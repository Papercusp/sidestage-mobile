// SPDX-License-Identifier: MIT

import Foundation

/// Presentation rules for the buyer's live event screen.
///
/// Deliberately free of any `SideStageCore` import: everything here is pure
/// formatting and input parsing over plain values, so it stays unit-testable
/// on its own and can never quietly become a second copy of a *core* rule.
///
/// The split to hold on to: money LADDER decisions (what to pre-fill, what the
/// API will accept) belong to the shared Rust core and are called through the
/// UniFFI boundary — `suggestedBidCents` / `minimumNextBidCents`. Only display
/// and text-field concerns live here.
enum LiveEventPresentation {
    // MARK: - Money

    /// Renders integer cents the way the web buyer surfaces do.
    ///
    /// Cents are the only representation that crosses the API and the FFI
    /// boundary; `Double` never holds a price here, it is used strictly to
    /// hand a already-exact value to the currency formatter.
    static func formatPrice(cents: Int64, locale: Locale = Locale(identifier: "en_US")) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = locale
        let dollars = Decimal(cents) / 100
        return formatter.string(from: dollars as NSDecimalNumber)
            ?? "$\(String(format: "%.2f", Double(cents) / 100))"
    }

    /// Parses what the buyer typed into the bid field.
    ///
    /// Mirrors `parseBidDollars` in `apps/web/src/auction.ts` exactly, including
    /// its strictness: digits with an optional 1–2 decimal places, nothing else.
    /// No currency symbols, no thousands separators, no leading `+`/`-`. Keeping
    /// the shapes identical means a buyer cannot get a bid accepted on one
    /// surface and rejected on another.
    static func parseBidDollars(_ value: String) -> Int64? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.wholeMatch(of: /\d+(\.\d{1,2})?/) != nil else { return nil }
        guard let dollars = Decimal(string: normalized, locale: Locale(identifier: "en_US")) else {
            return nil
        }
        // Rounding before the Int64 conversion keeps `12.34` from landing on
        // 1233 through a binary-fraction shortfall.
        var scaled = dollars * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let cents = NSDecimalNumber(decimal: rounded).int64Value
        return cents > 0 ? cents : nil
    }

    /// Formats cents back into the bare `12.34` the bid field accepts, so a
    /// pre-filled suggestion always survives a round trip through the parser.
    static func bidFieldText(cents: Int64) -> String {
        let dollars = Decimal(cents) / 100
        return NSDecimalNumber(decimal: dollars).stringValue
    }

    // MARK: - Countdown

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        // The API emits JavaScript `toISOString()`, which always carries
        // milliseconds; without this option the parse returns nil for every
        // real timestamp.
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func date(fromISO8601 value: String) -> Date? {
        timestampFormatter.date(from: value) ?? plainTimestampFormatter.date(from: value)
    }

    /// Whole seconds left, floored at zero. Mirrors the web `secondsRemaining`,
    /// which rounds UP so a partial second still reads as time on the clock.
    static func secondsRemaining(endsAt: String, now: Date = Date()) -> Int {
        guard let end = date(fromISO8601: endsAt) else { return 0 }
        return max(0, Int(ceil(end.timeIntervalSince(now))))
    }

    /// `M:SS` for a live countdown; the leading minute is unpadded like a timer.
    static func formatCountdown(seconds: Int) -> String {
        let clamped = max(0, seconds)
        return String(format: "%d:%02d", clamped / 60, clamped % 60)
    }

    // MARK: - Connection state

    /// One-line status for the connection chip.
    ///
    /// `Polling` is deliberately phrased as still-working rather than as an
    /// error: the sync is on its REST fallback and recovers on its own, so
    /// alarming the buyer would misrepresent what is happening.
    static func connectionLabel(_ state: LiveConnectionState) -> String {
        switch state {
        case .connecting: "Connecting…"
        case .live: "Live"
        case let .reconnecting(retryInSeconds):
            retryInSeconds > 0 ? "Reconnecting in \(retryInSeconds)s" : "Reconnecting…"
        }
    }
}

/// The connection state the screen renders, mapped from the core's
/// `LiveSyncStatus` by the view model so this stays FFI-free.
enum LiveConnectionState: Equatable {
    case connecting
    case live
    case reconnecting(retryInSeconds: Int)
}

/// Why the bid button is unavailable, so the screen can explain itself instead
/// of showing a dead control.
enum BidAvailability: Equatable {
    case ready(amountCents: Int64)
    case noAuction
    case auctionClosed
    case signedOut
    case amountNotANumber
    case belowMinimum(minimumCents: Int64)
    case submitting

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// Buyer-facing explanation, or `nil` when the bid can go through.
    func message(formatting format: (Int64) -> String = {
        LiveEventPresentation.formatPrice(cents: $0)
    }) -> String? {
        switch self {
        case .ready: nil
        case .noAuction: "Nothing is up for auction right now."
        case .auctionClosed: "This auction has closed."
        case .signedOut: "Sign in to bid."
        case .amountNotANumber: "Enter an amount like 24.50."
        case let .belowMinimum(minimum): "Bid at least \(format(minimum))."
        case .submitting: "Placing your bid…"
        }
    }
}
