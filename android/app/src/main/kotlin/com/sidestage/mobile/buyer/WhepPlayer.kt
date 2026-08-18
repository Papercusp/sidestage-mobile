// SPDX-License-Identifier: MIT
package com.sidestage.mobile.buyer

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import org.webrtc.DefaultVideoDecoderFactory
import org.webrtc.DefaultVideoEncoderFactory
import org.webrtc.EglBase
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.PeerConnectionFactory
import org.webrtc.RtpTransceiver
import org.webrtc.SdpObserver
import org.webrtc.SessionDescription
import org.webrtc.VideoTrack
import uniffi.sidestage.PeerConnectionState as CorePeerConnectionState
import uniffi.sidestage.WhepException
import uniffi.sidestage.WhepSignaling
import uniffi.sidestage.isLostConnectionState
import uniffi.sidestage.maxLossReconnects
import uniffi.sidestage.publisherAbsentMessage
import uniffi.sidestage.publisherRetryDelayMs
import uniffi.sidestage.sdpHasIceCandidate
import uniffi.sidestage.waitingForPublisherMessage
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * WHEP viewer for one live room (WI-39800).
 *
 * Everything that is POLICY — the publisher-not-ready retry schedule, the
 * loss-recovery budget, the "only `failed` is lost" rule, the user-facing
 * copy — comes from the shared core through UniFFI (plan decision D-036), so
 * this player, the iPhone player, and the web buyer cannot drift. This file
 * owns only what is genuinely platform-bound: the libwebrtc engine, the local
 * offer with its bounded ICE-gathering wait, and handing the remote video
 * track to the stage surface.
 */
sealed interface WhepPlayback {
    /** No connect requested (or a deliberate disconnect). */
    data object Idle : WhepPlayback

    data class Connecting(
        val waitingForPublisher: Boolean,
    ) : WhepPlayback

    data object Live : WhepPlayback

    data class Failed(
        val message: String,
    ) : WhepPlayback
}

/**
 * Process-wide libwebrtc engine. One EGL context + one factory: renderers and
 * decoders must share the context or remote frames render black, and the
 * factory carries native threads worth creating once, not per room.
 */
object WebRtcEngine {
    val eglBase: EglBase by lazy { EglBase.create() }

    @Volatile
    private var factory: PeerConnectionFactory? = null

    fun factory(context: Context): PeerConnectionFactory =
        factory ?: synchronized(this) {
            factory ?: run {
                PeerConnectionFactory.initialize(
                    PeerConnectionFactory.InitializationOptions
                        .builder(context.applicationContext)
                        .createInitializationOptions(),
                )
                PeerConnectionFactory
                    .builder()
                    .setVideoDecoderFactory(DefaultVideoDecoderFactory(eglBase.eglBaseContext))
                    .setVideoEncoderFactory(DefaultVideoEncoderFactory(eglBase.eglBaseContext, false, false))
                    .createPeerConnectionFactory()
                    .also { factory = it }
            }
        }
}

/** Budget for ICE gathering before the offer is sent as-is (mirrors the web). */
private const val ICE_GATHERING_TIMEOUT_MS = 10_000L

class WhepPlayerController(
    private val context: Context,
    private val playbackUrl: String,
    private val scope: CoroutineScope,
    private val onPlayback: (WhepPlayback) -> Unit,
    private val onVideoTrack: (VideoTrack?) -> Unit,
) {
    private var job: Job? = null

    /** One signaling client (it owns a small native runtime) per controller. */
    private val signaling: WhepSignaling by lazy { WhepSignaling() }

    fun connect() {
        if (job?.isActive == true) return
        job =
            scope.launch {
                try {
                    runPlayback()
                } catch (error: WhepException) {
                    report(WhepPlayback.Failed(error.userMessage()))
                }
            }
    }

    fun disconnect() {
        job?.cancel()
        job = null
        report(WhepPlayback.Idle)
    }

    /** Final teardown when the stage leaves composition. */
    fun release() {
        disconnect()
        runCatching { signaling.destroy() }
    }

    /**
     * The web buyer's recovery structure, suspend-shaped: a bounded
     * publisher wait produces an established session; a session that dies
     * after working re-enters the SAME bounded wait while the loss budget
     * lasts (WI-39747). Either bound running out surfaces the honest
     * "nobody is on camera" copy with an explicit retry.
     */
    private suspend fun runPlayback() {
        var lossBudget = maxLossReconnects().toInt()
        while (true) {
            val session = connectUntilPublisher() ?: return
            report(WhepPlayback.Live)
            try {
                session.lost.first { it }
            } finally {
                session.close()
                onVideoTrack(null)
            }
            if (lossBudget <= 0) {
                report(WhepPlayback.Failed(publisherAbsentMessage()))
                return
            }
            lossBudget -= 1
            report(WhepPlayback.Connecting(waitingForPublisher = false))
        }
    }

    /**
     * WI-39733: a WHEP 404 means the seller's camera has not arrived yet, so
     * re-offer on the core's bounded schedule. Every other failure latches
     * immediately. Returns null once a terminal state has been reported.
     */
    private suspend fun connectUntilPublisher(): WhepSession? {
        var failures = 0
        while (true) {
            report(WhepPlayback.Connecting(waitingForPublisher = failures > 0))
            try {
                return connectOnce()
            } catch (error: WhepException.PublisherNotReady) {
                val delayMs = publisherRetryDelayMs(failures.toUInt())
                if (delayMs == null) {
                    report(WhepPlayback.Failed(publisherAbsentMessage()))
                    return null
                }
                failures += 1
                report(WhepPlayback.Connecting(waitingForPublisher = true))
                delay(delayMs.toLong())
            } catch (error: WhepException) {
                report(WhepPlayback.Failed(error.userMessage()))
                return null
            }
        }
    }

    private suspend fun connectOnce(): WhepSession {
        val iceServers =
            signaling.discoverIceServers(playbackUrl).map { server ->
                PeerConnection.IceServer
                    .builder(server.urls)
                    .apply { server.username?.let(::setUsername) }
                    .apply { server.credential?.let(::setPassword) }
                    .createIceServer()
            }

        val gatheringComplete = MutableStateFlow(false)
        val lost = MutableStateFlow(false)
        val observer =
            object : NoOpPeerConnectionObserver() {
                override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {
                    if (state == PeerConnection.IceGatheringState.COMPLETE) gatheringComplete.value = true
                }

                override fun onConnectionChange(state: PeerConnection.PeerConnectionState?) {
                    // The lost/transient/deliberate distinction is core policy
                    // (WI-39747), not this file's judgment call.
                    if (state != null && isLostConnectionState(state.toCore())) lost.value = true
                }

                override fun onTrack(transceiver: RtpTransceiver?) {
                    val track = transceiver?.receiver?.track()
                    if (track is VideoTrack) onVideoTrack(track)
                }
            }

        val factory = WebRtcEngine.factory(context)
        val configuration =
            PeerConnection.RTCConfiguration(iceServers).apply {
                sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            }
        val peerConnection =
            factory.createPeerConnection(configuration, observer)
                ?: throw WhepException.Transport("the WebRTC engine could not create a peer connection")

        try {
            peerConnection.addTransceiver(
                MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
                RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY),
            )
            peerConnection.addTransceiver(
                MediaStreamTrack.MediaType.MEDIA_TYPE_AUDIO,
                RtpTransceiver.RtpTransceiverInit(RtpTransceiver.RtpTransceiverDirection.RECV_ONLY),
            )

            val offer = peerConnection.createOfferSuspend()
            peerConnection.setLocalDescriptionSuspend(offer)

            // WHEP is vanilla ICE: candidates that arrive after the POST are
            // never delivered, so wait for gathering — but a timeout with
            // candidates already in hand is shippable (host candidates are the
            // path that actually connects), while an empty offer would fail
            // server-side with no trace at all.
            withTimeoutOrNull(ICE_GATHERING_TIMEOUT_MS) { gatheringComplete.first { it } }
            val localSdp =
                peerConnection.localDescription?.description
                    ?: throw WhepException.Transport("the WebRTC engine produced no local offer")
            if (!sdpHasIceCandidate(localSdp)) {
                throw WhepException.Transport("timed out while gathering media ICE candidates")
            }

            val answer = signaling.postOffer(playbackUrl, localSdp)
            peerConnection.setRemoteDescriptionSuspend(
                SessionDescription(SessionDescription.Type.ANSWER, answer.sdp),
            )
            return WhepSession(peerConnection, answer.resourceUrl, lost)
        } catch (error: Throwable) {
            peerConnection.close()
            throw error
        }
    }

    private fun report(playback: WhepPlayback) {
        scope.launch(Dispatchers.Main.immediate) { onPlayback(playback) }
    }

    /** One established (or negotiated) viewer session. */
    private inner class WhepSession(
        private val peerConnection: PeerConnection,
        private val resourceUrl: String?,
        val lost: MutableStateFlow<Boolean>,
    ) {
        fun close() {
            peerConnection.close()
            // Deleting the WHEP resource keeps MediaMTX from holding a stale
            // peer; deliberately fire-and-forget past cancellation.
            val url = resourceUrl ?: return
            scope.launch(NonCancellable) {
                runCatching { signaling.deleteResource(url) }
            }
        }
    }
}

/** Concise user-facing copy per failure class (the raw variants render as
 * `detail=…` field dumps, which tell a buyer nothing they can act on). */
private fun WhepException.userMessage(): String =
    when (this) {
        is WhepException.PublisherNotReady -> waitingForPublisherMessage()
        is WhepException.InvalidEndpoint -> "This room's playback address is invalid."
        is WhepException.Transport -> "The stream could not be connected."
        is WhepException.Http -> "The media server rejected the stream ($status)."
        is WhepException.EmptyAnswer -> "The media server returned an unusable answer."
    }

private fun PeerConnection.PeerConnectionState.toCore(): CorePeerConnectionState =
    when (this) {
        PeerConnection.PeerConnectionState.NEW -> CorePeerConnectionState.NEW
        PeerConnection.PeerConnectionState.CONNECTING -> CorePeerConnectionState.CONNECTING
        PeerConnection.PeerConnectionState.CONNECTED -> CorePeerConnectionState.CONNECTED
        PeerConnection.PeerConnectionState.DISCONNECTED -> CorePeerConnectionState.DISCONNECTED
        PeerConnection.PeerConnectionState.FAILED -> CorePeerConnectionState.FAILED
        PeerConnection.PeerConnectionState.CLOSED -> CorePeerConnectionState.CLOSED
    }

private suspend fun PeerConnection.createOfferSuspend(): SessionDescription =
    withContext(Dispatchers.IO) {
        suspendCancellableCoroutine { continuation ->
            createOffer(
                object : NoOpSdpObserver() {
                    override fun onCreateSuccess(description: SessionDescription?) {
                        if (description == null) {
                            continuation.resumeWithException(
                                WhepException.Transport("the WebRTC engine produced no local offer"),
                            )
                        } else {
                            continuation.resume(description)
                        }
                    }

                    override fun onCreateFailure(error: String?) {
                        continuation.resumeWithException(
                            WhepException.Transport(error ?: "creating the media offer failed"),
                        )
                    }
                },
                MediaConstraints(),
            )
        }
    }

private suspend fun PeerConnection.setLocalDescriptionSuspend(description: SessionDescription) =
    withContext(Dispatchers.IO) {
        suspendCancellableCoroutine { continuation ->
            setLocalDescription(
                object : NoOpSdpObserver() {
                    override fun onSetSuccess() {
                        continuation.resume(Unit)
                    }

                    override fun onSetFailure(error: String?) {
                        continuation.resumeWithException(
                            WhepException.Transport(error ?: "applying the local offer failed"),
                        )
                    }
                },
                description,
            )
        }
    }

private suspend fun PeerConnection.setRemoteDescriptionSuspend(description: SessionDescription) =
    withContext(Dispatchers.IO) {
        suspendCancellableCoroutine { continuation ->
            setRemoteDescription(
                object : NoOpSdpObserver() {
                    override fun onSetSuccess() {
                        continuation.resume(Unit)
                    }

                    override fun onSetFailure(error: String?) {
                        continuation.resumeWithException(
                            WhepException.Transport(error ?: "applying the media answer failed"),
                        )
                    }
                },
                description,
            )
        }
    }

private abstract class NoOpSdpObserver : SdpObserver {
    override fun onCreateSuccess(description: SessionDescription?) {}

    override fun onSetSuccess() {}

    override fun onCreateFailure(error: String?) {}

    override fun onSetFailure(error: String?) {}
}

private abstract class NoOpPeerConnectionObserver : PeerConnection.Observer {
    override fun onSignalingChange(state: PeerConnection.SignalingState?) {}

    override fun onIceConnectionChange(state: PeerConnection.IceConnectionState?) {}

    override fun onIceConnectionReceivingChange(receiving: Boolean) {}

    override fun onIceGatheringChange(state: PeerConnection.IceGatheringState?) {}

    override fun onIceCandidate(candidate: IceCandidate?) {}

    override fun onIceCandidatesRemoved(candidates: Array<out IceCandidate>?) {}

    override fun onAddStream(stream: MediaStream?) {}

    override fun onRemoveStream(stream: MediaStream?) {}

    override fun onDataChannel(channel: org.webrtc.DataChannel?) {}

    override fun onRenegotiationNeeded() {}
}
