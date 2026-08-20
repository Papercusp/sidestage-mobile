// SPDX-License-Identifier: MIT
//
// The platform-bound half of the WHEP player (plan decision D-036): the
// libwebrtc engine, the local offer with its bounded ICE-gathering wait, and
// attaching the remote track to the stage's video surface. Policy lives in
// `WhepPlayer.swift` and the shared core.
//
// The whole file is guarded on `canImport(WebRTC)` because the repo's
// compile-verification path (tools/verify-ios-typecheck.sh) runs plain swiftc
// against the iOS SDK with no Swift Package Manager resolution, so the WebRTC
// package is absent there. The real Xcode build resolves it from project.yml
// and compiles the first branch; the fallback branch exists so the app target
// still typechecks — and says honestly that it cannot play — without it.

#if canImport(WebRTC)

import Foundation
import SideStageCore
import SwiftUI
import WebRTC

@MainActor
func makePlatformWhepEngine() -> WhepEngine? { WebRTCWhepEngine() }

/// Process-wide libwebrtc engine: one factory, created once — it carries
/// native threads worth paying for per process, not per room. The Android
/// `WebRtcEngine` singleton's sibling.
private enum SharedWebRTCFactory {
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
    }()
}

/// Budget for ICE gathering before the offer is sent as-is (mirrors the web
/// and Android players).
private let iceGatheringTimeoutMs: UInt64 = 10_000

@MainActor
final class WebRTCWhepEngine: WhepEngine {
    func createPeerConnection(
        iceServers: [WhepIceServer],
        onConnectionState: @escaping @MainActor (PeerConnectionState) -> Void,
        onVideoTrack: @escaping @MainActor (WhepVideoTrack?) -> Void
    ) throws -> WhepPeerConnectionHandle {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.iceServers = iceServers.map { server in
            RTCIceServer(
                urlStrings: [server.urls],
                username: server.username,
                credential: server.credential
            )
        }

        let events = PeerConnectionEvents(
            onConnectionState: onConnectionState,
            onVideoTrack: onVideoTrack
        )
        guard let peerConnection = SharedWebRTCFactory.factory.peerConnection(
            with: configuration,
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: events
        ) else {
            throw WhepError.Transport(detail: "the WebRTC engine could not create a peer connection")
        }
        return WebRTCPeerConnectionHandle(peerConnection: peerConnection, events: events)
    }
}

@MainActor
private final class WebRTCPeerConnectionHandle: WhepPeerConnectionHandle {
    private let peerConnection: RTCPeerConnection
    /// Retained here: `RTCPeerConnection` holds its delegate weakly.
    private let events: PeerConnectionEvents

    init(peerConnection: RTCPeerConnection, events: PeerConnectionEvents) {
        self.peerConnection = peerConnection
        self.events = events
    }

    func localOfferAfterGathering() async throws -> String {
        peerConnection.addTransceiver(of: .video, init: Self.recvOnly())
        peerConnection.addTransceiver(of: .audio, init: Self.recvOnly())

        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { description, error in
                if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: WhepError.Transport(
                        detail: error?.localizedDescription ?? "the WebRTC engine produced no local offer"
                    ))
                }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(offer) { error in
                if let error {
                    continuation.resume(throwing: WhepError.Transport(
                        detail: "applying the local offer failed: \(error.localizedDescription)"
                    ))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }

        await events.waitForGatheringComplete(timeoutMs: iceGatheringTimeoutMs)

        guard let sdp = peerConnection.localDescription?.sdp else {
            throw WhepError.Transport(detail: "the WebRTC engine produced no local offer")
        }
        return sdp
    }

    func applyRemoteAnswer(sdp: String) async throws {
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(answer) { error in
                if let error {
                    continuation.resume(throwing: WhepError.Transport(
                        detail: "applying the media answer failed: \(error.localizedDescription)"
                    ))
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func close() {
        peerConnection.close()
    }

    private static func recvOnly() -> RTCRtpTransceiverInit {
        let transceiverInit = RTCRtpTransceiverInit()
        transceiverInit.direction = .recvOnly
        return transceiverInit
    }
}

/// The delegate: maps libwebrtc callbacks (arriving on WebRTC's own threads)
/// onto main-actor reports. Which connection states count as LOST is the
/// core's call, made by the controller — this type only relays.
private final class PeerConnectionEvents: NSObject, RTCPeerConnectionDelegate {
    private let onConnectionState: @MainActor (PeerConnectionState) -> Void
    private let onVideoTrack: @MainActor (WhepVideoTrack?) -> Void

    /// Single-consumer by construction: one handle waits once per connection.
    private let gatheringStream: AsyncStream<Void>
    private let gatheringContinuation: AsyncStream<Void>.Continuation

    init(
        onConnectionState: @escaping @MainActor (PeerConnectionState) -> Void,
        onVideoTrack: @escaping @MainActor (WhepVideoTrack?) -> Void
    ) {
        self.onConnectionState = onConnectionState
        self.onVideoTrack = onVideoTrack
        (gatheringStream, gatheringContinuation) = AsyncStream.makeStream(of: Void.self)
        super.init()
    }

    func waitForGatheringComplete(timeoutMs: UInt64) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [gatheringStream] in
                for await _ in gatheringStream { break }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: timeoutMs * 1_000_000)
            }
            await group.next()
            group.cancelAll()
        }
    }

    // MARK: - The callbacks this player acts on

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        if newState == .complete {
            gatheringContinuation.yield(())
            gatheringContinuation.finish()
        }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let state = Self.coreState(from: newState)
        Task { @MainActor [onConnectionState] in onConnectionState(state) }
    }

    func peerConnection(_ peerConnection: RTCPeerConnection, didStartReceivingOn transceiver: RTCRtpTransceiver) {
        guard let track = transceiver.receiver.track as? RTCVideoTrack else { return }
        Task { @MainActor [onVideoTrack] in onVideoTrack(WhepVideoTrack(raw: track)) }
    }

    private static func coreState(from state: RTCPeerConnectionState) -> PeerConnectionState {
        switch state {
        case .new: .new
        case .connecting: .connecting
        case .connected: .connected
        case .disconnected: .disconnected
        case .failed: .failed
        case .closed: .closed
        @unknown default: .failed
        }
    }

    // MARK: - Required no-ops

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}

    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}

/// The stage's video surface: a Metal-backed renderer with the remote track
/// attached. The track and the view arrive independently (native callback vs
/// SwiftUI update); the coordinator attaches whenever both exist and detaches
/// when either goes.
struct WhepVideoView: UIViewRepresentable {
    let track: WhepVideoTrack?

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFit
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        let next = track?.raw as? RTCVideoTrack
        guard context.coordinator.attached !== next else { return }
        context.coordinator.attached?.remove(view)
        next?.add(view)
        context.coordinator.attached = next
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attached?.remove(view)
        coordinator.attached = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var attached: RTCVideoTrack?
    }
}

#else

import SwiftUI

/// No WebRTC package in this toolchain (the swiftc typecheck harness). The
/// controller reports an honest failure instead of playing; the real Xcode
/// build never takes this branch.
@MainActor
func makePlatformWhepEngine() -> WhepEngine? { nil }

/// Keeps the stage's call site typecheckable without the package.
struct WhepVideoView: View {
    let track: WhepVideoTrack?

    var body: some View { Color.clear }
}

#endif
