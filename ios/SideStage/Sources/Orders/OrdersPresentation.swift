// SPDX-License-Identifier: MIT

import Foundation

/// Every formatting and wording rule the Orders screens use.
///
/// Pure and FFI-free on purpose: it takes scalars, returns strings, and imports
/// nothing from the core — so the whole rule set is testable on any machine,
/// including the Linux hosts where no Swift toolchain builds the app target.
/// `OrdersViewModel` does the talking to the core; this file does the deciding
/// about how the result reads.
///
/// The rules mirror `apps/web/src/OrdersTab.tsx` so an order reads identically
/// on both clients. Where the mobile core cannot supply what the web has, the
/// divergence is stated at the rule rather than papered over.
enum OrdersPresentation {
    // MARK: - Status

    /// Mirrors the web's `orderStatusLabel`, including its default.
    ///
    /// The unknown case deliberately falls through to "Pending" rather than
    /// echoing the raw token: a status the client has not been taught about is
    /// far more likely to be a new in-flight state than a finished one, and
    /// "Pending" is the reading that does not tell the buyer their money moved.
    static func statusLabel(_ status: String) -> String {
        switch status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "paid": return "Paid"
        case "accepted": return "Offer accepted"
        case "failed": return "Payment failed"
        case "expired": return "Offer expired"
        case "cancelled", "canceled": return "Cancelled"
        default: return "Pending"
        }
    }

    /// Whether a status should read as money-has-moved.
    ///
    /// Drives colour only. Kept separate from `statusLabel` so the colour rule
    /// cannot drift from the wording rule by being re-derived at a call site.
    static func isSettled(_ status: String) -> Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "paid" || normalized == "accepted"
    }

    /// Whether a status should read as something went wrong.
    static func isFailed(_ status: String) -> Bool {
        let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "failed" || normalized == "expired" || normalized == "cancelled"
            || normalized == "canceled"
    }

    // MARK: - Money

    /// One money formatter for the app — the same one the live room and checkout
    /// use, so a total cannot render one way on the receipt and another here.
    static func formatPrice(cents: Int64) -> String {
        LiveEventPresentation.formatPrice(cents: cents)
    }

    /// The item line: `2 × $24.00`, as the web joins quantity and unit price.
    static func itemLine(quantity: UInt32, unitPriceCents: Int64) -> String {
        "\(quantity) × \(formatPrice(cents: unitPriceCents))"
    }

    /// The web's footer note, shown only when shipping was actually charged.
    /// `nil` means render nothing — free or unshipped orders get no empty row.
    static func shippingNote(shippingCents: Int64) -> String? {
        guard shippingCents > 0 else { return nil }
        return "Includes \(formatPrice(cents: shippingCents)) shipping"
    }

    // MARK: - Dates

    /// Mirrors the web's `formatOrderDate`: medium date, short time, and the
    /// literal "Date unavailable" for anything that will not parse — an
    /// unparseable timestamp is data to report, not a reason to hide the order.
    static func formatDate(
        _ createdAt: String,
        locale: Locale = Locale(identifier: "en_US"),
        timeZone: TimeZone = .current
    ) -> String {
        guard let date = parseDate(createdAt) else { return "Date unavailable" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Parses the API's ISO-8601 timestamps.
    ///
    /// Tried with fractional seconds first and then without, because the API
    /// emits both shapes (`…:30.561Z` and `…:30Z`) and `ISO8601DateFormatter`
    /// rejects rather than tolerates the shape it was not configured for.
    static func parseDate(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: trimmed) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: trimmed)
    }

    /// Newest first, which is the only order a buyer looks for.
    ///
    /// Orders whose timestamp will not parse sort last rather than being
    /// dropped: they are still the buyer's orders, and silently losing one is a
    /// worse failure than showing it at the bottom with "Date unavailable".
    /// The comparison falls back to the id so the result is a total order and
    /// the list cannot reshuffle between two identical timestamps.
    static func isOrderedBefore(
        lhsCreatedAt: String,
        lhsID: String,
        rhsCreatedAt: String,
        rhsID: String
    ) -> Bool {
        switch (parseDate(lhsCreatedAt), parseDate(rhsCreatedAt)) {
        case let (lhs?, rhs?):
            return lhs == rhs ? lhsID < rhsID : lhs > rhs
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            return lhsID < rhsID
        }
    }

    // MARK: - Wording

    static let title = "My orders"

    static let emptyTitle = "No orders yet"

    /// Deliberately names all three ways an order can appear even though this
    /// screen can only load checkout orders today (see `ordersScopeNote`) —
    /// the buyer's mental model is what the sentence describes, not the API's.
    static let emptyMessage =
        "Checkouts, auction wins, and accepted offers will appear here."

    static let loadingMessage = "Gathering your orders…"

    static let coreUnavailableTitle = "Orders unavailable"

    static let coreUnavailableMessage =
        "The app could not reach SideStage. Check the connection and try again."

    static func failureMessage(detail: String?) -> String {
        guard let detail, !detail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Your orders could not be loaded."
        }
        return "Your orders could not be loaded: \(detail)"
    }

    static func orderReference(id: String) -> String {
        "Order \(id)"
    }

    static func itemCountLabel(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count) items"
    }

    /// What this screen can and cannot show, stated once.
    ///
    /// The mobile core's `orders()` reads `GET /checkout/orders`, which returns
    /// checkout orders only — so auction wins, accepted offers, seller names and
    /// the web's video snapshots do not cross the FFI yet. The web's Orders tab
    /// reads a richer buyer-orders shape. This is a real parity gap, tracked
    /// rather than faked: nothing here invents a field the core did not send.
    static let ordersScopeNote =
        "Auction wins and accepted offers are not on mobile yet."
}
