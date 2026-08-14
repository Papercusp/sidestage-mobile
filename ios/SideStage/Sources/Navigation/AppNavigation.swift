// SPDX-License-Identifier: MIT

import Foundation

enum MobileTab: String, CaseIterable, Identifiable {
    case buyer
    case orders

    static let initial: MobileTab = .buyer

    var id: Self { self }

    var title: String {
        switch self {
        case .buyer: "Buyer"
        case .orders: "Orders"
        }
    }

    var symbolName: String {
        switch self {
        case .buyer: "play.rectangle.fill"
        case .orders: "shippingbox.fill"
        }
    }
}

enum BuyerRoute: Hashable {
    case liveEvent(id: String, title: String)
    case cart
    /// Carries the event the cart was filled from: `createCheckoutSession`
    /// requires an `eventId`, and checkout is reachable from the cart screen
    /// where the originating room is no longer on screen to supply it.
    case checkout(eventID: String)
}

enum OrdersRoute: Hashable {
    case order(id: String)
}

struct BuyerFeedItem: Identifiable, Hashable {
    let id: String
    let title: String
    let sellerName: String
    let isLive: Bool
}
