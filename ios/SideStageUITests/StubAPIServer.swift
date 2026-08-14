// SPDX-License-Identifier: MIT

import Foundation
import Network

/// A tiny HTTP server that stands in for the SideStage API, so the buyer loop
/// can be driven end to end against the real shipping binary.
///
/// ## Why this exists
///
/// The app under test is unmodified — there is no test-only branch inside it.
/// The only seam used is the one the app already has:
/// `SideStageClientFactory.resolveBaseURL` reads `SIDESTAGE_API_BASE_URL` from
/// the environment before anything else, and `XCUIApplication.launchEnvironment`
/// sets exactly that. So the test points the shipping client at this server and
/// then drives the UI like a buyer.
///
/// A stub is not a second-best choice here, it is the only available one: no
/// SideStage API exists in this workspace, and the whole buyer loop — including
/// the live room and bidding — is plain HTTP, with no WebSocket anywhere. That
/// last fact is what makes this possible at all.
///
/// ## What it is faithful to, and what it is not
///
/// The response shapes are taken from the Rust core's own serde models and its
/// recorded contract fixtures (`crates/sidestage-core/testdata/`), which are the
/// same definitions the client decodes with — so a field name or enum spelling
/// that is wrong here fails the test rather than passing quietly.
///
/// It is NOT a claim that the deployed API agrees with those models. The events,
/// catalog and cart fixtures were captured live on 2026-08-14; the checkout and
/// shipping ones were not (the capture recorded that `/shipping/rates` returned
/// no selectable rates with EasyPost unconfigured), so those shapes are
/// representative. A divergence between the models and a real server would pass
/// here. Closing that gap needs a contract test against a live API and is out of
/// this suite's reach.
///
/// ## Statefulness is the point
///
/// The server is deliberately stateful rather than a fixed set of canned
/// replies. A bid updates the auction the next snapshot returns; adding to the
/// cart changes what the cart endpoint serves; confirming checkout creates the
/// order that the Orders tab then lists. Canned replies would let the test pass
/// while the app dropped every mutation on the floor — which is exactly the
/// class of bug an end-to-end test is for.
final class StubAPIServer {
    // MARK: - Fixed identifiers the test asserts against

    enum Fixture {
        static let eventID = "sunday-drop"
        static let eventTitle = "Sunday vintage drop"
        static let sellerName = "Field Office"
        static let productID = "product-1"
        static let productTitle = "Vintage jacket"
        static let auctionID = "auction-1"
        static let cartID = "cart-1"
        static let orderID = "order-17"
        static let buyerID = "buyer-e2e"
        static let rateID = "rate-1"
        static let startingPriceCents = 2_400
        static let productPriceCents = 2_000
        static let shippingCents = 895
    }

    // MARK: - Lifecycle

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.sidestage.stub-api")
    private let state = State()

    /// The base URL to hand the app. Includes the `/api` prefix the client
    /// expects to sit in front of every route.
    private(set) var baseURL: String = ""

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        listener = try NWListener(using: parameters, on: .any)
    }

    /// Starts listening and returns once a port has actually been assigned.
    ///
    /// The wait is not optional: `NWListener.port` is nil until the listener
    /// reaches `.ready`, and a base URL built before then would point at port 0
    /// and fail every request with a connection error that looks exactly like a
    /// server that is not running.
    func start(timeout: TimeInterval = 10) throws {
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?

        listener.stateUpdateHandler = { newState in
            switch newState {
            case .ready:
                ready.signal()
            case let .failed(error):
                failure = error
                ready.signal()
            default:
                break
            }
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + timeout) == .success else {
            throw StubError.startTimedOut
        }
        if let failure { throw failure }
        guard let port = listener.port?.rawValue, port != 0 else {
            throw StubError.noPortAssigned
        }

        baseURL = "http://127.0.0.1:\(port)/api"
    }

    func stop() {
        listener.cancel()
    }

    enum StubError: Error {
        case startTimedOut
        case noPortAssigned
    }

    /// Requests the server has served, for assertions about what the app
    /// actually sent. A UI that renders the right thing for the wrong reason —
    /// or without ever calling the endpoint — is a passing test worth nothing.
    var servedRequests: [String] { state.servedRequests }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] chunk, _, isComplete, error in
            guard let self else { return }

            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if error != nil {
                connection.cancel()
                return
            }

            // Only dispatch once the whole request is in hand: headers, plus a
            // body of exactly Content-Length bytes. Network.framework delivers
            // whatever has arrived, and a POST body routinely lands in a second
            // read — parsing early would route a request with an empty body.
            if let request = HTTPRequest(buffer) {
                self.respond(to: request, on: connection)
                return
            }

            if isComplete {
                connection.cancel()
                return
            }

            self.receive(on: connection, buffer: buffer)
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) {
        state.record("\(request.method) \(request.path)")

        let (status, payload) = route(request)
        let body: Data
        let contentType: String

        switch payload {
        case let .json(value):
            body = (try? JSONSerialization.data(withJSONObject: value)) ?? Data("null".utf8)
            contentType = "application/json"
        case let .text(text):
            body = Data(text.utf8)
            contentType = "text/plain"
        case .eventStream:
            // Hold the stream open and send nothing. The core treats a silent
            // stream as a lost heartbeat and falls back to polling
            // rest-query-batch, which is a supported live path and a
            // deterministic one — where synthesising invalidation frames would
            // race the poller and make the test flaky.
            let head = """
            HTTP/1.1 200 OK\r
            Content-Type: text/event-stream\r
            Cache-Control: no-cache\r
            Connection: keep-alive\r
            \r
            : connected\n\n
            """
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            return
        }

        let head = """
        HTTP/1.1 \(status) \(Self.reason(status))\r
        Content-Type: \(contentType)\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r\n
        """

        var response = Data(head.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 404: return "Not Found"
        default: return "Error"
        }
    }

    // MARK: - Routing

    private enum Payload {
        case json(Any)
        case text(String)
        case eventStream
    }

    private func route(_ request: HTTPRequest) -> (Int, Payload) {
        // Every route the client builds sits under the /api prefix carried by
        // the base URL, so strip it once here rather than in every case.
        var path = request.path
        if path.hasPrefix("/api") { path = String(path.dropFirst(4)) }
        let segments = path.split(separator: "/").map(String.init)

        // ⚠ SWIFT HAS NO ARRAY DESTRUCTURING PATTERN. A `[...]` in a `case` is an
        // EXPRESSION pattern — it compiles to `segments == ["catalog", "types"]`.
        // That works fine for an all-literal route, which is why the fixed routes
        // below read like destructuring and behave correctly. But it means a
        // PARAMETERISED route cannot bind a segment inline:
        //
        //     case let ("GET", ["catalog", "variants", productID]):   // ✗
        //     error: pattern variable binding cannot appear in an expression
        //
        // The `_` spelling fails the same way ("'_' can only appear in a pattern").
        // So variable routes bind the whole array and test it in a `where` clause.
        switch (request.method, segments) {
        case ("GET", ["events"]):
            return (200, .json(["events": [state.eventJSON()]]))

        case ("GET", ["catalog"]):
            return (200, .json(state.catalogPageJSON()))

        case ("GET", ["catalog", "types"]):
            // A bare JSON array — product_types() decodes Vec<String> directly,
            // with no envelope.
            return (200, .json(["Jackets"]))

        case let ("GET", p) where p.count == 3 && p[0] == "catalog" && p[1] == "variants":
            return (200, .json(state.variantJSON(productID: p[2])))

        case ("POST", ["sync", "rest-query-batch"]):
            // Order matters and is not alphabetical: the core pops the auction
            // result first and the transcript second, so results[0] must be the
            // transcript. `version` is required, not optional.
            return (200, .json([
                "results": [
                    ["rows": state.transcriptRowsJSON(), "version": "1"],
                    ["rows": [state.auctionJSON()], "version": "1"],
                ],
            ]))

        case ("GET", ["sync", "sse"]):
            return (200, .eventStream)

        case let ("POST", p) where p.count == 3 && p[0] == "auctions" && p[2] == "bids":
            let amount = (request.jsonBody?["amountCents"] as? Int) ?? 0
            let bidder = (request.jsonBody?["bidderId"] as? String) ?? Fixture.buyerID
            state.placeBid(amountCents: amount, bidderID: bidder)
            return (200, .json(state.auctionJSON()))

        case ("POST", ["cart", "items"]):
            let quantity = (request.jsonBody?["quantity"] as? Int) ?? 1
            let productID = (request.jsonBody?["productId"] as? String) ?? Fixture.productID
            let title = (request.jsonBody?["title"] as? String) ?? Fixture.productTitle
            let priceCents = (request.jsonBody?["priceCents"] as? Int) ?? Fixture.productPriceCents
            state.addToCart(
                productID: productID,
                title: title,
                priceCents: priceCents,
                quantity: quantity
            )
            return (200, .json(state.cartJSON()))

        case let ("GET", p) where p.count == 2 && p[0] == "cart" && p[1] == Fixture.cartID:
            return (200, .json(state.cartJSON()))

        case ("POST", ["shipping", "rates"]):
            // A bare array again — shipping_rates() decodes Vec<ShippingRate>.
            return (200, .json([state.shippingRateJSON()]))

        case ("POST", ["checkout", "sessions"]):
            state.openOrder(from: request.jsonBody)
            return (200, .json([
                "order": state.orderJSON(status: "pending"),
                "session": state.paymentSessionJSON(),
            ]))

        case ("POST", ["checkout", "confirm"]):
            state.markOrderPaid()
            return (200, .json([
                "order": state.orderJSON(status: "paid"),
                "payment": ["status": "paid", "transactionId": "sandbox-txn-1"],
            ]))

        case ("GET", ["checkout", "orders"]):
            return (200, .json(["orders": state.placedOrdersJSON()]))

        default:
            // Loud rather than empty. A silent 200 with `[]` would let the app
            // render a plausible empty screen and the test pass while the real
            // route was never implemented.
            return (404, .text("stub has no route for \(request.method) \(path)"))
        }
    }
}

// MARK: - Mutable fixture state

/// The server's world. Guarded by a lock because Network.framework may deliver
/// connections concurrently and the UI drives several endpoints at once.
private final class State {
    private let lock = NSLock()

    private var cartItems: [[String: Any]] = []
    private var currentPriceCents = StubAPIServer.Fixture.startingPriceCents
    private var bids: [[String: Any]] = []
    private var orderStatus: String?
    private var requests: [String] = []

    private func withLock<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }

    var servedRequests: [String] { withLock { requests } }

    func record(_ line: String) { withLock { requests.append(line) } }

    // MARK: Mutations

    func placeBid(amountCents: Int, bidderID: String) {
        withLock {
            currentPriceCents = max(currentPriceCents, amountCents)
            bids.append([
                "id": "bid-\(bids.count + 1)",
                "bidderId": bidderID,
                "amountCents": amountCents,
                "createdAt": "2026-08-14T15:00:00Z",
            ])
        }
    }

    func addToCart(productID: String, title: String, priceCents: Int, quantity: Int) {
        withLock {
            if let index = cartItems.firstIndex(where: { $0["productId"] as? String == productID }) {
                let existing = (cartItems[index]["quantity"] as? Int) ?? 0
                cartItems[index]["quantity"] = existing + quantity
            } else {
                cartItems.append([
                    "productId": productID,
                    "title": title,
                    "priceCents": priceCents,
                    "quantity": quantity,
                ])
            }
        }
    }

    func openOrder(from body: [String: Any]?) {
        withLock { orderStatus = "pending" }
    }

    func markOrderPaid() {
        withLock { orderStatus = "paid" }
    }

    // MARK: Serialisation

    func eventJSON() -> [String: Any] {
        [
            "eventId": StubAPIServer.Fixture.eventID,
            "title": StubAPIServer.Fixture.eventTitle,
            "sellerId": "seller-1",
            "sellerName": StubAPIServer.Fixture.sellerName,
            "status": "live",
            "startsAt": NSNull(),
            "endedAt": NSNull(),
            "viewers": 12,
        ]
    }

    func variantJSON(productID: String) -> [String: Any] {
        [
            "id": productID,
            "groupId": NSNull(),
            "title": StubAPIServer.Fixture.productTitle,
            "brand": "Field Office",
            "productType": "Jackets",
            "sku": "SKU-1",
            "condition": "Good",
            "handlingDays": 2,
            "priceCents": StubAPIServer.Fixture.productPriceCents,
            "availableQty": 3,
        ]
    }

    func catalogPageJSON() -> [String: Any] {
        [
            "rows": [variantJSON(productID: StubAPIServer.Fixture.productID)],
            "page": 1,
            "pageSize": 24,
            "total": 1,
            "totalIsFloor": false,
        ]
    }

    func transcriptRowsJSON() -> [[String: Any]] {
        [[
            "id": "message-1",
            "eventId": StubAPIServer.Fixture.eventID,
            "userId": "seller-1",
            "displayName": StubAPIServer.Fixture.sellerName,
            "role": "seller",
            "text": "Welcome in.",
            "createdAt": "2026-08-14T15:00:00Z",
        ]]
    }

    func auctionJSON() -> [String: Any] {
        withLock {
            [
                "id": StubAPIServer.Fixture.auctionID,
                "eventId": StubAPIServer.Fixture.eventID,
                "eventItemId": "event-item-1",
                "productId": StubAPIServer.Fixture.productID,
                "quantity": 1,
                "startingPriceCents": StubAPIServer.Fixture.startingPriceCents,
                "currentPriceCents": currentPriceCents,
                "status": "active",
                "startedAt": "2026-08-14T15:00:00Z",
                // Far enough out that the countdown cannot expire mid-test and
                // close the auction underneath the bid control.
                "endsAt": "2099-01-01T00:00:00Z",
                "bids": bids,
            ]
        }
    }

    func cartJSON() -> [String: Any] {
        withLock {
            let subtotal = cartItems.reduce(0) { total, item in
                total + ((item["priceCents"] as? Int) ?? 0) * ((item["quantity"] as? Int) ?? 0)
            }
            return [
                "id": StubAPIServer.Fixture.cartID,
                "currency": "USD",
                "items": cartItems,
                "subtotalCents": subtotal,
                "updatedAt": "2026-08-14T15:00:00Z",
            ]
        }
    }

    func shippingRateJSON() -> [String: Any] {
        [
            "id": StubAPIServer.Fixture.rateID,
            "carrier": "USPS",
            "service": "Priority",
            "totalCents": StubAPIServer.Fixture.shippingCents,
            "deliveryDays": 3,
            "parcelCount": 1,
            "quotedAt": "2026-08-14T15:00:00Z",
        ]
    }

    func paymentSessionJSON() -> [String: Any] {
        withLock {
            let subtotal = cartItems.reduce(0) { total, item in
                total + ((item["priceCents"] as? Int) ?? 0) * ((item["quantity"] as? Int) ?? 0)
            }
            return [
                "provider": "square",
                "mode": "sandbox",
                // kebab-case in the core: the other spelling here is
                // "needs-configuration", which is what drives the
                // buyer.checkout.needsConfiguration branch.
                "status": "ready",
                "appId": "sandbox-app",
                "locationId": "sandbox-location",
                "orderId": StubAPIServer.Fixture.orderID,
                "amountCents": subtotal + StubAPIServer.Fixture.shippingCents,
                "currency": "USD",
            ]
        }
    }

    func orderJSON(status: String) -> [String: Any] {
        let items = withLock { cartItems }
        let subtotal = items.reduce(0) { total, item in
            total + ((item["priceCents"] as? Int) ?? 0) * ((item["quantity"] as? Int) ?? 0)
        }
        return [
            "id": StubAPIServer.Fixture.orderID,
            "cartId": StubAPIServer.Fixture.cartID,
            "buyerId": StubAPIServer.Fixture.buyerID,
            "eventId": StubAPIServer.Fixture.eventID,
            "subtotalCents": subtotal,
            "shippingCents": StubAPIServer.Fixture.shippingCents,
            "totalCents": subtotal + StubAPIServer.Fixture.shippingCents,
            "currency": "USD",
            "status": status,
            "createdAt": "2026-08-14T15:00:00Z",
            "items": items,
            "paymentSession": paymentSessionJSON(),
        ]
    }

    /// Empty until checkout actually completes. That emptiness is load-bearing:
    /// it is what makes the Orders assertion evidence that the purchase created
    /// the order, rather than evidence that a fixture was always there.
    func placedOrdersJSON() -> [[String: Any]] {
        guard let status = withLock({ orderStatus }) else { return [] }
        return [orderJSON(status: status)]
    }
}

// MARK: - Minimal HTTP request parsing

private struct HTTPRequest {
    let method: String
    let path: String
    let body: Data

    var jsonBody: [String: Any]? {
        guard !body.isEmpty else { return nil }
        return (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    /// Returns nil while the request is still incomplete, which is the signal to
    /// keep reading rather than to fail.
    init?(_ buffer: Data) {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }

        let headerData = buffer[buffer.startIndex ..< headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerText.components(separatedBy: "\r\n")
        let requestLine = lines[0].split(separator: " ")
        guard requestLine.count >= 2 else { return nil }

        method = String(requestLine[0])
        // The query string is dropped deliberately: every route dispatches on
        // path alone, and the app's own query parameters (catalog paging,
        // buyerId) are not what this stub varies on.
        path = String(requestLine[1].split(separator: "?").first ?? "")

        let contentLength = lines
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0

        let bodyStart = headerEnd.upperBound
        let available = buffer.distance(from: bodyStart, to: buffer.endIndex)
        guard available >= contentLength else { return nil }

        body = buffer[bodyStart ..< buffer.index(bodyStart, offsetBy: contentLength)]
    }
}
