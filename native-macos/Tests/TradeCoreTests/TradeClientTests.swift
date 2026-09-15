import Foundation
import XCTest
@testable import TradeCore

final class TradeClientTests: XCTestCase {
    private let query = #"{"query":{"status":{"option":"online"}},"sort":{"price":"asc"}}"#

    func testLeaguesUsesTradeEndpointAndRemovesDuplicates() async throws {
        let (client, fixture) = makeClient([
            .init(json: #"{"result":[{"id":"Standard","text":"Standard"},{"id":"A New League"},{"id":"Standard"},{"id":" "}]}"#)
        ])
        let leagues = try await client.leagues()
        XCTAssertEqual(leagues, ["Standard", "A New League"])
        XCTAssertEqual(fixture.requests.first?.url?.absoluteString, "https://www.pathofexile.com/api/trade/data/leagues")
        XCTAssertEqual(fixture.requests.first?.httpMethod, "GET")
    }

    func testSearchFetchesOnlyFirstTenAndDecodesListings() async throws {
        let ids = (1...12).map { "item\($0)" }
        let searchData = try JSONSerialization.data(withJSONObject: ["id": "search+id", "total": 120, "result": ids])
        let fetch = #"{"result":[{"id":"item1","item":{"name":"Test Relic","typeLine":"Gold Ring"},"listing":{"indexed":"2026-09-11T00:00:00Z","price":{"amount":1.5,"currency":"divine"},"account":{"name":"ExampleSeller","online":{"league":"Standard"}}}},null,{"id":"item2","item":{"name":"","typeLine":"Leather Belt"},"listing":{"account":{"name":"OfflineSeller"}}}]}"#
        let (client, fixture) = makeClient([
            .init(json: String(decoding: searchData, as: UTF8.self)), .init(json: fetch)
        ])
        let result = try await client.search(queryJSON: query, league: "League / + 測試", representativeResults: false)
        XCTAssertEqual(result.searchID, "search+id")
        XCTAssertEqual(result.total, 120)
        XCTAssertEqual(result.resultIDs, ids)
        XCTAssertEqual(result.fetchedCount, 10)
        XCTAssertTrue(result.hasMore)
        XCTAssertEqual(result.listings.count, 2)
        XCTAssertEqual(result.listings[0].itemName, "Test Relic Gold Ring")
        XCTAssertEqual(result.listings[0].account, "ExampleSeller")
        XCTAssertEqual(result.listings[0].priceAmount, 1.5)
        XCTAssertEqual(result.listings[0].priceCurrency, "divine")
        XCTAssertEqual(result.listings[0].indexed, "2026-09-11T00:00:00Z")
        XCTAssertTrue(result.listings[0].online)
        XCTAssertFalse(result.listings[1].online)
        XCTAssertNil(result.listings[1].priceAmount)
        XCTAssertEqual(result.listings[1].itemName, "Leather Belt")
        XCTAssertNil(result.listings[1].itemLevel)
        XCTAssertNil(result.listings[1].stackSize)
        XCTAssertNil(result.listings[1].quality)
        XCTAssertNil(result.listings[1].gemLevel)
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertEqual(fixture.requests[0].httpMethod, "POST")
        XCTAssertEqual(fixture.requests[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertTrue(fixture.requests[0].url!.absoluteString.contains("League%20%2F%20%2B%20"))
        XCTAssertEqual(fixture.requests[1].url!.path, "/api/trade/fetch/" + ids.prefix(10).joined(separator: ","))
        XCTAssertEqual(URLComponents(url: fixture.requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "search+id")
        XCTAssertTrue(fixture.requests[1].url!.absoluteString.contains("query=search%2Bid"))
    }

    func testListingDetailsDecodeNumericFieldsAndPropertyDisplayValues() async throws {
        let fetch = #"""
        {"result":[
          {"id":"gem","item":{"name":"","typeLine":"Fireball","ilvl":80,
            "properties":[{"name":"物品等級","type":78,"values":[["86",0]]},
                          {"name":"品質","type":6,"values":[["+23%",1]]},
                          {"name":"等級","type":5,"values":[["21 (Max)",0]]}]},
           "listing":{"account":{"name":"GemSeller"}}},
          {"id":"stack","item":{"typeLine":"Example Stack","ilvl":0,"stackSize":42,
            "properties":[{"name":"Quality","values":[["+20%",1]]},
                          {"name":"Level","values":[["20",0]]},
                          {"name":"Unrelated","values":[["999",0]]}]},
           "listing":{"account":{"name":"StackSeller"}}},
          {"id":"empty","item":{"typeLine":"Empty Properties",
            "properties":[{"name":"Quality","type":6,"values":[]},
                          {"name":"Level","type":5,"values":[[]]}]},
           "listing":{"account":{"name":"ExampleSeller"}}}
        ]}
        """#
        let (client, _) = makeClient([
            .init(json: #"{"id":"details","total":3,"result":["gem","stack","empty"]}"#),
            .init(json: fetch)
        ])
        let result = try await client.search(queryJSON: query, league: "Standard")
        XCTAssertEqual(result.listings[0].itemLevel, 86)
        XCTAssertNil(result.listings[0].stackSize)
        XCTAssertEqual(result.listings[0].quality, "+23%")
        XCTAssertEqual(result.listings[0].gemLevel, "21 (Max)")
        XCTAssertEqual(result.listings[1].itemLevel, 0)
        XCTAssertEqual(result.listings[1].stackSize, 42)
        XCTAssertEqual(result.listings[1].quality, "+20%")
        XCTAssertEqual(result.listings[1].gemLevel, "20")
        XCTAssertNil(result.listings[2].quality)
        XCTAssertNil(result.listings[2].gemLevel)
    }

    func testListingDetailsRemainCompatibleWithExistingInitializersAndSavedData() throws {
        let listing = TradeListing(id: "old", itemName: "Example", account: "Seller", priceAmount: nil,
                                   priceCurrency: nil, indexed: nil, online: false)
        XCTAssertNil(listing.itemLevel)
        XCTAssertNil(listing.stackSize)
        XCTAssertNil(listing.quality)
        XCTAssertNil(listing.gemLevel)
        let previousJSON = #"{"id":"old","itemName":"Example","account":"Seller","online":false}"#
        let decoded = try JSONDecoder().decode(TradeListing.self, from: Data(previousJSON.utf8))
        XCTAssertNil(decoded.itemLevel)
        XCTAssertNil(decoded.stackSize)
        XCTAssertNil(decoded.quality)
        XCTAssertNil(decoded.gemLevel)
    }

    func testZeroResultsDoesNotFetch() async throws {
        let (client, fixture) = makeClient([.init(json: #"{"id":"empty","total":0,"result":[]}"#)])
        let result = try await client.search(queryJSON: query, league: "Standard")
        XCTAssertEqual(result.total, 0)
        XCTAssertTrue(result.listings.isEmpty)
        XCTAssertFalse(result.hasMore)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testInjectedTransportHandlesSearchFetchAndLeaguesWithoutDefaultSession() async throws {
        let (client, fixture) = makeClient([])
        let transport = StubTradeTransport([
            .init(json: #"{"result":[{"id":"Private (PL123)"}]}"#),
            .init(json: #"{"id":"authenticated","total":1,"result":["item"]}"#),
            .init(json: #"{"result":[{"id":"item","item":{"typeLine":"Example"},"listing":{"whisper":"@Seller Hi, I would like to buy your Example.","account":{"name":"Account","lastCharacterName":"Seller","online":{"status":"afk"}},"stash":{"name":"Sale","x":2,"y":3}}}]}"#)
        ])
        let leagues = try await client.leagues(transport: transport)
        let page = try await client.search(queryJSON: query, league: "Private (PL123)", transport: transport)
        XCTAssertEqual(leagues, ["Private (PL123)"])
        XCTAssertEqual(page.listings.first?.lastCharacterName, "Seller")
        XCTAssertEqual(page.listings.first?.accountStatus, "afk")
        XCTAssertEqual(page.listings.first?.whisper, "@Seller Hi, I would like to buy your Example.")
        XCTAssertEqual(page.listings.first?.stashName, "Sale")
        XCTAssertEqual(page.listings.first?.stashX, 2)
        XCTAssertEqual(page.listings.first?.stashY, 3)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST", "GET"])
        XCTAssertEqual(requests[1].httpBody, Data(query.utf8))
        XCTAssertTrue(fixture.requests.isEmpty)
        for request in requests {
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "www.pathofexile.com")
            XCTAssertTrue(request.url!.path.hasPrefix("/api/trade/"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testInjectedTransportFailureNeverFallsBackToAnonymousRequests() async throws {
        let (client, fixture) = makeClient([])
        let transport = StubTradeTransport([], failure: URLError(.userAuthenticationRequired))
        do {
            _ = try await client.search(queryJSON: query, league: "Private (PL123)", transport: transport)
            XCTFail("Expected authentication failure")
        } catch let error as URLError { XCTAssertEqual(error.code, .userAuthenticationRequired) }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testInjectedTransportCancellationReleasesTheRequestQueue() async throws {
        let (client, fixture) = makeClient([.init(json: #"{"result":[{"id":"Standard"}]}"#)])
        let transport = StubTradeTransport([.init(json: "{}", delay: 10)])
        let pending = Task { try await client.leagues(transport: transport) }
        for _ in 0..<100 {
            if await !transport.requests.isEmpty { break }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let leagues = try await client.leagues()
        XCTAssertEqual(leagues, ["Standard"])
        XCTAssertEqual(fixture.requests.count, 1)
        let active = await transport.activeRequests
        XCTAssertEqual(active, 0)
    }

    func testInjectedTransportUsesExistingSerializationAndRateLimitCooldown() async throws {
        let (client, fixture) = makeClient([], interval: 0.02)
        let transport = StubTradeTransport([
            .init(json: #"{"result":[]}"#, delay: 0.04),
            .init(json: #"{"result":[]}"#, delay: 0.04),
            .init(status: 429, json: "{}", headers: ["Retry-After": "60"])
        ])
        async let first = client.leagues(transport: transport)
        async let second = client.leagues(transport: transport)
        _ = try await (first, second)
        let maxActive = await transport.maximumActive
        XCTAssertEqual(maxActive, 1)
        do { _ = try await client.leagues(transport: transport); XCTFail("Expected rate limit") }
        catch let error as TradeClientError { XCTAssertEqual(error.retryAfter, 60) }
        let waiting = Task { try await client.leagues() }
        try await Task.sleep(nanoseconds: 20_000_000)
        waiting.cancel()
        do { _ = try await waiting.value; XCTFail("Expected cooldown cancellation") }
        catch is CancellationError { }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testTransportResponseCannotRedirectOutsideOfficialAPI() async throws {
        let (client, fixture) = makeClient([])
        let transport = StubTradeTransport([
            .init(json: #"{"result":[{"id":"Unexpected"}]}"#, responseURL: URL(string: "https://example.com/api/trade/data/leagues"))
        ])
        do { _ = try await client.leagues(transport: transport); XCTFail("Expected origin validation") }
        catch TradeClientError.malformedResponse(let message) { XCTAssertTrue(message.contains("official trade API")) }
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testHTMLTransportResponseExplainsBrowserVerification() async throws {
        let (client, _) = makeClient([])
        let transport = StubTradeTransport([.init(json: "  <html>Sign in</html>")])
        do { _ = try await client.leagues(transport: transport); XCTFail("Expected HTML rejection") }
        catch TradeClientError.malformedResponse(let message) { XCTAssertTrue(message.contains("sign-in or browser verification")) }
    }

    func testFetchMorePreservesSearchIDsSkipsDisappearedListingsAndAvoidsPost() async throws {
        let ids = (1...12).map { "item\($0)" }
        let search = try JSONSerialization.data(withJSONObject: ["id": "original", "total": 120, "result": ids])
        let (client, fixture) = makeClient([])
        let transport = StubTradeTransport([
            .init(json: String(decoding: search, as: UTF8.self)),
            .init(json: #"{"result":[null,{"id":"item2","item":{"typeLine":"Second"},"listing":{"account":{"name":"Seller"}}}]}"#),
            .init(json: #"{"result":[{"id":"item12","item":{"typeLine":"Twelfth"},"listing":{"account":{"name":"Seller"}}},{"id":"item11","item":{"typeLine":"Eleventh"},"listing":{"account":{"name":"Seller"}}},{"id":"item2","item":{"typeLine":"Wrong page duplicate"},"listing":{"account":{"name":"Seller"}}}]}"#)
        ])
        let first = try await client.search(queryJSON: query, league: "Private (PL123)", transport: transport, representativeResults: false)
        XCTAssertEqual(first.fetchedCount, 10)
        XCTAssertEqual(first.listings.map(\.id), ["item2"])
        XCTAssertTrue(first.hasMore)
        let next = try await client.fetchMore(page: first, transport: transport)
        XCTAssertEqual(next.searchID, "original")
        XCTAssertEqual(next.resultIDs, ids)
        XCTAssertEqual(next.total, 120)
        XCTAssertEqual(next.fetchedCount, 12)
        XCTAssertEqual(next.listings.map(\.id), ["item2", "item11", "item12"])
        XCTAssertFalse(next.hasMore)
        _ = try await client.fetchMore(page: next, transport: transport)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "GET"])
        XCTAssertEqual(requests[2].url?.path, "/api/trade/fetch/item11,item12")
        XCTAssertEqual(URLComponents(url: requests[2].url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "original")
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testFetchMoreFailureLeavesOriginalPageUsableAndDoesNotRetry() async throws {
        let (client, fixture) = makeClient([])
        let page = TradeSearchPage(searchID: "saved", total: 1, listings: [], resultIDs: ["next"], fetchedCount: 0)
        let transport = StubTradeTransport([.init(status: 403, json: "{}")])
        do { _ = try await client.fetchMore(page: page, transport: transport); XCTFail("Expected forbidden") }
        catch TradeClientError.http(let status, _, _) { XCTAssertEqual(status, 403) }
        XCTAssertEqual(page.fetchedCount, 0)
        XCTAssertTrue(page.hasMore)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.httpMethod, "GET")
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testSavedSearchPagesDecodeWithoutPaginationMetadata() throws {
        let json = #"{"searchID":"old","total":50,"listings":[]}"#
        let page = try JSONDecoder().decode(TradeSearchPage.self, from: Data(json.utf8))
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.resultIDs, [])
        XCTAssertEqual(page.fetchedCount, 0)
    }

    func testRepresentativeSearchStartsWithTwentyThenAllowsPagination() async throws {
        let ids = (1...30).map { "item\($0)" }
        let search = try JSONSerialization.data(withJSONObject: ["id": "representative", "total": 30, "result": ids])
        let transport = StubTradeTransport([
            .init(json: String(decoding: search, as: UTF8.self)),
            try listingResponse(Array(ids.prefix(10))),
            try listingResponse(Array(ids[10..<20])),
            try listingResponse(Array(ids[20..<30]))
        ])
        let (client, _) = makeClient([])
        let page = try await client.search(queryJSON: query, league: "Standard", transport: transport)
        XCTAssertEqual(page.fetchedCount, 20)
        XCTAssertEqual(page.listings.count, 20)
        XCTAssertTrue(page.hasMore)
        let next = try await client.fetchMore(page: page, transport: transport)
        XCTAssertEqual(next.fetchedCount, 30)
        XCTAssertEqual(next.listings.map(\.id), ids)
        let requests = await transport.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "GET", "GET"])
    }

    func testRepresentativeSearchCapsAutomaticFetchAtOneHundredIDs() async throws {
        let ids = (1...110).map { "item\($0)" }
        let search = try JSONSerialization.data(withJSONObject: ["id": "duplicates", "total": 110, "result": ids])
        var responses = [StubResponse(json: String(decoding: search, as: UTF8.self))]
        for start in stride(from: 0, to: 100, by: 10) {
            responses.append(try listingResponse(Array(ids[start..<(start + 10)]), sameSeller: true))
        }
        let transport = StubTradeTransport(responses)
        let (client, _) = makeClient([])
        let page = try await client.search(queryJSON: query, league: "Standard", transport: transport)
        XCTAssertEqual(page.fetchedCount, 100)
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.groupedListings().count, 1)
        XCTAssertEqual(page.groupedListings().first?.listedTimes, 100)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 11)
    }

    func testGroupingAggregatesStockAndRespectsMerchantPreference() {
        func listing(_ id: String, stock: Int? = nil, fee: Double? = nil) -> TradeListing {
            TradeListing(id: id, itemName: "Example", account: "Seller", priceAmount: 1,
                         priceCurrency: "chaos", indexed: nil, online: true, stackSize: stock, fee: fee)
        }
        let stockPage = TradeSearchPage(searchID: "x", total: 2,
                                       listings: [listing("a", stock: 20), listing("b", stock: 30)])
        XCTAssertEqual(stockPage.groupedListings().first?.stock, 50)
        let merchants = TradeSearchPage(searchID: "x", total: 2,
                                       listings: [listing("a", fee: 0), listing("b", fee: 1)])
        XCTAssertEqual(merchants.groupedListings().count, 2)
        XCTAssertEqual(merchants.groupedListings(collapseMerchant: true).count, 1)
    }

    func testExtraDelayAddsToMinimumRequestSpacingAndRejectsNonfiniteValues() async throws {
        let response = StubResponse(json: #"{"result":[]}"#)
        let (client, fixture) = makeClient([response, response, response], interval: 0.02)
        await client.setExtraDelay(0.04)
        _ = try await client.leagues()
        _ = try await client.leagues()
        let starts = fixture.startTimes
        XCTAssertGreaterThanOrEqual(starts[1].timeIntervalSince(starts[0]), 0.055)
        await client.setExtraDelay(.infinity)
        _ = try await client.leagues()
        XCTAssertEqual(fixture.requests.count, 3)
    }

    private func listingResponse(_ ids: [String], sameSeller: Bool = false) throws -> StubResponse {
        let rows: [[String: Any]] = ids.map { id in
            ["id": id, "item": ["typeLine": "Example"],
             "listing": ["account": ["name": sameSeller ? "Seller" : id],
                         "price": ["amount": 1, "currency": "chaos"]]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["result": rows])
        return .init(json: String(decoding: data, as: UTF8.self))
    }

    func testRejectsMalformedInputBeforeMakingRequests() async throws {
        for input in ["not json", "[]", "{}", #"{"query":false}"#] {
            let (client, fixture) = makeClient([])
            do {
                _ = try await client.search(queryJSON: input, league: "Standard")
                XCTFail("Expected invalid input to fail")
            } catch TradeClientError.invalidRequest { }
            XCTAssertTrue(fixture.requests.isEmpty)
        }
    }

    func testRejectsMalformedAndAPIErrorResponses() async throws {
        for response in ["<html>challenge</html>", #"{"id":"x","result":[]}"#,
                         #"{"id":"","result":[],"total":0}"#,
                         #"{"error":{"message":"Invalid query"}}"#] {
            let (client, fixture) = makeClient([.init(json: response)])
            do {
                _ = try await client.search(queryJSON: query, league: "Standard")
                XCTFail("Expected malformed response to fail")
            } catch TradeClientError.malformedResponse(let message) {
                XCTAssertFalse(message.isEmpty)
            }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testForbiddenExplainsBrowserFallbackAndDoesNotRetryPost() async throws {
        let (client, fixture) = makeClient([.init(status: 403, json: "<html>Forbidden</html>")])
        do {
            _ = try await client.search(queryJSON: query, league: "Standard")
            XCTFail("Expected forbidden response")
        } catch TradeClientError.http(let status, let message, let retryAfter) {
            XCTAssertEqual(status, 403)
            XCTAssertTrue(message.contains("browser"))
            XCTAssertNil(retryAfter)
        }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testRateLimitPreservesRetryAfterAndDoesNotRetryPost() async throws {
        let (client, fixture) = makeClient([.init(status: 429, json: "{}", headers: ["Retry-After": "12"])])
        do {
            _ = try await client.search(queryJSON: query, league: "Standard")
            XCTFail("Expected rate limit response")
        } catch let error as TradeClientError {
            XCTAssertEqual(error.retryAfter, 12)
            XCTAssertTrue(error.localizedDescription.contains("12 seconds"))
        }
        let pending = Task { try await client.leagues() }
        try await Task.sleep(nanoseconds: 30_000_000)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation during rate limit cooldown") }
        catch is CancellationError { }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testHTTPDateRetryAfter() async throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let future = formatter.string(from: Date().addingTimeInterval(30))
        let (client, _) = makeClient([.init(status: 429, json: "{}", headers: ["Retry-After": future])])
        do { _ = try await client.leagues(); XCTFail("Expected rate limit response") }
        catch let error as TradeClientError {
            XCTAssertNotNil(error.retryAfter)
            XCTAssertGreaterThan(error.retryAfter ?? 0, 25)
            XCTAssertLessThanOrEqual(error.retryAfter ?? 0, 30)
        }
    }

    func testCancellationBetweenSearchAndFetchSkipsFetch() async throws {
        let (client, fixture) = makeClient([
            .init(json: #"{"id":"search","total":1,"result":["item1"]}"#)
        ], interval: 1)
        let pending = Task { try await client.search(queryJSON: query, league: "Standard") }
        for _ in 0..<100 where fixture.requests.isEmpty {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testConcurrentRequestsAreSerializedAndSpaced() async throws {
        let response = StubResponse(json: #"{"result":[{"id":"Standard"}]}"#, delay: 0.08)
        let (client, fixture) = makeClient([response, response, response], interval: 0.06)
        async let first = client.leagues()
        async let second = client.leagues()
        async let third = client.leagues()
        _ = try await (first, second, third)
        XCTAssertEqual(fixture.requests.count, 3)
        XCTAssertEqual(fixture.maximumActive, 1)
        let starts = fixture.startTimes
        XCTAssertGreaterThanOrEqual(starts[1].timeIntervalSince(starts[0]), 0.06)
        XCTAssertGreaterThanOrEqual(starts[2].timeIntervalSince(starts[1]), 0.06)
    }

    func testBrowserURLsEncodeUntrustedPathAndQueryValues() throws {
        let league = "League /?# + 測試"
        let query = #"{"query":{"name":"A+B & C/#?"}}"#
        let browser = try XCTUnwrap(TradeClient.browserURL(league: league, queryJSON: query))
        let components = try XCTUnwrap(URLComponents(url: browser, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "www.pathofexile.com")
        XCTAssertEqual(components.queryItems, [URLQueryItem(name: "q", value: query)])
        XCTAssertNil(components.fragment)
        XCTAssertTrue(components.percentEncodedPath.contains("%2F%3F%23%20%2B"))
        XCTAssertFalse(components.percentEncodedQuery!.contains("+"))
        let result = try XCTUnwrap(TradeClient.resultURL(league: league, searchID: "id/../?#"))
        XCTAssertTrue(result.absoluteString.hasSuffix("id%2F..%2F%3F%23"))
        XCTAssertNil(TradeClient.resultURL(league: "", searchID: "id"))
        XCTAssertNil(TradeClient.browserURL(league: " ", queryJSON: query))
        let exchange = try XCTUnwrap(TradeClient.exchangeResultURL(league: league, searchID: "id/../?#"))
        XCTAssertTrue(exchange.absoluteString.contains("/trade/exchange/League%20%2F%3F%23%20%2B"))
        XCTAssertTrue(exchange.absoluteString.hasSuffix("id%2F..%2F%3F%23"))
        XCTAssertNil(TradeClient.exchangeResultURL(league: "Standard", searchID: ""))
    }

    private let exchangeQuery = #"{"engine":"new","query":{"have":["divine","chaos"],"want":["fusing"],"status":{"option":"online"}},"sort":{"have":"asc"}}"#

    func testExchangeUsesOneInjectedPostAndPreservesMultipleCurrencyOffers() async throws {
        let json = #"""
        {"id":"bulk+id","total":103,"result":{
          "seller1":{"id":"seller1","listing":{"indexed":"2026-09-11T00:00:00Z",
            "account":{"name":"SellerOne","lastCharacterName":"CharacterOne","online":{"status":"afk"}},
            "whisper":"@CharacterOne example fixture whisper",
            "offers":[{"exchange":{"currency":"divine","amount":1},"item":{"amount":500,"stock":2000}},
                      {"exchange":{"currency":"chaos","amount":10},"item":{"currency":"fusing","amount":50,"stock":2000}}]}},
          "seller2":{"id":"seller2","listing":{"account":{"name":"SellerTwo"},
            "offers":[{"exchange":{"currency":"divine","amount":1},"item":{"amount":600,"stock":300}}]}}
        }}
        """#
        let transport = StubTradeTransport([.init(json: json)])
        let (client, fallback) = makeClient([])
        let page = try await client.exchange(queryJSON: exchangeQuery, league: "Private + / 測試", transport: transport)
        XCTAssertEqual(page.searchID, "bulk+id")
        XCTAssertEqual(page.total, 103)
        XCTAssertEqual(page.requestedCurrencies, ["divine", "chaos"])
        XCTAssertEqual(page.offers.map(\.id), ["seller2:0", "seller1:0", "seller1:1"])
        XCTAssertEqual(page.offers.map(\.exchangeCurrency), ["divine", "divine", "chaos"])
        XCTAssertEqual(page.offers[0].unitPrice, 1.0 / 600)
        XCTAssertEqual(page.offers[0].stock, 300)
        XCTAssertEqual(page.offers[0].accountStatus, "offline")
        XCTAssertEqual(page.offers[1].accountStatus, "afk")
        XCTAssertEqual(page.offers[1].lastCharacterName, "CharacterOne")
        XCTAssertEqual(page.offers[1].itemCurrency, "fusing")
        XCTAssertEqual(page.offers[2].listingID, "seller1")
        XCTAssertEqual(page.offers[2].whisper, "@CharacterOne example fixture whisper")
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].httpBody, Data(exchangeQuery.utf8))
        XCTAssertTrue(requests[0].url!.absoluteString.contains("/api/trade/exchange/Private%20%2B%20%2F%20"))
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(fallback.requests.isEmpty)
    }

    func testExchangeEmptyResultsDoNotFetch() async throws {
        let (client, fixture) = makeClient([.init(json: #"{"id":"bulk","total":0,"result":{}}"#)])
        let page = try await client.exchange(queryJSON: exchangeQuery, league: "Standard")
        XCTAssertEqual(page.total, 0)
        XCTAssertTrue(page.offers.isEmpty)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testExchangeEmptyArrayResultsAreAnEmptyPage() async throws {
        // Observed HTTP 200 from Standard for Dead Man's Sulphur at minimum stock 750 (search ID normalized).
        let transport = StubTradeTransport([.init(json: #"{"id":"empty-exchange","complexity":null,"result":[],"total":0}"#)])
        let (client, fallback) = makeClient([])
        let query = #"{"engine":"new","query":{"have":["divine","chaos"],"want":["dead-mans-sulphur"],"status":{"option":"online"},"minimum":750},"sort":{"have":"asc"}}"#
        let page = try await client.exchange(queryJSON: query, league: "Standard", transport: transport)
        XCTAssertEqual(page.searchID, "empty-exchange")
        XCTAssertEqual(page.total, 0)
        XCTAssertTrue(page.offers.isEmpty)
        XCTAssertEqual(page.requestedCurrencies, ["divine", "chaos"])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].httpBody, Data(query.utf8))
        XCTAssertTrue(fallback.requests.isEmpty)
    }

    func testExchangeMalformedResultContainersAreNotTreatedAsEmptyPages() async throws {
        let (client, fallback) = makeClient([])
        for result in ["null", "42", #""invalid""#, "[null]", "[{}]", #"{"bad":{"id":"bad"}}"#] {
            let transport = StubTradeTransport([.init(json: "{\"id\":\"bulk\",\"total\":0,\"result\":\(result)}")])
            do {
                _ = try await client.exchange(queryJSON: exchangeQuery, league: "Standard", transport: transport)
                XCTFail("Expected malformed response for \(result)")
            } catch let error as TradeClientError {
                guard case .malformedResponse = error else { return XCTFail("Wrong error: \(error)") }
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
        XCTAssertTrue(fallback.requests.isEmpty)
    }

    func testExchangeFormatsObservedAPIWhisperForEachSelectedOffer() async throws {
        // The first offer reproduces the live API's exact templates and listed quantities.
        let json = #"""
        {"id":"bulk-whisper","total":1,"result":{"seller":{"id":"seller","listing":{
          "account":{"name":"ExampleAccount","lastCharacterName":"Stevia_"},
          "whisper":"@Stevia_ Hi, I'd like to buy your {0} for my {1} in Standard",
          "offers":[
            {"exchange":{"currency":"chaos","amount":1,"whisper":"{0} Chaos Orb"},
             "item":{"currency":"alt","amount":4,"stock":4781,"whisper":"{0} Orb of Alteration"}},
            {"exchange":{"currency":"divine","amount":0.25,"whisper":"{0} Divine Orb"},
             "item":{"currency":"alt","amount":1250,"stock":4781,"whisper":"{0} Orb of Alteration"}}
          ]}}}}
        """#
        let transport = StubTradeTransport([.init(json: json)])
        let (client, fallback) = makeClient([])
        let page = try await client.exchange(queryJSON: exchangeQuery.replacingOccurrences(of: "fusing", with: "alt"),
                                             league: "Standard", transport: transport)
        let chaos = try XCTUnwrap(page.offers.first { $0.exchangeCurrency == "chaos" })
        let divine = try XCTUnwrap(page.offers.first { $0.exchangeCurrency == "divine" })
        XCTAssertEqual(chaos.whisper, "@Stevia_ Hi, I'd like to buy your 4 Orb of Alteration for my 1 Chaos Orb in Standard")
        XCTAssertEqual(divine.whisper, "@Stevia_ Hi, I'd like to buy your 1250 Orb of Alteration for my 0.25 Divine Orb in Standard")
        XCTAssertFalse(chaos.whisper!.contains("4781"), "Copy the listed lot, not the entire available stock")
        XCTAssertFalse(divine.whisper!.contains("1,250"), "Whisper quantities must not use locale grouping")
        XCTAssertTrue(fallback.requests.isEmpty)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testExchangeIncompleteOrUnknownWhisperTemplatesAreNotCopyable() async throws {
        let template = "@Seller Hi, I'd like to buy your {0} for my {1} in Standard"
        let cases: [(String, String?, String?)] = [
            (template, nil, "{0} Chaos Orb"),
            (template, "{0} Orb of Alteration", nil),
            (template, "{2} Orb of Alteration", "{0} Chaos Orb"),
            (template, "{0} Orb of Alteration", "Chaos Orb"),
            (template + " {2}", "{0} Orb of Alteration", "{0} Chaos Orb")
        ]
        let (client, fallback) = makeClient([])
        for (base, itemTemplate, exchangeTemplate) in cases {
            var item: [String: Any] = ["currency": "alt", "amount": 4, "stock": 4781]
            var exchange: [String: Any] = ["currency": "chaos", "amount": 1]
            item["whisper"] = itemTemplate
            exchange["whisper"] = exchangeTemplate
            let response: [String: Any] = ["id": "bulk", "total": 1, "result": ["seller": ["id": "seller", "listing": [
                "account": ["name": "ExampleSeller"], "whisper": base,
                "offers": [["exchange": exchange, "item": item]]
            ]]]]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
            let transport = StubTradeTransport([.init(json: json)])
            let page = try await client.exchange(queryJSON: exchangeQuery, league: "Standard", transport: transport)
            XCTAssertEqual(page.offers.count, 1, "An incomplete whisper must not discard a valid price result")
            XCTAssertNil(page.offers[0].whisper)
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
        XCTAssertTrue(fallback.requests.isEmpty)
    }

    func testExchangeRejectsInvalidQueriesAndPrices() async throws {
        let (client, fixture) = makeClient([])
        for input in [query, "{}", #"{"query":{"have":[],"want":["fusing"]}}"#, #"{"query":{"have":["chaos"],"want":[""]}}"#] {
            do {
                _ = try await client.exchange(queryJSON: input, league: "Standard")
                XCTFail("Expected invalid exchange query")
            } catch let error as TradeClientError {
                guard case .invalidRequest = error else { return XCTFail("Wrong error: \(error)") }
            }
        }
        XCTAssertTrue(fixture.requests.isEmpty)
        for amount in [0, -1] {
            let response: [String: Any] = ["id": "bulk", "total": 1, "result": ["item": ["id": "item", "listing": [
                "account": ["name": "Seller"], "offers": [["exchange": ["currency": "chaos", "amount": 1],
                                                         "item": ["amount": amount, "stock": 10]]]
            ]]]]
            let json = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
            let transport = StubTradeTransport([.init(json: json)])
            do {
                _ = try await client.exchange(queryJSON: exchangeQuery, league: "Standard", transport: transport)
                XCTFail("Expected invalid exchange price")
            } catch let error as TradeClientError {
                guard case .malformedResponse = error else { return XCTFail("Wrong error: \(error)") }
            }
            let requests = await transport.requests
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testExchangeRateLimitDoesNotRetryOrUseDefaultSession() async throws {
        let transport = StubTradeTransport([.init(status: 429, json: "{}", headers: ["Retry-After": "7"])])
        let (client, fallback) = makeClient([])
        do {
            _ = try await client.exchange(queryJSON: exchangeQuery, league: "Standard", transport: transport)
            XCTFail("Expected rate limit")
        } catch let error as TradeClientError {
            XCTAssertEqual(error.retryAfter, 7)
            XCTAssertTrue(error.localizedDescription.contains("429"))
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(fallback.requests.isEmpty)
    }

    func testCancelledExchangeReleasesQueueForLeagues() async throws {
        let transport = StubTradeTransport([.init(json: #"{"id":"bulk","total":0,"result":{}}"#, delay: 1)])
        let (client, fixture) = makeClient([.init(json: #"{"result":[{"id":"Standard"}]}"#)])
        let task = Task { try await client.exchange(queryJSON: exchangeQuery, league: "Standard", transport: transport) }
        while await transport.requests.isEmpty { await Task.yield() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        let leagues = try await client.leagues()
        XCTAssertEqual(leagues, ["Standard"])
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testRateLimitHeadersMatchSpentWindowsAndChooseLongestRule() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://www.pathofexile.com/api/trade/data/leagues")!,
            statusCode: 200, httpVersion: nil, headerFields: [
                "X-Rate-Limit-Rules": "ip, account",
                "X-Rate-Limit-Ip": "20:60:120,100:300:600",
                // The states are deliberately reordered: counts must match their own window.
                "X-Rate-Limit-Ip-State": "100:300:0,19:60:0",
                "X-Rate-Limit-Account": "10:10:60",
                "X-Rate-Limit-Account-State": "10:10:0"
            ]))
        XCTAssertEqual(TradeClient.serverRateLimitDelay(response), 300)
    }

    func testRateLimitHeadersDiscoverRulesAndRespectOnlyActivePenalty() throws {
        let url = URL(string: "https://www.pathofexile.com/api/trade/data/leagues")!
        let active = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "x-rate-limit": "account",
            "x-rate-limit-account": "10:60:600",
            "x-rate-limit-account-state": "2:60:23",
            // Rule discovery also works without a rule being named in either announcement.
            "x-rate-limit-ip": "1:30:600",
            "x-rate-limit-ip-state": "1:30:0"
        ]))
        XCTAssertEqual(TradeClient.serverRateLimitDelay(active), 30)
        let penalty = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "X-Rate-Limit-Account": "10:60:600", "X-Rate-Limit-Account-State": "2:60:23"
        ]))
        XCTAssertEqual(TradeClient.serverRateLimitDelay(penalty), 23)
        let available = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "X-Rate-Limit-Account": "10:60:600", "X-Rate-Limit-Account-State": "9:60:0"
        ]))
        XCTAssertEqual(TradeClient.serverRateLimitDelay(available), 0)
    }

    func testRateLimitHeadersIgnoreMissingMalformedAndNonfiniteTriples() throws {
        let url = URL(string: "https://www.pathofexile.com/api/trade/data/leagues")!
        let invalid: [[String: String]] = [
            [:], ["X-Rate-Limit-Rules": "ip"], ["X-Rate-Limit-Ip-State": "1:60:20"],
            ["X-Rate-Limit-Ip": "1:60:20", "X-Rate-Limit-Ip-State": "1:30:20"],
            ["X-Rate-Limit-Ip": "0:60:20", "X-Rate-Limit-Ip-State": "1:60:20"],
            ["X-Rate-Limit-Ip": "1:60:20", "X-Rate-Limit-Ip-State": "1:60"],
            ["X-Rate-Limit-Ip": "1:60:20", "X-Rate-Limit-Ip-State": "1:60:-2"],
            ["X-Rate-Limit-Ip": "1:60:20", "X-Rate-Limit-Ip-State": "1:60:nan"],
            ["X-Rate-Limit-Ip": "1:inf:20", "X-Rate-Limit-Ip-State": "1:inf:0"],
            ["X-Rate-Limit-Ip": "1:60:20", "X-Rate-Limit-Ip-State": "1e999:60:0"]
        ]
        for headers in invalid {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers))
            XCTAssertEqual(TradeClient.serverRateLimitDelay(response), 0, "Headers: \(headers)")
        }
    }

    func testSuccessfulRateLimitHeadersDelayNextRequestAndAddExtraDelay() async throws {
        let (client, fixture) = makeClient([
            .init(json: #"{"result":[]}"#, headers: [
                "X-Rate-Limit-Ip": "1:0.09:1", "X-Rate-Limit-Ip-State": "1:0.09:0"
            ]), .init(json: #"{"result":[]}"#)
        ], interval: 0.01)
        await client.setExtraDelay(0.03)
        _ = try await client.leagues()
        _ = try await client.leagues()
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertGreaterThanOrEqual(fixture.startTimes[1].timeIntervalSince(fixture.startTimes[0]), 0.115)
    }

    func testErrorRateLimitHeadersApplyAcrossTransportsWithoutRetry() async throws {
        let transport = StubTradeTransport([.init(status: 403, json: "{}", headers: [
            "X-Rate-Limit-Account": "10:0.05:1", "X-Rate-Limit-Account-State": "1:0.05:0.12"
        ])])
        let (client, fixture) = makeClient([.init(json: #"{"result":[]}"#)])
        let started = Date()
        do { _ = try await client.leagues(transport: transport); XCTFail("Expected forbidden") }
        catch let error as TradeClientError {
            guard case .http(statusCode: 403, _, _) = error else { return XCTFail("Wrong error: \(error)") }
        }
        _ = try await client.leagues()
        XCTAssertGreaterThanOrEqual(fixture.startTimes[0].timeIntervalSince(started), 0.115)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(fixture.requests.count, 1)
    }

    func testCancellationWhileWaitingForServerWindowDoesNotSendOrClearCooldown() async throws {
        let (client, fixture) = makeClient([
            .init(json: #"{"result":[]}"#, headers: [
                "X-Rate-Limit-Rules": "ip", "X-Rate-Limit-Ip": "1:0.2:1", "X-Rate-Limit-Ip-State": "1:0.2:0"
            ]), .init(json: #"{"result":[]}"#)
        ])
        _ = try await client.leagues()
        let queued = Task { try await client.leagues() }
        try await Task.sleep(nanoseconds: 20_000_000)
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertEqual(fixture.requests.count, 1)
        _ = try await client.leagues()
        XCTAssertEqual(fixture.requests.count, 2)
        XCTAssertGreaterThanOrEqual(fixture.startTimes[1].timeIntervalSince(fixture.startTimes[0]), 0.195)
    }

    private func makeClient(_ responses: [StubResponse], interval: TimeInterval = 0) -> (TradeClient, StubFixture) {
        let fixture = StubFixture(responses)
        let id = UUID().uuidString
        StubURLProtocol.register(fixture, id: id)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        config.httpAdditionalHeaders = ["X-Trade-Test-Session": id]
        let session = URLSession(configuration: config)
        addTeardownBlock {
            session.invalidateAndCancel()
            StubURLProtocol.unregister(id)
        }
        return (TradeClient(session: session, minimumRequestInterval: interval), fixture)
    }
}

private struct StubResponse: Sendable {
    var status = 200
    var json: String
    var headers: [String: String] = [:]
    var delay: TimeInterval = 0
    var responseURL: URL?
}

private actor StubTradeTransport: TradeHTTPTransport {
    private var responses: [StubResponse]
    private let failure: URLError?
    private(set) var requests: [URLRequest] = []
    private(set) var activeRequests = 0
    private(set) var maximumActive = 0

    init(_ responses: [StubResponse], failure: URLError? = nil) {
        self.responses = responses
        self.failure = failure
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        activeRequests += 1
        maximumActive = max(maximumActive, activeRequests)
        defer { activeRequests -= 1 }
        if let failure { throw failure }
        guard !responses.isEmpty else { throw URLError(.resourceUnavailable) }
        let response = responses.removeFirst()
        if response.delay > 0 { try await Task.sleep(nanoseconds: UInt64(response.delay * 1_000_000_000)) }
        try Task.checkCancellation()
        let http = HTTPURLResponse(url: response.responseURL ?? request.url!, statusCode: response.status,
                                   httpVersion: "HTTP/1.1", headerFields: response.headers)!
        return (Data(response.json.utf8), http)
    }
}

private final class StubFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [StubResponse]
    private var recordedRequests: [URLRequest] = []
    private var recordedStartTimes: [Date] = []
    private var active = 0
    private var maxActive = 0
    init(_ responses: [StubResponse]) { self.responses = responses }
    var requests: [URLRequest] { lock.withLock { recordedRequests } }
    var startTimes: [Date] { lock.withLock { recordedStartTimes } }
    var maximumActive: Int { lock.withLock { maxActive } }
    func begin(_ request: URLRequest) -> StubResponse? {
        lock.withLock {
            recordedRequests.append(request)
            recordedStartTimes.append(Date())
            active += 1
            maxActive = max(maxActive, active)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
    }
    func finish() { lock.withLock { active -= 1 } }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var fixtures: [String: StubFixture] = [:]
    private var work: DispatchWorkItem?
    static func register(_ fixture: StubFixture, id: String) { lock.withLock { fixtures[id] = fixture } }
    static func unregister(_ id: String) { _ = lock.withLock { fixtures.removeValue(forKey: id) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Trade-Test-Session") ?? ""
        guard let fixture = Self.lock.withLock({ Self.fixtures[id] }),
              let response = fixture.begin(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }
        let work = DispatchWorkItem { [self] in
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status,
                                       httpVersion: "HTTP/1.1", headerFields: response.headers)!
            fixture.finish()
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(response.json.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
        self.work = work
        DispatchQueue.global().asyncAfter(deadline: .now() + response.delay, execute: work)
    }
    override func stopLoading() { work?.cancel() }
}
