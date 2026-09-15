import Foundation

public struct MarketQuery: Codable, Hashable, Sendable {
    public let ns: String
    public let name: String
    public let variant: String?
    public init(ns: String, name: String, variant: String? = nil) {
        self.ns = ns; self.name = name; self.variant = variant
    }
}

public struct MarketRelatedItem: Codable, Hashable, Sendable {
    public let name: String
    public let query: MarketQuery
    public let highlighted: Bool
    public init(name: String, query: MarketQuery, highlighted: Bool = false) {
        self.name = name; self.query = query; self.highlighted = highlighted
    }
}

/// Query metadata comes from the shared Windows getDetailsId and ITEM_DROP data.
public struct MarketItemMetadata: Codable, Hashable, Sendable {
    public let query: MarketQuery?
    public let related: [MarketRelatedItem]
    public let stackSize: Int?
    public let stackMax: Int?
    public let dustEquivalent: Double?
    public let predictionEligible: Bool
    public init(query: MarketQuery?, related: [MarketRelatedItem] = [], stackSize: Int? = nil,
                stackMax: Int? = nil, dustEquivalent: Double? = nil, predictionEligible: Bool = false) {
        self.query = query; self.related = related; self.stackSize = stackSize
        self.stackMax = stackMax; self.dustEquivalent = dustEquivalent; self.predictionEligible = predictionEligible
    }
}

public struct MarketQuote: Sendable {
    public let query: MarketQuery
    public let chaos: Double
    public let graph: [Double?]
    public let url: URL
    public var trendVariation: Double? {
        let values = graph.compactMap { $0 }
        guard values.count >= 2 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return 2 * sqrt(values.map { pow($0 - mean, 2) }.reduce(0, +) / Double(values.count - 1))
    }
}

public struct MarketPrice: Sendable, Equatable {
    public let min: Double
    public let max: Double
    public let currency: String
    public var display: String {
        let lower = Self.rounded(min)
        return "\(lower)\(min == max ? "" : "–" + Self.rounded(max)) \(currency)"
    }
    public func formatted(fraction: Bool) -> String {
        guard fraction, min == max, min != 0, abs(min) < 1 else { return display }
        let reciprocal = Self.rounded(1 / min)
        return reciprocal == "1" ? "1 \(currency)" : "1 / \(reciprocal) \(currency)"
    }
    public static func rounded(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...(abs(value) < 10 ? 1 : 0))))
    }
}

public struct MarketSnapshot: Sendable {
    public let league: String
    public let quotes: [MarketQuery: MarketQuote]
    public let fetchedAt: Date
    public func quote(_ query: MarketQuery?) -> MarketQuote? { query.flatMap { quotes[$0] } }
    public var divineChaos: Double? {
        guard let value = quote(.init(ns: "ITEM", name: "Divine Orb"))?.chaos, value >= 30 else { return nil }
        return value
    }
    public func price(_ chaos: Double, forceChaos: Bool = false) -> MarketPrice {
        guard !forceChaos, let rate = divineChaos, chaos > rate * 0.94 else {
            return .init(min: chaos, max: chaos, currency: "chaos")
        }
        let value = chaos < rate * 1.06 ? 1 : chaos / rate
        return .init(min: value, max: value, currency: "div")
    }
    public func price(min: Double, max: Double) -> MarketPrice {
        guard let rate = divineChaos, max > rate else { return .init(min: min, max: max, currency: "chaos") }
        return .init(min: min / rate, max: max / rate, currency: "div")
    }

    /// Same reference offer sizes as TradeBulk.vue; this is an estimate, never a seller offer.
    public func marketRatio(query: MarketQuery?, exchangeCurrency: String) -> MarketRatio? {
        guard let quote = quote(query), quote.chaos > 0 else { return nil }
        if exchangeCurrency == "chaos", quote.chaos < (divineChaos ?? 9999) * 1.06 {
            if quote.chaos > 4 { return .init(exchangeAmount: quote.chaos, itemAmount: 1, currency: "chaos") }
            let amount: Double = quote.chaos > 1 ? 20 : 10
            return .init(exchangeAmount: amount, itemAmount: amount / quote.chaos, currency: "chaos")
        }
        if exchangeCurrency == "divine", let rate = divineChaos {
            if quote.chaos > rate * 0.94 { return .init(exchangeAmount: quote.chaos / rate, itemAmount: 1, currency: "div") }
            let amount: Double = quote.chaos > rate * 0.2 ? 2 : 1
            return .init(exchangeAmount: amount, itemAmount: amount * rate / quote.chaos, currency: "div")
        }
        return nil
    }
}

public struct MarketRatio: Sendable, Equatable {
    public let exchangeAmount: Double
    public let itemAmount: Double
    public let currency: String
    public var unitPrice: Double { exchangeAmount / itemAmount }
}

public struct PricePrediction: Sendable {
    public struct Contribution: Sendable, Identifiable {
        public let name: String
        public let percent: Double
        public var id: String { name }
    }
    public let price: MarketPrice
    public let confidence: Double
    public let contributions: [Contribution]
    public let providerURL: URL
}

public enum PredictionFeedback: String, CaseIterable, Sendable { case low, fair, high }

public enum MarketDataError: LocalizedError {
    case privateLeague, invalidResponse(String), requestFailed(String, Int), prediction(String)
    public var errorDescription: String? {
        switch self {
        case .privateLeague: return "Market providers do not supply private-league prices."
        case .invalidResponse(let provider): return "\(provider) returned an unreadable response."
        case .requestFailed(let provider, let status): return "\(provider) is unavailable (HTTP \(status))."
        case .prediction(let message): return "poeprices.info: " + message
        }
    }
}

/// Public market providers use a separate session, never the trade account's cookies.
public actor MarketDataClient {
    public static let shared = MarketDataClient()
    private let session: URLSession
    private var cache: [String: MarketSnapshot] = [:]
    private var pending: [String: Task<MarketSnapshot, Error>] = [:]
    private var predictions: [String: (Date, PricePrediction)] = [:]

    public init(session: URLSession? = nil) {
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 25
            config.httpShouldSetCookies = false
            self.session = URLSession(configuration: config)
        }
    }

    public func snapshot(league: String, force: Bool = false) async throws -> MarketSnapshot {
        guard !Self.isPrivateLeague(league) else { throw MarketDataError.privateLeague }
        if !force, let value = cache[league], Date().timeIntervalSince(value.fetchedAt) < 31 * 60 { return value }
        if let task = pending[league] { return try await task.value }
        let session = self.session
        let task = Task {
            let request = URLRequest(url: Self.overviewURL(league: league))
            let data = try await Self.perform(request, provider: "poe.ninja", session: session)
            return try Self.decodeOverview(data, league: league)
        }
        pending[league] = task
        defer { pending[league] = nil }
        let result = try await task.value
        cache[league] = result
        return result
    }

    public func predict(text: String, league: String, market: MarketSnapshot?) async throws -> PricePrediction {
        guard !Self.isPrivateLeague(league) else { throw MarketDataError.privateLeague }
        let url = Self.predictionURL(text: text, league: league)
        if let (date, cached) = predictions[url.absoluteString], Date().timeIntervalSince(date) < 300 { return cached }
        let data = try await Self.perform(URLRequest(url: url), provider: "poeprices.info", session: session)
        let result = try Self.decodePrediction(data, providerURL: Self.predictionURL(text: text, league: league, website: true), market: market)
        predictions[url.absoluteString] = (Date(), result)
        return result
    }

    /// Called only from the explicit Send Feedback control.
    public func sendFeedback(_ option: PredictionFeedback, text: String, itemText: String,
                             league: String, prediction: PricePrediction) async throws {
        let boundary = "AwakenedPoeTrade-" + UUID().uuidString
        let fields = ["selector": option.rawValue, "feedbacktxt": text,
                      "qitem_txt": Data(Self.transformItemText(itemText).utf8).base64EncodedString(),
                      "source": "awakened-poe-trade", "min": String(prediction.price.min),
                      "max": String(prediction.price.max), "currency": prediction.price.currency == "div" ? "divine" : "chaos",
                      "league": league]
        var request = URLRequest(url: URL(string: "https://www.poeprices.info/send_feedback")!)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        var body = Data()
        for key in fields.keys.sorted() {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(fields[key]!)\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8)); request.httpBody = body
        _ = try await Self.perform(request, provider: "poeprices.info", session: session)
    }

    public static func isPrivateLeague(_ league: String) -> Bool {
        league.contains("Ruthless") || league.range(of: #"\(PL\d+\)$"#, options: .regularExpression) != nil
    }

    public static func overviewURL(league: String) -> URL {
        var url = URLComponents(string: "https://poe.ninja/poe1/api/economy/current/dense/overviews")!
        url.queryItems = [.init(name: "league", value: league), .init(name: "language", value: "en")]
        return url.url!
    }

    public static func predictionURL(text: String, league: String, website: Bool = false) -> URL {
        var url = URLComponents(string: "https://www.poeprices.info/api")!
        url.queryItems = [.init(name: "i", value: Data(transformItemText(text).utf8).base64EncodedString()),
                          .init(name: "l", value: league), .init(name: "s", value: "awakened-poe-trade")]
        if website { url.queryItems?.append(.init(name: "w", value: "1")) }
        // A literal plus in base64 must not become a form-encoded space.
        url.percentEncodedQuery = url.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return url.url!
    }

    public static func transformItemText(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: #"(?<=\d)\([^)]+\)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?m)^\{.+\}\n"#, with: "", options: .regularExpression)
    }

    private static func perform(_ original: URLRequest, provider: String, session: URLSession) async throws -> Data {
        var request = original
        request.setValue("Awakened-PoE-Trade-Native", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MarketDataError.invalidResponse(provider) }
        guard (200..<300).contains(http.statusCode) else { throw MarketDataError.requestFailed(provider, http.statusCode) }
        return data
    }

    public static func decodeOverview(_ data: Data, league: String) throws -> MarketSnapshot {
        guard let root = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw MarketDataError.invalidResponse("poe.ninja") }
        var quotes: [MarketQuery: MarketQuote] = [:]
        var recognizedOverview = false
        func visit(_ value: JSONValue) {
            switch value {
            case .array(let values): values.forEach(visit)
            case .object(let fields):
                if let type = fields["type"]?.string, let descriptor = overviewTypes[type] {
                    recognizedOverview = true
                    for line in fields["lines"]?.array ?? [] {
                        guard let name = line["name"].string, let chaos = line["chaos"].number,
                              chaos.isFinite, chaos >= 0 else { continue }
                        let query = MarketQuery(ns: descriptor.0, name: name, variant: line["variant"].string)
                        let slug = detailsSlug(name: name, variant: query.variant)
                        let url = URL(string: "https://poe.ninja/poe1/economy/\(leagueSlug(league))/\(descriptor.1)/\(slug)")!
                        quotes[query] = .init(query: query, chaos: chaos, graph: line["graph"].array.map { $0.number }, url: url)
                    }
                } else { fields.values.forEach(visit) }
            default: break
            }
        }
        visit(root)
        guard recognizedOverview else { throw MarketDataError.invalidResponse("poe.ninja") }
        return .init(league: league, quotes: quotes, fetchedAt: .now)
    }

    public static func decodePrediction(_ data: Data, providerURL: URL, market: MarketSnapshot?) throws -> PricePrediction {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data), let code = value["error"].number else {
            throw MarketDataError.invalidResponse("poeprices.info")
        }
        guard code == 0 else { throw MarketDataError.prediction(value["error_msg"].string ?? "Could not predict this item.") }
        guard let min = value["min"].number, let max = value["max"].number, min >= 0, max >= min,
              min.isFinite, max.isFinite, let confidence = value["pred_confidence_score"].number else {
            throw MarketDataError.invalidResponse("poeprices.info")
        }
        let price: MarketPrice
        switch value["currency"].string {
        case "chaos": price = .init(min: min, max: max, currency: "chaos")
        case "divine": price = .init(min: min, max: max, currency: "div")
        case "exalt":
            guard let market, let exalted = market.quote(.init(ns: "ITEM", name: "Exalted Orb")) else {
                throw MarketDataError.prediction("The price is in Exalted Orbs, but their exchange rate is unavailable.")
            }
            price = market.price(min: min * exalted.chaos, max: max * exalted.chaos)
        default: throw MarketDataError.prediction("The response uses an unknown currency.")
        }
        let contributions = value["pred_explanation"].array.compactMap { entry -> PricePrediction.Contribution? in
            let pair = entry.array
            guard pair.count >= 2, let name = pair[0].string, let fraction = pair[1].number else { return nil }
            return .init(name: name, percent: (fraction * 100).rounded())
        }
        return .init(price: price, confidence: confidence.rounded(), contributions: contributions, providerURL: providerURL)
    }

    private static func leagueSlug(_ league: String) -> String {
        if league == "Standard" || league == "Hardcore" { return league.lowercased() }
        return league.replacingOccurrences(of: "Hardcore ", with: "").lowercased()
            .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)! + (league.hasPrefix("Hardcore ") ? "hc" : "")
    }
    private static func detailsSlug(name: String, variant: String?) -> String {
        (variant.map { "\(name), \($0)" } ?? name).decomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: #"[^a-zA-Z0-9:\- ]"#, with: "", options: .regularExpression)
            .lowercased().replacingOccurrences(of: " ", with: "-")
    }
    private static let overviewTypes: [String: (String, String)] = {
        let items = ["Currency":"currency", "Fragment":"fragments", "DeliriumOrb":"delirium-orbs",
                     "Scarab":"scarabs", "Artifact":"artifacts", "BaseType":"base-types", "Fossil":"fossils",
                     "Resonator":"resonators", "Incubator":"incubators", "Oil":"oils", "Vial":"vials",
                     "Invitation":"invitations", "BlightedMap":"blighted-maps", "BlightRavagedMap":"blight-ravaged-maps",
                     "Essence":"essences", "Map":"maps", "Tattoo":"tattoos", "Omen":"omens", "Coffin":"coffins",
                     "AllflameEmber":"allflame-embers", "DjinnCoin":"djinn-coins", "Astrolabe":"astrolabes",
                     "Runegraft":"runegrafts", "Ducat":"ducats", "EnshroudingCrystal":"enshrouding-crystals", "Corpse":"corpses"]
        var result = items.mapValues { ("ITEM", $0) }
        for (type, path) in ["UniqueJewel":"unique-jewels", "UniqueFlask":"unique-flasks", "UniqueWeapon":"unique-weapons",
                             "UniqueArmour":"unique-armours", "UniqueAccessory":"unique-accessories", "UniqueMap":"unique-maps",
                             "UniqueRelic":"unique-relics", "UniqueTincture":"unique-tinctures"] { result[type] = ("UNIQUE", path) }
        result["DivinationCard"] = ("DIVINATION_CARD", "divination-cards")
        result["Beast"] = ("CAPTURED_BEAST", "beasts"); result["SkillGem"] = ("GEM", "skill-gems")
        return result
    }()
}
