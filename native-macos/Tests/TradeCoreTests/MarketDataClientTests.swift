import Foundation
import XCTest
@testable import TradeCore

final class MarketDataClientTests: XCTestCase {
    private let overview = #"{"currencyOverviews":[{"type":"Currency","lines":[{"name":"Divine Orb","chaos":200,"graph":[1,null,3,2,4,3,6]},{"name":"Exalted Orb","chaos":10,"graph":[]}]}],"itemOverviews":[{"type":"UniqueArmour","lines":[{"name":"Example's Armour","variant":"Silken Vest, 6L","chaos":210,"graph":[-1,0,1]},{"name":"Example's Armour","variant":"Silken Vest","chaos":20,"graph":[]}]}]}"#
    private let prediction = #"{"error":0,"currency":"divine","min":2,"max":3,"pred_confidence_score":77.6,"pred_explanation":[["Life",0.451],["Resistance",0.2]]}"#

    func testDenseOverviewUsesExactNamespaceAndVariant() throws {
        let snapshot = try MarketDataClient.decodeOverview(Data(overview.utf8), league: "Hardcore Test League")
        let quote = try XCTUnwrap(snapshot.quote(.init(ns: "UNIQUE", name: "Example's Armour", variant: "Silken Vest, 6L")))
        XCTAssertEqual(quote.chaos, 210)
        XCTAssertNil(snapshot.quote(.init(ns: "ITEM", name: "Example's Armour", variant: "Silken Vest, 6L")))
        XCTAssertNil(snapshot.quote(.init(ns: "UNIQUE", name: "Example's Armour")))
        XCTAssertEqual(quote.url.absoluteString, "https://poe.ninja/poe1/economy/test%20leaguehc/unique-armours/examples-armour-silken-vest-6l")
        XCTAssertEqual(snapshot.divineChaos, 200)
        XCTAssertEqual(snapshot.quote(.init(ns: "ITEM", name: "Divine Orb"))?.graph.count, 7)
        XCTAssertNil(snapshot.quote(.init(ns: "ITEM", name: "Divine Orb"))?.graph[1])
    }

    func testMalformedOverviewDoesNotBecomeAnEmptySuccessfulMarket() {
        for value in ["<html>Unavailable</html>", "{}", #"{"error":"blocked"}"#] {
            XCTAssertThrowsError(try MarketDataClient.decodeOverview(Data(value.utf8), league: "Standard"))
        }
    }

    func testMarketCurrencyConversionMatchesWindowsThresholds() throws {
        let snapshot = try MarketDataClient.decodeOverview(Data(overview.utf8), league: "Standard")
        XCTAssertEqual(snapshot.price(187).currency, "chaos")
        XCTAssertEqual(snapshot.price(195).min, 1)
        XCTAssertEqual(snapshot.price(210).min, 1)
        XCTAssertEqual(snapshot.price(220).min, 1.1)
        XCTAssertEqual(snapshot.price(200, forceChaos: true).currency, "chaos")
        XCTAssertEqual(snapshot.price(min: 100, max: 220).min, 0.5)
        XCTAssertEqual(snapshot.price(min: 100, max: 220).max, 1.1)
        XCTAssertEqual(snapshot.price(min: 100, max: 200).currency, "chaos")
        XCTAssertEqual(snapshot.price(0.002).formatted(fraction: true), "1 / 500 chaos")
        let quote = try XCTUnwrap(snapshot.quote(.init(ns: "UNIQUE", name: "Example's Armour", variant: "Silken Vest, 6L")))
        XCTAssertEqual(quote.trendVariation, 2)
    }

    func testPredictionTransformsAdvancedCRLFTextAndEncodesExactLeague() throws {
        let text = "Item Class: Rings\r\nRarity: Rare\r\n--------\r\n{ Prefix Modifier — Life }\r\n+50(45-55) to maximum Life\r\n(Description)\r\n"
        let url = MarketDataClient.predictionURL(text: text, league: "Test + 測試", website: true)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        let encoded = try XCTUnwrap(query.first { $0.name == "i" }?.value)
        let decoded = String(decoding: try XCTUnwrap(Data(base64Encoded: encoded)), as: UTF8.self)
        XCTAssertFalse(decoded.contains("Prefix Modifier"))
        XCTAssertTrue(decoded.contains("+50 to maximum Life"))
        XCTAssertTrue(decoded.contains("(Description)"))
        XCTAssertFalse(decoded.contains("\r"))
        XCTAssertEqual(query.first { $0.name == "l" }?.value, "Test + 測試")
        XCTAssertEqual(query.first { $0.name == "w" }?.value, "1")
        XCTAssertFalse(url.absoluteString.contains("+"))
    }

    func testBulkMarketRatioUsesOriginalOfferSizesAndCurrencyThresholds() throws {
        let json = #"{"currencyOverviews":[{"type":"Currency","lines":[{"name":"Divine Orb","chaos":200,"graph":[]},{"name":"Cheap","chaos":0.5,"graph":[]},{"name":"Middle","chaos":50,"graph":[]},{"name":"Expensive","chaos":250,"graph":[]},{"name":"Zero","chaos":0,"graph":[]}]}]}"#
        let market = try MarketDataClient.decodeOverview(Data(json.utf8), league: "Standard")
        let cheapChaos = try XCTUnwrap(market.marketRatio(query: .init(ns: "ITEM", name: "Cheap"), exchangeCurrency: "chaos"))
        XCTAssertEqual(cheapChaos.exchangeAmount, 10)
        XCTAssertEqual(cheapChaos.itemAmount, 20)
        XCTAssertEqual(cheapChaos.unitPrice, 0.5)
        let cheapDivine = try XCTUnwrap(market.marketRatio(query: .init(ns: "ITEM", name: "Cheap"), exchangeCurrency: "divine"))
        XCTAssertEqual(cheapDivine.exchangeAmount, 1)
        XCTAssertEqual(cheapDivine.itemAmount, 400)
        let middle = try XCTUnwrap(market.marketRatio(query: .init(ns: "ITEM", name: "Middle"), exchangeCurrency: "divine"))
        XCTAssertEqual(middle.exchangeAmount, 2)
        XCTAssertEqual(middle.itemAmount, 8)
        XCTAssertNil(market.marketRatio(query: .init(ns: "ITEM", name: "Expensive"), exchangeCurrency: "chaos"))
        XCTAssertEqual(market.marketRatio(query: .init(ns: "ITEM", name: "Expensive"), exchangeCurrency: "divine")?.exchangeAmount, 1.25)
        XCTAssertNil(market.marketRatio(query: .init(ns: "ITEM", name: "Zero"), exchangeCurrency: "chaos"))
    }

    func testPredictionDecodesConfidenceContributionsAndCurrency() throws {
        let result = try MarketDataClient.decodePrediction(Data(prediction.utf8), providerURL: URL(string: "https://www.poeprices.info")!, market: nil)
        XCTAssertEqual(result.confidence, 78)
        XCTAssertEqual(result.price.currency, "div")
        XCTAssertEqual(result.contributions.map(\.percent), [45, 20])
        XCTAssertEqual(result.contributions.map(\.name), ["Life", "Resistance"])
    }

    func testPredictionConvertsExaltedOnlyWhenExchangeRateExists() throws {
        let data = Data(prediction.replacingOccurrences(of: "divine", with: "exalt").utf8)
        let url = URL(string: "https://www.poeprices.info")!
        XCTAssertThrowsError(try MarketDataClient.decodePrediction(data, providerURL: url, market: nil))
        let market = try MarketDataClient.decodeOverview(Data(overview.utf8), league: "Standard")
        let result = try MarketDataClient.decodePrediction(data, providerURL: url, market: market)
        XCTAssertEqual(result.price.currency, "chaos")
        XCTAssertEqual(result.price.min, 20)
        XCTAssertEqual(result.price.max, 30)
    }

    func testPredictionRejectsProviderErrorsUnknownCurrenciesAndReversedBounds() {
        let url = URL(string: "https://www.poeprices.info")!
        for json in [#"{"error":1,"error_msg":"No model"}"#,
                     prediction.replacingOccurrences(of: "divine", with: "unknown"),
                     prediction.replacingOccurrences(of: "\"min\":2", with: "\"min\":4")] {
            XCTAssertThrowsError(try MarketDataClient.decodePrediction(Data(json.utf8), providerURL: url, market: nil))
        }
    }

    func testOverviewCacheIsScopedToLeague() async throws {
        let (client, fixture) = makeClient(json: overview)
        _ = try await client.snapshot(league: "Standard")
        _ = try await client.snapshot(league: "Standard")
        _ = try await client.snapshot(league: "Hardcore")
        XCTAssertEqual(fixture.requests.count, 2)
        let leagues = fixture.requests.compactMap { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "league" }?.value }
        XCTAssertEqual(leagues, ["Standard", "Hardcore"])
        XCTAssertEqual(fixture.requests.first?.url?.host, "poe.ninja")
    }

    func testPrivateLeagueNeverRequestsProviderPrices() async {
        let (client, fixture) = makeClient(json: overview)
        do { _ = try await client.snapshot(league: "Private (PL86569)"); XCTFail("Expected private league rejection") }
        catch MarketDataError.privateLeague { }
        catch { XCTFail("Unexpected error: \(error)") }
        do { _ = try await client.predict(text: "item", league: "Private (PL86569)", market: nil); XCTFail("Expected private league rejection") }
        catch MarketDataError.privateLeague { }
        catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testProviderFailureDoesNotRetryAutomatically() async {
        let (client, fixture) = makeClient(json: "Unavailable", status: 503)
        do { _ = try await client.snapshot(league: "Standard"); XCTFail("Expected failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("poe.ninja")); XCTAssertTrue(error.localizedDescription.contains("503")) }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testFeedbackSendsOnlyAfterExplicitCallWithMultipartBody() async throws {
        let (client, fixture) = makeClient(json: #""fair""#)
        XCTAssertTrue(fixture.requests.isEmpty)
        let result = try MarketDataClient.decodePrediction(Data(prediction.utf8), providerURL: URL(string: "https://www.poeprices.info")!, market: nil)
        try await client.sendFeedback(.fair, text: "", itemText: "Item text", league: "Standard", prediction: result)
        let request = try XCTUnwrap(fixture.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://www.poeprices.info/send_feedback")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data;") == true)
        // URLSession may expose upload data through a stream instead of httpBody.
        XCTAssertEqual(fixture.requests.count, 1)
    }

    private func makeClient(json: String, status: Int = 200) -> (MarketDataClient, MarketFixture) {
        let fixture = MarketFixture(json: json, status: status)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MarketProtocol.self]
        let key = UUID().uuidString
        config.httpAdditionalHeaders = ["X-Market-Fixture": key]
        MarketProtocol.register(fixture, key: key)
        return (MarketDataClient(session: URLSession(configuration: config)), fixture)
    }
}

private final class MarketFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    let json: String
    let status: Int
    init(json: String, status: Int) { self.json = json; self.status = status }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    func record(_ request: URLRequest) { lock.lock(); defer { lock.unlock() }; recorded.append(request) }
}

private final class MarketProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var fixtures: [String: MarketFixture] = [:]
    static func register(_ fixture: MarketFixture, key: String) { lock.lock(); defer { lock.unlock() }; fixtures[key] = fixture }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let fixture = Self.fixtures[request.value(forHTTPHeaderField: "X-Market-Fixture") ?? ""]
        Self.lock.unlock()
        guard let fixture else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        fixture.record(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(fixture.json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
