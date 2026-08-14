// SPDX-License-Identifier: MIT

import SideStageCore
import XCTest
@testable import SideStage

/// Covers the rules a buyer would notice being wrong: what their money looks
/// like, what the bid field accepts, and how much time the clock says is left.
///
/// The parsing cases are deliberately paired with the web's `parseBidDollars`
/// (`apps/web/src/auction.ts`). A buyer must not be able to get an amount
/// accepted on one surface and rejected on another, so these tests are the
/// place that divergence gets caught.
final class LiveEventPresentationTests: XCTestCase {
    // MARK: - Money formatting

    func testFormatPriceRendersWholeAndFractionalDollars() {
        XCTAssertEqual(LiveEventPresentation.formatPrice(cents: 2_400), "$24.00")
        XCTAssertEqual(LiveEventPresentation.formatPrice(cents: 2_450), "$24.50")
        XCTAssertEqual(LiveEventPresentation.formatPrice(cents: 0), "$0.00")
        XCTAssertEqual(LiveEventPresentation.formatPrice(cents: 123_456), "$1,234.56")
    }

    func testFormatPriceKeepsCentsExactAtLargeAmounts() {
        // The value crosses through Decimal rather than Double precisely so a
        // large amount cannot land a cent off.
        XCTAssertEqual(LiveEventPresentation.formatPrice(cents: 99_999_999), "$999,999.99")
    }

    // MARK: - Bid parsing

    func testParseBidDollarsAcceptsTheShapesTheWebAccepts() {
        XCTAssertEqual(LiveEventPresentation.parseBidDollars("24"), 2_400)
        XCTAssertEqual(LiveEventPresentation.parseBidDollars("24.5"), 2_450)
        XCTAssertEqual(LiveEventPresentation.parseBidDollars("24.50"), 2_450)
        XCTAssertEqual(LiveEventPresentation.parseBidDollars("  24.50  "), 2_450)
        XCTAssertEqual(LiveEventPresentation.parseBidDollars("1234.56"), 123_456)
    }

    func testParseBidDollarsRejectsEverythingElse() {
        for input in ["", " ", "abc", "$24.50", "24.505", "24.", ".50", "-5", "1,234", "24 50", "1e3"] {
            XCTAssertNil(
                LiveEventPresentation.parseBidDollars(input),
                "expected \"\(input)\" to be rejected"
            )
        }
    }

    func testParseBidDollarsRejectsZeroBecauseTheApiWould() {
        XCTAssertNil(LiveEventPresentation.parseBidDollars("0"))
        XCTAssertNil(LiveEventPresentation.parseBidDollars("0.00"))
    }

    func testParseBidDollarsIsExactAtValuesThatBreakBinaryFloats() {
        // 12.34 * 100 is 1233.9999… in binary floating point; landing on 1233
        // would silently under-bid the buyer.
        XCTAssertEqual(LiveEventPresentation.parseBidDollars("12.34"), 1_234)
        XCTAssertEqual(LiveEventPresentation.parseBidDollars("8.29"), 829)
        XCTAssertEqual(LiveEventPresentation.parseBidDollars("1.15"), 115)
    }

    func testBidFieldTextRoundTripsThroughTheParser() {
        for cents: Int64 in [100, 829, 1_234, 2_400, 2_450, 99_999] {
            let text = LiveEventPresentation.bidFieldText(cents: cents)
            XCTAssertEqual(
                LiveEventPresentation.parseBidDollars(text),
                cents,
                "\(cents) did not survive a round trip (rendered as \"\(text)\")"
            )
        }
    }

    // MARK: - Countdown

    private func date(_ iso: String) -> Date {
        guard let parsed = LiveEventPresentation.date(fromISO8601: iso) else {
            XCTFail("could not parse \(iso)")
            return Date()
        }
        return parsed
    }

    func testParsesTheFractionalSecondsTheApiActuallyEmits() {
        // The API serializes with JavaScript's toISOString(), which always
        // carries milliseconds; without .withFractionalSeconds every real
        // timestamp parses as nil and every countdown reads zero.
        XCTAssertNotNil(LiveEventPresentation.date(fromISO8601: "2026-08-14T12:00:30.123Z"))
    }

    func testParsesTimestampsWithoutFractionalSecondsToo() {
        XCTAssertNotNil(LiveEventPresentation.date(fromISO8601: "2026-08-14T12:00:30Z"))
    }

    func testSecondsRemainingRoundsUpSoAPartialSecondStillShows() {
        let now = date("2026-08-14T12:00:00.000Z")
        XCTAssertEqual(
            LiveEventPresentation.secondsRemaining(endsAt: "2026-08-14T12:00:30.400Z", now: now),
            31
        )
        XCTAssertEqual(
            LiveEventPresentation.secondsRemaining(endsAt: "2026-08-14T12:00:30.000Z", now: now),
            30
        )
    }

    func testSecondsRemainingFloorsAtZeroForAPastDeadline() {
        let now = date("2026-08-14T12:00:00.000Z")
        XCTAssertEqual(
            LiveEventPresentation.secondsRemaining(endsAt: "2026-08-14T11:59:00.000Z", now: now),
            0
        )
    }

    func testSecondsRemainingTreatsAnUnparseableDeadlineAsExpired() {
        XCTAssertEqual(LiveEventPresentation.secondsRemaining(endsAt: "not a date"), 0)
    }

    func testFormatCountdownPadsSecondsButNotMinutes() {
        XCTAssertEqual(LiveEventPresentation.formatCountdown(seconds: 0), "0:00")
        XCTAssertEqual(LiveEventPresentation.formatCountdown(seconds: 5), "0:05")
        XCTAssertEqual(LiveEventPresentation.formatCountdown(seconds: 65), "1:05")
        XCTAssertEqual(LiveEventPresentation.formatCountdown(seconds: 600), "10:00")
    }

    func testFormatCountdownClampsNegativeInput() {
        XCTAssertEqual(LiveEventPresentation.formatCountdown(seconds: -12), "0:00")
    }

    // MARK: - Connection copy

    func testConnectionLabelsReadAsProgressNotFailure() {
        XCTAssertEqual(LiveEventPresentation.connectionLabel(.connecting), "Connecting…")
        XCTAssertEqual(LiveEventPresentation.connectionLabel(.live), "Live")
        XCTAssertEqual(
            LiveEventPresentation.connectionLabel(.reconnecting(retryInSeconds: 3)),
            "Reconnecting in 3s"
        )
    }

    func testConnectionLabelOmitsAZeroSecondRetry() {
        XCTAssertEqual(
            LiveEventPresentation.connectionLabel(.reconnecting(retryInSeconds: 0)),
            "Reconnecting…"
        )
    }

    // MARK: - Bid availability

    func testOnlyAReadyBidEnablesTheButton() {
        XCTAssertTrue(BidAvailability.ready(amountCents: 2_500).isReady)
        for unavailable: BidAvailability in [
            .noAuction, .auctionClosed, .signedOut, .amountNotANumber,
            .belowMinimum(minimumCents: 2_401), .submitting,
        ] {
            XCTAssertFalse(unavailable.isReady, "\(unavailable) should not enable the button")
        }
    }

    func testEveryUnavailableStateExplainsItself() {
        // A disabled control with no explanation is the failure this guards:
        // during a live auction the buyer must always know why they cannot bid.
        for unavailable: BidAvailability in [
            .noAuction, .auctionClosed, .signedOut, .amountNotANumber,
            .belowMinimum(minimumCents: 2_401), .submitting,
        ] {
            XCTAssertNotNil(unavailable.message(), "\(unavailable) had no message")
        }
        XCTAssertNil(BidAvailability.ready(amountCents: 2_500).message())
    }

    func testBelowMinimumQuotesTheMinimumInDollars() {
        XCTAssertEqual(
            BidAvailability.belowMinimum(minimumCents: 2_401).message(),
            "Bid at least $24.01."
        )
    }
}

/// The two pure mappings the view model owns. They take core types, so they
/// live here rather than in the FFI-free presentation tests above.
final class LiveEventViewModelMappingTests: XCTestCase {
    func testPollingReadsAsReconnectingWithWholeSeconds() {
        XCTAssertEqual(
            LiveEventViewModel.connectionState(from: .polling(retryInMs: 3_000)),
            .reconnecting(retryInSeconds: 3)
        )
    }

    func testASubSecondRetryRoundsUpRatherThanReadingAsZero() {
        // Rounding down would render "Reconnecting in 0s", which claims the
        // retry already happened.
        XCTAssertEqual(
            LiveEventViewModel.connectionState(from: .polling(retryInMs: 1)),
            .reconnecting(retryInSeconds: 1)
        )
        XCTAssertEqual(
            LiveEventViewModel.connectionState(from: .polling(retryInMs: 1_500)),
            .reconnecting(retryInSeconds: 2)
        )
    }

    func testLiveAndConnectingMapStraightThrough() {
        XCTAssertEqual(LiveEventViewModel.connectionState(from: .live), .live)
        XCTAssertEqual(LiveEventViewModel.connectionState(from: .connecting), .connecting)
    }

    func testAConflictIsExplainedAsBeingOutbid() {
        // The API returns 409 when the amount no longer clears the current
        // price, which in a live room means somebody else got there first.
        let message = LiveEventViewModel.bidErrorMessage(
            for: .Http(status: 409, detail: "bid too low")
        )
        XCTAssertEqual(message, "Someone outbid you — the price just moved.")
    }

    func testAnOfflineFailureSaysTheBidDidNotLand() {
        let message = LiveEventViewModel.bidErrorMessage(for: .Transport(detail: "offline"))
        XCTAssertEqual(message, "You're offline. Your bid was not placed.")
    }

    func testAnUnexpectedStatusStillGetsAnActionableMessage() {
        let message = LiveEventViewModel.bidErrorMessage(
            for: .Http(status: 500, detail: "boom")
        )
        XCTAssertEqual(message, "Could not place your bid. Try again.")
    }
}
