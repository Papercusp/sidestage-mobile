// SPDX-License-Identifier: MIT

import Foundation
import SideStageCore

/// WHEP viewer for one live room (WI-39800).
///
/// Everything that is POLICY — the publisher-not-ready retry schedule, the
/// loss-recovery budget, the "only `failed` is lost" rule, the user-facing
/// copy — comes from the shared core through UniFFI (plan decision D-036), so
/// this player, the Android player, and the web buyer cannot drift. This file
/// owns only the policy-driving loop; what is genuinely platform-bound (the
/// WebRTC engine, the local offer with its bounded ICE-gathering wait, and
/// handing the remote video track to the stage) sits behind `WhepEngine`,
/// implemented in `WhepWebRTCEngine.swift`.

/// What the stage renders for the seller's stream.
enum WhepPlayback: Equatable {
    /// No connect requested (or a deliberate disconnect).
    case idle
    case connecting(waitingForPublisher: Bool)
    case live
    case failed(message: String)
}

extension WhepPlayback {
    /// The stage's one-line stream status, shared with the connect control.
    /// Mirrors the Android `StreamStage` wording exactly.
    func statusLabel(hasPlaybackUrl: Bool) -> String {
        switch self {
        case .idle:
            hasPlaybackUrl
                ? "The seller stream appears here when the room is live."
                : "Live playback isn't available for this room yet."
        case let .connecting(waitingForPublisher):
            waitingForPublisher ? waitingForPublisherMessage() : "Connecting…"
        case .live:
            "Live"
        case let .failed(message):
            message
        }
    }

    /// What the stream control offers next.
    var buttonLabel: String {
        switch self {
        case .connecting, .live: "Disconnect"
        case .failed: "Retry"
        case .idle: "Connect"
        }
    }

    /// Whether a session is up or being negotiated — the states where the
    /// video surface replaces the poster and the control means "Disconnect".
    var isActive: Bool {
        switch self {
        case .connecting, .live: true
        case .idle, .failed: false
        }
    }
}

/// An opaque remote video track. The controller and view model pass it
/// through untouched; only the platform engine and the video surface (both
/// behind `canImport(WebRTC)`) know the concrete type inside.
struct WhepVideoTrack {
    let raw: AnyObject
}

/// The signaling seam, so tests can drive the controller without the Rust
/// core's HTTP client. `WhepSignaling` (generated) conforms as-is.
protocol WhepSignalingProtocol: AnyObject {
    func discoverIceServers(endpoint: String) async throws -> [WhepIceServer]
    func postOffer(endpoint: String, offerSdp: String) async throws -> WhepAnswer
    func deleteResource(resourceUrl: String) async throws
}

extension WhepSignaling: WhepSignalingProtocol {}

/// One platform peer connection being negotiated (or established).
@MainActor
protocol WhepPeerConnectionHandle: AnyObject {
    /// Adds the recv-only transceivers, creates the local offer, and waits a
    /// bounded time for ICE gathering — returning whatever SDP is in hand at
    /// the bound. Whether that SDP is shippable is the CONTROLLER's judgment
    /// (core policy), not the engine's.
    func localOfferAfterGathering() async throws -> String
    func applyRemoteAnswer(sdp: String) async throws
    func close()
}

/// The platform-bound half of the player (D-036): the WebRTC engine and track
/// attachment, nothing else.
@MainActor
protocol WhepEngine {
    /// `onConnectionState` and `onVideoTrack` are delivered on the main actor.
    /// The engine maps its native connectivity enum onto the core's
    /// `PeerConnectionState`; deciding which states are LOST stays with the
    /// controller.
    func createPeerConnection(
        iceServers: [WhepIceServer],
        onConnectionState: @escaping @MainActor (PeerConnectionState) -> Void,
        onVideoTrack: @escaping @MainActor (WhepVideoTrack?) -> Void
    ) throws -> WhepPeerConnectionHandle
}

@MainActor
final class WhepPlayerController {
    private let playbackUrl: String
    private let engine: WhepEngine?
    private let signaling: WhepSignalingProtocol?
    private let onPlayback: (WhepPlayback) -> Void
    private let onVideoTrack: (WhepVideoTrack?) -> Void

    private var task: Task<Void, Never>?
    private var isRunning = false

    init(
        playbackUrl: String,
        engine: WhepEngine? = makePlatformWhepEngine(),
        signaling: WhepSignalingProtocol? = try? WhepSignaling(),
        onPlayback: @escaping (WhepPlayback) -> Void,
        onVideoTrack: @escaping (WhepVideoTrack?) -> Void
    ) {
        self.playbackUrl = playbackUrl
        self.engine = engine
        self.signaling = signaling
        self.onPlayback = onPlayback
        self.onVideoTrack = onVideoTrack
    }

    func connect() {
        guard !isRunning else { return }
        guard let engine, let signaling else {
            // No engine means a build without the WebRTC package (the
            // typecheck harness); no signaling means the core failed to
            // construct its runtime. Neither is retryable from here.
            onPlayback(.failed(message: "The stream could not be connected."))
            return
        }
        isRunning = true
        task = Task { [weak self] in
            await self?.runPlayback(engine: engine, signaling: signaling)
            self?.isRunning = false
        }
    }

    func disconnect() {
        task?.cancel()
        task = nil
        isRunning = false
        onVideoTrack(nil)
        onPlayback(.idle)
    }

    /// The web buyer's recovery structure (WI-39747), task-shaped: a bounded
    /// publisher wait produces an established session; a session that dies
    /// after working re-enters the SAME bounded wait while the loss budget
    /// lasts. Either bound running out surfaces the honest "nobody is on
    /// camera" copy with an explicit retry.
    private func runPlayback(engine: WhepEngine, signaling: WhepSignalingProtocol) async {
        var lossBudget = Int(maxLossReconnects())
        while !Task.isCancelled {
            guard let session = await connectUntilPublisher(engine: engine, signaling: signaling) else { return }
            report(.live)
            await session.waitUntilLost()
            session.shutdown(signaling: signaling)
            onVideoTrack(nil)
            if Task.isCancelled { return }
            if lossBudget <= 0 {
                report(.failed(message: publisherAbsentMessage()))
                return
            }
            lossBudget -= 1
            report(.connecting(waitingForPublisher: false))
        }
    }

    /// WI-39733: a WHEP 404 means the seller's camera has not arrived yet, so
    /// re-offer on the core's bounded schedule. Every other failure latches
    /// immediately. Returns nil once a terminal state has been reported.
    private func connectUntilPublisher(
        engine: WhepEngine,
        signaling: WhepSignalingProtocol
    ) async -> Session? {
        var failures: UInt32 = 0
        while !Task.isCancelled {
            report(.connecting(waitingForPublisher: failures > 0))
            do {
                return try await connectOnce(engine: engine, signaling: signaling)
            } catch WhepError.PublisherNotReady {
                guard let delayMs = publisherRetryDelayMs(attempt: failures) else {
                    report(.failed(message: publisherAbsentMessage()))
                    return nil
                }
                failures += 1
                report(.connecting(waitingForPublisher: true))
                do {
                    try await Task.sleep(nanoseconds: delayMs * 1_000_000)
                } catch {
                    return nil
                }
            } catch let error as WhepError {
                report(.failed(message: Self.userMessage(for: error)))
                return nil
            } catch {
                report(.failed(message: "The stream could not be connected."))
                return nil
            }
        }
        return nil
    }

    private func connectOnce(
        engine: WhepEngine,
        signaling: WhepSignalingProtocol
    ) async throws -> Session {
        let iceServers = try await signaling.discoverIceServers(endpoint: playbackUrl)

        var stateContinuation: AsyncStream<PeerConnectionState>.Continuation?
        let states = AsyncStream<PeerConnectionState> { stateContinuation = $0 }
        let handle = try engine.createPeerConnection(
            iceServers: iceServers,
            onConnectionState: { state in stateContinuation?.yield(state) },
            onVideoTrack: { [onVideoTrack] track in onVideoTrack(track) }
        )

        do {
            let offerSdp = try await handle.localOfferAfterGathering()
            // WHEP is vanilla ICE: candidates that arrive after the POST are
            // never delivered — but a gathering timeout with candidates
            // already in hand is shippable (host candidates are the path that
            // actually connects), while an empty offer would fail server-side
            // with no trace at all. The judgment is the core's.
            guard sdpHasIceCandidate(sdp: offerSdp) else {
                throw WhepError.Transport(detail: "timed out while gathering media ICE candidates")
            }
            let answer = try await signaling.postOffer(endpoint: playbackUrl, offerSdp: offerSdp)
            try await handle.applyRemoteAnswer(sdp: answer.sdp)
            return Session(handle: handle, resourceUrl: answer.resourceUrl, states: states)
        } catch {
            handle.close()
            throw error
        }
    }

    private func report(_ playback: WhepPlayback) {
        guard !Task.isCancelled else { return }
        onPlayback(playback)
    }

    /// Concise user-facing copy per failure class (the raw variants render as
    /// field dumps, which tell a buyer nothing they can act on). Mirrors the
    /// Android `WhepException.userMessage()`.
    nonisolated static func userMessage(for error: WhepError) -> String {
        switch error {
        case .PublisherNotReady:
            waitingForPublisherMessage()
        case .InvalidEndpoint:
            "This room's playback address is invalid."
        case .Transport:
            "The stream could not be connected."
        case let .Http(status, _):
            "The media server rejected the stream (\(status))."
        case .EmptyAnswer:
            "The media server returned an unusable answer."
        }
    }

    /// One established (or negotiated) viewer session.
    @MainActor
    private final class Session {
        private let handle: WhepPeerConnectionHandle
        private let resourceUrl: String?
        private let states: AsyncStream<PeerConnectionState>

        init(
            handle: WhepPeerConnectionHandle,
            resourceUrl: String?,
            states: AsyncStream<PeerConnectionState>
        ) {
            self.handle = handle
            self.resourceUrl = resourceUrl
            self.states = states
        }

        /// Resolves when the connection is gone for good — where "for good"
        /// is core policy (WI-39747: only `failed`; `disconnected` is
        /// transient, `closed` deliberate) — or when the task is cancelled.
        func waitUntilLost() async {
            for await state in states where isLostConnectionState(state: state) {
                return
            }
        }

        func shutdown(signaling: WhepSignalingProtocol) {
            handle.close()
            // Deleting the WHEP resource keeps the media server from holding
            // a stale peer; deliberately fire-and-forget past cancellation.
            guard let resourceUrl else { return }
            Task.detached {
                try? await signaling.deleteResource(resourceUrl: resourceUrl)
            }
        }
    }
}
