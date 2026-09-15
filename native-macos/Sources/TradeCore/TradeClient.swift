import Foundation

/// A transport owns its authentication session. Implementations must keep requests and redirects
/// on the official HTTPS trade API; the client never reads or copies browser credentials.
public protocol TradeHTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct TradeListingGroup: Identifiable, Sendable {
    public var id: String { listing.id }
    public let listing: TradeListing
    public var listedTimes: Int
    public var stock: Int?
}

public struct TradeSearchPage: Codable, Sendable {
    public let searchID: String
    public let total: Int
    public let listings: [TradeListing]
    public let resultIDs: [String]
    public let fetchedCount: Int
    public var hasMore: Bool { fetchedCount < resultIDs.count }

    public func groupedListings(collapseMerchant: Bool = false) -> [TradeListingGroup] {
        var groups: [TradeListingGroup] = []
        for listing in listings {
            let existing = groups.indices.first { index in
                let previous = groups[index].listing
                return previous.account == listing.account &&
                    ((previous.priceCurrency == listing.priceCurrency && previous.priceAmount == listing.priceAmount) ||
                     groups.count - index <= 2)
            }
            if let existing, listing.fee == nil || collapseMerchant {
                if let stock = groups[existing].stock {
                    groups[existing].stock = stock + (listing.stackSize ?? 0)
                } else { groups[existing].listedTimes += 1 }
            } else {
                groups.append(TradeListingGroup(listing: listing, listedTimes: 1, stock: listing.stackSize))
            }
        }
        return groups
    }

    public init(searchID: String, total: Int, listings: [TradeListing],
                resultIDs: [String] = [], fetchedCount: Int? = nil) {
        self.searchID = searchID
        self.total = total
        self.listings = listings
        self.resultIDs = resultIDs
        self.fetchedCount = fetchedCount ?? listings.count
    }

    private enum CodingKeys: String, CodingKey { case searchID, total, listings, resultIDs, fetchedCount }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        searchID = try container.decode(String.self, forKey: .searchID)
        total = try container.decode(Int.self, forKey: .total)
        listings = try container.decode([TradeListing].self, forKey: .listings)
        resultIDs = try container.decodeIfPresent([String].self, forKey: .resultIDs) ?? []
        fetchedCount = try container.decodeIfPresent(Int.self, forKey: .fetchedCount) ?? listings.count
    }
}

public struct TradeListing: Codable, Identifiable, Sendable {
    public let id: String
    public let itemName: String
    public let account: String
    public let priceAmount: Double?
    public let priceCurrency: String?
    public let indexed: String?
    public let online: Bool
    public let itemLevel: Int?
    public let stackSize: Int?
    public let quality: String?
    public let gemLevel: String?
    public let lastCharacterName: String?
    public let accountStatus: String?
    public let whisper: String?
    public let stashName: String?
    public let stashX: Int?
    public let stashY: Int?
    public let fee: Double?
    public let hasNote: Bool?

    public init(id: String, itemName: String, account: String, priceAmount: Double?,
                priceCurrency: String?, indexed: String?, online: Bool,
                itemLevel: Int? = nil, stackSize: Int? = nil,
                quality: String? = nil, gemLevel: String? = nil,
                lastCharacterName: String? = nil, accountStatus: String? = nil,
                whisper: String? = nil, stashName: String? = nil,
                stashX: Int? = nil, stashY: Int? = nil, fee: Double? = nil, hasNote: Bool? = nil) {
        self.id = id
        self.itemName = itemName
        self.account = account
        self.priceAmount = priceAmount
        self.priceCurrency = priceCurrency
        self.indexed = indexed
        self.online = online
        self.itemLevel = itemLevel
        self.stackSize = stackSize
        self.quality = quality
        self.gemLevel = gemLevel
        self.lastCharacterName = lastCharacterName
        self.accountStatus = accountStatus
        self.whisper = whisper
        self.stashName = stashName
        self.stashX = stashX
        self.stashY = stashY
        self.fee = fee
        self.hasNote = hasNote
    }
}

public struct TradeExchangePage: Codable, Sendable {
    public let searchID: String
    public let total: Int
    public let offers: [TradeExchangeOffer]
    public let requestedCurrencies: [String]

    public init(searchID: String, total: Int, offers: [TradeExchangeOffer], requestedCurrencies: [String] = []) {
        self.searchID = searchID
        self.total = total
        self.offers = offers
        self.requestedCurrencies = requestedCurrencies
    }
}

public struct TradeExchangeOffer: Codable, Identifiable, Sendable {
    public let id: String
    public let listingID: String
    public let exchangeCurrency: String
    public let exchangeAmount: Double
    public let itemCurrency: String?
    public let itemAmount: Double
    public let stock: Double
    public let account: String
    public let lastCharacterName: String?
    public let accountStatus: String
    public let indexed: String?
    public let whisper: String?
    public var unitPrice: Double { exchangeAmount / itemAmount }

    public init(id: String, listingID: String, exchangeCurrency: String, exchangeAmount: Double,
                itemCurrency: String? = nil, itemAmount: Double, stock: Double, account: String,
                lastCharacterName: String? = nil, accountStatus: String, indexed: String? = nil,
                whisper: String? = nil) {
        self.id = id
        self.listingID = listingID
        self.exchangeCurrency = exchangeCurrency
        self.exchangeAmount = exchangeAmount
        self.itemCurrency = itemCurrency
        self.itemAmount = itemAmount
        self.stock = stock
        self.account = account
        self.lastCharacterName = lastCharacterName
        self.accountStatus = accountStatus
        self.indexed = indexed
        self.whisper = whisper
    }
}

public enum TradeClientError: Error, LocalizedError, Sendable {
    case invalidRequest(String)
    case malformedResponse(String)
    case http(statusCode: Int, message: String, retryAfter: TimeInterval?)

    public var retryAfter: TimeInterval? {
        if case let .http(_, _, value) = self { return value }
        return nil
    }

    public var errorDescription: String? {
        switch self {
        case let .invalidRequest(message), let .malformedResponse(message): return message
        case let .http(_, message, _): return message
        }
    }
}

/// A single client serializes its requests and spaces their start times by at least five seconds.
/// Requests are never retried automatically, including search POSTs.
public actor TradeClient {
    private let session: URLSession
    private let minimumRequestInterval: TimeInterval
    private var requestInProgress = false
    private var nextRequestAt = Date.distantPast
    private var extraDelay: TimeInterval = 0

    public init(session: URLSession = .shared, minimumRequestInterval: TimeInterval = 5) {
        self.session = session
        self.minimumRequestInterval = minimumRequestInterval.isFinite
            ? max(0, minimumRequestInterval) : 5
    }

    public func setExtraDelay(_ seconds: TimeInterval) {
        extraDelay = seconds.isFinite ? min(max(seconds, 0), 10) : 0
    }

    public func leagues(transport: (any TradeHTTPTransport)? = nil) async throws -> [String] {
        let data = try await request(url: Self.url(path: ["api", "trade", "data", "leagues"])!, transport: transport)
        let response: LeagueResponse = try decode(data)
        var seen = Set<String>()
        return response.result.map(\.id).filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && seen.insert($0).inserted
        }
    }

    public func search(queryJSON: String, league: String,
                       transport: (any TradeHTTPTransport)? = nil,
                       representativeResults: Bool = true, collapseMerchant: Bool = false) async throws -> TradeSearchPage {
        try Task.checkCancellation()
        guard !league.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TradeClientError.invalidRequest("Choose a league before searching.")
        }
        guard let body = queryJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              object["query"] is [String: Any] else {
            throw TradeClientError.invalidRequest("The trade query must be a JSON object containing a query object.")
        }
        let searchData = try await request(
            url: Self.url(path: ["api", "trade", "search", league])!, body: body, transport: transport
        )
        let search: SearchResponse = try decode(searchData)
        guard !search.id.isEmpty, search.total >= 0,
              search.result.allSatisfy({ !$0.isEmpty }) else {
            throw TradeClientError.malformedResponse("The trade service returned an invalid search result.")
        }
        var page = try await fetchMore(page: TradeSearchPage(searchID: search.id, total: search.total,
                                                       listings: [], resultIDs: search.result, fetchedCount: 0),
                                   transport: transport)
        if representativeResults {
            while page.hasMore && page.fetchedCount < 100 {
                let groups = page.groupedListings(collapseMerchant: collapseMerchant)
                if page.fetchedCount >= 20 && groups.count >= 10 && groups.filter({ $0.listedTimes <= 2 }).count >= 7 { break }
                page = try await fetchMore(page: page, transport: transport)
            }
        }
        return page
    }

    /// Bulk offers are returned by the exchange POST itself; they do not use the listing fetch endpoint.
    public func exchange(queryJSON: String, league: String,
                         transport: (any TradeHTTPTransport)? = nil) async throws -> TradeExchangePage {
        try Task.checkCancellation()
        guard !league.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TradeClientError.invalidRequest("Choose a league before searching.")
        }
        guard let body = queryJSON.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let query = object["query"] as? [String: Any],
              let have = query["have"] as? [String], !have.isEmpty,
              let want = query["want"] as? [String], !want.isEmpty,
              (have + want).allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw TradeClientError.invalidRequest("The exchange query must specify currencies to pay and items to buy.")
        }
        let data = try await request(url: Self.url(path: ["api", "trade", "exchange", league])!,
                                     body: body, transport: transport)
        let response: ExchangeResponse = try decode(data)
        guard !response.id.isEmpty, response.total >= 0 else {
            throw TradeClientError.malformedResponse("The trade service returned an invalid exchange result.")
        }
        var offers: [TradeExchangeOffer] = []
        for key in response.result.keys.sorted() {
            guard let result = response.result[key] else { continue }
            guard !result.id.isEmpty else {
                throw TradeClientError.malformedResponse("The trade service returned an exchange offer without an identifier.")
            }
            let listing = result.listing
            for (index, offer) in listing.offers.enumerated() {
                guard have.contains(offer.exchange.currency),
                      offer.exchange.amount.isFinite, offer.exchange.amount > 0,
                      offer.item.amount.isFinite, offer.item.amount > 0,
                      offer.item.stock.isFinite, offer.item.stock >= 0,
                      (offer.exchange.amount / offer.item.amount).isFinite else {
                    throw TradeClientError.malformedResponse("The trade service returned an invalid exchange price or stock amount.")
                }
                offers.append(TradeExchangeOffer(
                    id: "\(result.id):\(index)", listingID: result.id,
                    exchangeCurrency: offer.exchange.currency, exchangeAmount: offer.exchange.amount,
                    itemCurrency: offer.item.currency ?? (want.count == 1 ? want[0] : nil),
                    itemAmount: offer.item.amount, stock: offer.item.stock,
                    account: listing.account.name, lastCharacterName: listing.account.lastCharacterName,
                    accountStatus: listing.account.online == nil ? "offline" : listing.account.online?.status == "afk" ? "afk" : "online",
                    indexed: listing.indexed,
                    whisper: Self.exchangeWhisper(listing.whisper, itemTemplate: offer.item.whisper,
                                                  itemAmount: offer.item.amount, exchangeTemplate: offer.exchange.whisper,
                                                  exchangeAmount: offer.exchange.amount)
                ))
            }
        }
        let ordered = offers.sorted { left, right in
            if left.exchangeCurrency != right.exchangeCurrency {
                return (have.firstIndex(of: left.exchangeCurrency) ?? have.count) < (have.firstIndex(of: right.exchangeCurrency) ?? have.count)
            }
            if left.unitPrice != right.unitPrice { return left.unitPrice < right.unitPrice }
            return left.id < right.id
        }
        return TradeExchangePage(searchID: response.id, total: response.total, offers: ordered,
                                 requestedCurrencies: have)
    }

    /// The exchange API supplies currency wording separately for each offer. Resolve one listed
    /// bulk lot, keeping server text intact; incomplete templates must never reach the clipboard.
    private nonisolated static func exchangeWhisper(_ template: String?, itemTemplate: String?, itemAmount: Double,
                                                    exchangeTemplate: String?, exchangeAmount: Double) -> String? {
        guard var text = template, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.usesSignificantDigits = true
        formatter.minimumSignificantDigits = 1
        formatter.maximumSignificantDigits = 15
        for (placeholder, part, amount) in [("{0}", itemTemplate, itemAmount), ("{1}", exchangeTemplate, exchangeAmount)] {
            guard text.contains(placeholder) else { continue }
            guard let part, part.contains("{0}"), amount.isFinite, amount > 0,
                  let number = formatter.string(from: NSNumber(value: amount)) else { return nil }
            let filled = part.replacingOccurrences(of: "{0}", with: number)
            guard !filled.contains("{"), !filled.contains("}") else { return nil }
            text = text.replacingOccurrences(of: placeholder, with: filled)
        }
        guard !text.contains("{"), !text.contains("}") else { return nil }
        return text
    }

    /// Fetches the next ten IDs from the original search, preserving its order and search identifier.
    /// Disappeared listings still advance the cursor, so loading more never repeats or skips an ID.
    public func fetchMore(page: TradeSearchPage,
                          transport: (any TradeHTTPTransport)? = nil) async throws -> TradeSearchPage {
        try Task.checkCancellation()
        guard !page.searchID.isEmpty, page.fetchedCount >= 0,
              page.fetchedCount <= page.resultIDs.count,
              page.resultIDs.allSatisfy({ !$0.isEmpty }) else {
            throw TradeClientError.invalidRequest("This search cannot load more listings. Refresh the search first.")
        }
        guard page.hasMore else { return page }
        let ids = Array(page.resultIDs.dropFirst(page.fetchedCount).prefix(10))
        var fetchURL = URLComponents()
        fetchURL.scheme = "https"
        fetchURL.host = "www.pathofexile.com"
        fetchURL.percentEncodedPath = "/api/trade/fetch/" + ids.map(Self.encodePathComponent).joined(separator: ",")
        fetchURL.queryItems = [URLQueryItem(name: "query", value: page.searchID)]
        Self.encodeQueryPluses(&fetchURL)
        let fetchedData = try await request(url: fetchURL.url!, transport: transport)
        let fetched: FetchResponse = try decode(fetchedData)
        // A listing can disappear between search and fetch; the API represents this with null.
        let requestedIDs = Set(ids)
        var byID: [String: TradeListing] = [:]
        for result in fetched.result.compactMap({ $0 }) where requestedIDs.contains(result.id) {
            let parts = [result.item.name, result.item.typeLine ?? result.item.baseType]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let online = result.listing.account.online != nil || result.listing.fee != nil
            let accountStatus = !online ? "offline" : result.listing.account.online?.status == "afk" ? "afk" : "online"
            byID[result.id] = TradeListing(
                id: result.id, itemName: parts.isEmpty ? "Unnamed item" : parts.joined(separator: " "),
                account: result.listing.account.name,
                priceAmount: result.listing.price?.amount, priceCurrency: result.listing.price?.currency,
                indexed: result.listing.indexed, online: online,
                itemLevel: result.item.propertyValue(type: 78, names: ["item level"]).flatMap(Int.init) ?? result.item.ilvl,
                stackSize: result.item.stackSize,
                quality: result.item.propertyValue(type: 6, names: ["quality"]),
                gemLevel: result.item.propertyValue(type: 5, names: ["level", "gem level"]),
                lastCharacterName: result.listing.account.lastCharacterName, accountStatus: accountStatus,
                whisper: result.listing.whisper, stashName: result.listing.stash?.name,
                stashX: result.listing.stash?.x, stashY: result.listing.stash?.y,
                fee: result.listing.fee, hasNote: result.item.note != nil
            )
        }
        var seen = Set(page.listings.map(\.id))
        let additional = ids.compactMap { id -> TradeListing? in
            guard seen.insert(id).inserted else { return nil }
            return byID[id]
        }
        return TradeSearchPage(searchID: page.searchID, total: page.total, listings: page.listings + additional,
                               resultIDs: page.resultIDs, fetchedCount: page.fetchedCount + ids.count)
    }

    public nonisolated static func browserURL(league: String, queryJSON: String) -> URL? {
        guard !league.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return url(path: ["trade", "search", league], queryItems: [URLQueryItem(name: "q", value: queryJSON)])
    }

    public nonisolated static func resultURL(league: String, searchID: String) -> URL? {
        guard !league.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !searchID.isEmpty else { return nil }
        return url(path: ["trade", "search", league, searchID])
    }

    public nonisolated static func exchangeResultURL(league: String, searchID: String) -> URL? {
        guard !league.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !searchID.isEmpty else { return nil }
        return url(path: ["trade", "exchange", league, searchID])
    }

    private func request(url: URL, body: Data? = nil,
                         transport: (any TradeHTTPTransport)? = nil) async throws -> Data {
        guard Self.isOfficialTradeAPI(url) else {
            throw TradeClientError.invalidRequest("Trade requests must use the official Path of Exile HTTPS API.")
        }
        try await waitForRequestSlot()
        defer { requestInProgress = false }
        try Task.checkCancellation()
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("AwakenedPoeTradeNative/0.1", forHTTPHeaderField: "User-Agent")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }

        let data: Data
        let response: URLResponse
        do {
            if let transport { (data, response) = try await transport.data(for: request) }
            else { (data, response) = try await session.data(for: request) }
        } catch {
            try Task.checkCancellation()
            if (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw TradeClientError.malformedResponse("The trade service did not return an HTTP response.")
        }
        guard let responseURL = http.url, Self.isOfficialTradeAPI(responseURL) else {
            throw TradeClientError.malformedResponse("The request left the official trade API. Open the trade site to check your sign-in, then try again.")
        }
        // Account/IP usage can include other clients. With no reset timestamp, waiting a full
        // exhausted window is conservative and keeps the shared queue within the server's limits.
        let serverDelay = Self.serverRateLimitDelay(http)
        if serverDelay > 0 {
            nextRequestAt = max(nextRequestAt, Date().addingTimeInterval(serverDelay))
        }
        try Task.checkCancellation()
        let apiError = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data))?.error?.message
        guard (200..<300).contains(http.statusCode) else {
            let retry = Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After"))
            if http.statusCode == 429 {
                nextRequestAt = max(nextRequestAt, Date().addingTimeInterval(retry ?? 60))
            }
            let message: String
            switch http.statusCode {
            case 403:
                message = "Path of Exile blocked this request (403). Open the search in your browser to complete any sign-in or browser verification."
            case 429:
                let delay = String(format: "%.0f", ceil(retry ?? 60))
                message = "Path of Exile is rate limiting requests (429). Wait at least \(delay) seconds before trying again."
            case 401:
                message = "Path of Exile requires sign-in (401). Open the search in your browser."
            default:
                message = "Trade request failed (HTTP \(http.statusCode))." + (apiError.map { " \($0)" } ?? "")
            }
            throw TradeClientError.http(statusCode: http.statusCode, message: message, retryAfter: retry)
        }
        if let apiError {
            throw TradeClientError.malformedResponse("Trade service: \(apiError)")
        }
        if http.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/html") == true ||
            data.first(where: { ![9, 10, 13, 32].contains($0) }) == 60 {
            throw TradeClientError.malformedResponse("Path of Exile returned a sign-in or browser verification page. Open the trade site and complete it before trying again.")
        }
        return data
    }

    private func waitForRequestSlot() async throws {
        while true {
            try Task.checkCancellation()
            let delay = nextRequestAt.addingTimeInterval(extraDelay).timeIntervalSinceNow
            if !requestInProgress && delay <= 0 {
                requestInProgress = true
                nextRequestAt = Date().addingTimeInterval(minimumRequestInterval)
                return
            }
            // A short cancellable sleep also allows other actor calls to finish an active request.
            let interval = requestInProgress ? 0.05 : min(max(delay, 0.01), 0.1)
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
    }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch {
            throw TradeClientError.malformedResponse("The trade service returned data this app could not read. Try opening the search in your browser.")
        }
    }

    private nonisolated static func url(path: [String], queryItems: [URLQueryItem] = []) -> URL? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "www.pathofexile.com"
        components.percentEncodedPath = "/" + path.map(encodePathComponent).joined(separator: "/")
        if !queryItems.isEmpty { components.queryItems = queryItems }
        encodeQueryPluses(&components)
        return components.url
    }

    private nonisolated static func encodePathComponent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
    }

    private nonisolated static func isOfficialTradeAPI(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "www.pathofexile.com" &&
            (url.port == nil || url.port == 443) && url.user == nil && url.password == nil &&
            url.path.hasPrefix("/api/trade/")
    }

    private nonisolated static func encodeQueryPluses(_ components: inout URLComponents) {
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }

    private nonisolated static func retryAfter(_ header: String?) -> TimeInterval? {
        guard let header else { return nil }
        if let seconds = TimeInterval(header.trimmingCharacters(in: .whitespacesAndNewlines)), seconds.isFinite {
            return max(0, seconds)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { max(0, $0.timeIntervalSinceNow) }
    }

    /// Rules contain max:window:configuredPenalty; state contains spent:window:activePenalty.
    /// Match windows by duration, rather than position, so reordered or partial states are safe.
    nonisolated static func serverRateLimitDelay(_ response: HTTPURLResponse) -> TimeInterval {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }
        var rules = Set<String>()
        for header in ["x-rate-limit-rules", "x-rate-limit"] {
            for rule in (headers[header] ?? "").split(separator: ",") {
                rules.insert(rule.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
            }
        }
        let prefix = "x-rate-limit-", suffix = "-state"
        for name in headers.keys where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
            rules.insert(String(name.dropFirst(prefix.count).dropLast(suffix.count)))
        }
        var delay: TimeInterval = 0
        for rule in rules {
            guard !rule.isEmpty,
                  rule.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-").contains($0) }),
                  let limits = headers[prefix + rule], let states = headers[prefix + rule + suffix] else { continue }
            let windows = rateLimitTriples(limits)
            for state in rateLimitTriples(states) {
                guard state.window > 0,
                      let limit = windows.filter({ $0.window == state.window && $0.count > 0 })
                        .min(by: { $0.count < $1.count }) else { continue }
                delay = max(delay, state.penalty)
                if state.count >= limit.count { delay = max(delay, limit.window) }
            }
        }
        return delay
    }

    private nonisolated static func rateLimitTriples(_ header: String) -> [(count: Double, window: Double, penalty: Double)] {
        header.split(separator: ",").compactMap { part in
            let values = part.split(separator: ":", omittingEmptySubsequences: false)
            guard values.count == 3 else { return nil }
            let parsed = values.compactMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            guard parsed.count == 3, parsed.allSatisfy({ $0.isFinite && $0 >= 0 }) else { return nil }
            return (parsed[0], parsed[1], parsed[2])
        }
    }
}

private struct LeagueResponse: Decodable {
    struct League: Decodable { let id: String }
    let result: [League]
}

private struct SearchResponse: Decodable {
    let id: String
    let total: Int
    let result: [String]
}

private struct ExchangeResponse: Decodable {
    struct Result: Decodable {
        struct Listing: Decodable {
            struct Offer: Decodable {
                struct Exchange: Decodable { let currency: String; let amount: Double; let whisper: String? }
                struct Item: Decodable { let currency: String?; let amount: Double; let stock: Double; let whisper: String? }
                let exchange: Exchange
                let item: Item
            }
            let indexed: String?
            let offers: [Offer]
            let account: FetchResponse.Result.Listing.Account
            let whisper: String?
        }
        let id: String
        let listing: Listing
    }
    let id: String
    let total: Int
    let result: [String: Result]

    private enum CodingKeys: String, CodingKey { case id, total, result }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        total = try container.decode(Int.self, forKey: .total)
        do {
            result = try container.decode([String: Result].self, forKey: .result)
        } catch {
            // The exchange endpoint can represent an empty result collection as [] rather than {}.
            // Accept only an empty array; retain the original error for malformed listings or other shapes.
            guard let array = try? container.nestedUnkeyedContainer(forKey: .result), array.isAtEnd else { throw error }
            result = [:]
        }
    }
}

private struct APIErrorEnvelope: Decodable {
    struct APIError: Decodable { let message: String }
    let error: APIError?
}

private struct FetchResponse: Decodable {
    struct Result: Decodable {
        struct Item: Decodable {
            struct Property: Decodable {
                struct Value: Decodable {
                    let text: String?

                    init(from decoder: Decoder) throws {
                        // The API uses [display text, colour code]; only the text is shown here.
                        var pair = try decoder.unkeyedContainer()
                        text = pair.isAtEnd ? nil : try pair.decodeIfPresent(String.self)
                    }
                }

                let name: String?
                let type: Int?
                let values: [Value]
            }

            let name: String?
            let typeLine: String?
            let baseType: String?
            let ilvl: Int?
            let stackSize: Int?
            let properties: [Property]?
            let note: String?

            func propertyValue(type: Int, names: Set<String>) -> String? {
                let properties = properties ?? []
                let matches = properties.filter { $0.type == type } + properties.filter {
                    $0.type == nil && names.contains(($0.name ?? "").lowercased())
                }
                return matches.compactMap { $0.values.first?.text }
                    .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            }
        }
        struct Listing: Decodable {
            struct Price: Decodable { let amount: Double; let currency: String }
            struct Stash: Decodable { let name: String?; let x: Int?; let y: Int? }
            struct Account: Decodable {
                struct Online: Decodable { let league: String?; let status: String? }
                let name: String
                let online: Online?
                let lastCharacterName: String?
            }
            let indexed: String?
            let price: Price?
            let account: Account
            let whisper: String?
            let stash: Stash?
            let fee: Double?
        }
        let id: String
        let item: Item
        let listing: Listing
    }
    let result: [Result?]
}
