// SPDX-License-Identifier: MIT

import SideStageCore
import XCTest
@testable import SideStage

/// Covers the stream stage's state → words mapping (WI-39800). The wording is
/// deliberately paired with the Android `StreamStage`: a buyer must read the
/// same room the same way on either phone. The retry schedule, the loss
/// budget, and the "only failed is lost" rule are the shared core's and are
/// tested there (crates/sidestage-core/src/whep.rs); these tests pin only
/// what this shell owns.
final class WhepPlaybackTests: XCTestCase {
    // MARK: - Status line

    func testIdleStatusExplainsMissingPlaybackHonestly() {
        XCTAssertEqual(
            WhepPlayback.idle.statusLabel(hasPlaybackUrl: false),
            "Live playback isn't available for this room yet."
        )
        XCTAssertEqual(
            WhepPlayback.idle.statusLabel(hasPlaybackUrl: true),
            "The seller stream appears here when the room is live."
        )
    }

    func testConnectingStatusUsesTheCoreCopyWhileWaitingForThePublisher() {
        // The waiting copy is the CORE's, byte-for-byte — every surface (web
        // included) says exactly the same thing, so this asserts against the
        // core function rather than a copy of the string.
        XCTAssertEqual(
            WhepPlayback.connecting(waitingForPublisher: true).statusLabel(hasPlaybackUrl: true),
            waitingForPublisherMessage()
        )
        XCTAssertEqual(
            WhepPlayback.connecting(waitingForPublisher: false).statusLabel(hasPlaybackUrl: true),
            "Connecting…"
        )
    }

    func testTerminalStatuses() {
        XCTAssertEqual(WhepPlayback.live.statusLabel(hasPlaybackUrl: true), "Live")
        XCTAssertEqual(
            WhepPlayback.failed(message: "nope").statusLabel(hasPlaybackUrl: true),
            "nope"
        )
    }

    // MARK: - The one control

    func testButtonOffersTheOppositeOfTheCurrentState() {
        XCTAssertEqual(WhepPlayback.idle.buttonLabel, "Connect")
        XCTAssertEqual(WhepPlayback.connecting(waitingForPublisher: false).buttonLabel, "Disconnect")
        XCTAssertEqual(WhepPlayback.connecting(waitingForPublisher: true).buttonLabel, "Disconnect")
        XCTAssertEqual(WhepPlayback.live.buttonLabel, "Disconnect")
        XCTAssertEqual(WhepPlayback.failed(message: "x").buttonLabel, "Retry")
    }

    func testActiveStatesAreExactlyConnectingAndLive() {
        XCTAssertTrue(WhepPlayback.connecting(waitingForPublisher: false).isActive)
        XCTAssertTrue(WhepPlayback.connecting(waitingForPublisher: true).isActive)
        XCTAssertTrue(WhepPlayback.live.isActive)
        XCTAssertFalse(WhepPlayback.idle.isActive)
        XCTAssertFalse(WhepPlayback.failed(message: "x").isActive)
    }

    // MARK: - Failure copy

    func testUserMessagesNeverLeakRawErrorDumps() {
        XCTAssertEqual(
            WhepPlayerController.userMessage(for: .PublisherNotReady),
            waitingForPublisherMessage()
        )
        XCTAssertEqual(
            WhepPlayerController.userMessage(for: .InvalidEndpoint(detail: "raw")),
            "This room's playback address is invalid."
        )
        XCTAssertEqual(
            WhepPlayerController.userMessage(for: .Transport(detail: "raw")),
            "The stream could not be connected."
        )
        XCTAssertEqual(
            WhepPlayerController.userMessage(for: .Http(status: 503, detail: "raw")),
            "The media server rejected the stream (503)."
        )
        XCTAssertEqual(
            WhepPlayerController.userMessage(for: .EmptyAnswer),
            "The media server returned an unusable answer."
        )
    }
}
