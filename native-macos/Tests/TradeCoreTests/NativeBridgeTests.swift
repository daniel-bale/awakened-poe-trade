import Foundation
import XCTest
@testable import TradeCore

final class NativeBridgeTests: XCTestCase {
    @MainActor
    func testJavaScriptCoreParsesCurrencyAndReturnsMatchingBrowserQuery() async throws {
        let bridge = try NativeBridge()
        let result = try bridge.analyze(text: fixture("chaos-orb"), league: "Standard", language: "en")
        XCTAssertEqual(result.item.name, "Chaos Orb")
        XCTAssertEqual(result.item.rarity, "Currency")
        XCTAssertEqual(result.item.properties.first?.value, "10 / 20")
        XCTAssertEqual(result.kind, "bulk")
        XCTAssertEqual(result.query["query"]["want"].array, [.string("chaos")])
        XCTAssertEqual(result.query["query"]["have"].array, [.string("divine")])
        XCTAssertEqual(result.query["sort"]["have"].string, "asc")
        let market = try XCTUnwrap(result.item.market)
        XCTAssertEqual(market.query?.ns, "ITEM")
        XCTAssertEqual(market.query?.name, "Chaos Orb")
        XCTAssertEqual(market.stackSize, 10)
        XCTAssertEqual(market.stackMax, 20)
        XCTAssertFalse(market.predictionEligible)
        let components = try XCTUnwrap(URLComponents(string: result.url))
        XCTAssertEqual(components.host, "www.pathofexile.com")
        let encodedQuery = try XCTUnwrap(components.queryItems?.first(where: { $0.name == "q" })?.value)
        XCTAssertEqual(try JSONDecoder().decode(JSONValue.self, from: Data(encodedQuery.utf8))["exchange"], result.query["query"])
    }

    @MainActor
    func testSearchOptionsReachMerchantAndCurrencyFilters() async throws {
        let bridge = try NativeBridge()
        let result = try bridge.analyze(
            text: fixture("rare-ring"),
            league: "Standard",
            language: "en",
            options: NativeSearchOptions(currency: "divine")
        )
        XCTAssertEqual(result.query["query"]["status"]["option"].string, "securable")
        XCTAssertEqual(result.query["query"]["filters"]["trade_filters"]["filters"]["price"]["option"].string, "divine")
        let preset = try XCTUnwrap(result.presets.first(where: { $0.id == result.activePreset }))
        let rebuilt = try bridge.buildQuery(preset: preset, league: result.league, language: result.language)
        XCTAssertEqual(rebuilt.query, result.query)

        let defaults = try bridge.analyze(text: fixture("rare-ring"), league: "Standard", language: "en")
        XCTAssertEqual(defaults.query["query"]["status"]["option"].string, "securable")
        XCTAssertEqual(defaults.query["query"]["filters"]["trade_filters"]["filters"]["price"]["option"], .null)
    }

    @MainActor
    func testStockOptionSetsBulkMinimumAndTradeTagSurvivesQueryRebuild() async throws {
        let bridge = try NativeBridge()
        let result = try bridge.analyze(
            text: fixture("chaos-orb"), league: "Standard", language: "en",
            options: NativeSearchOptions(activateStockFilter: true)
        )
        XCTAssertEqual(result.kind, "bulk")
        XCTAssertEqual(result.query["query"]["minimum"].number, 10)
        let preset = try XCTUnwrap(result.presets.first(where: { $0.id == result.activePreset }))
        XCTAssertEqual(preset.tradeTag, "chaos")
        let rebuilt = try bridge.buildQuery(preset: preset, league: result.league, language: result.language)
        XCTAssertEqual(rebuilt.kind, "bulk")
        XCTAssertEqual(rebuilt.query, result.query)
        XCTAssertEqual(rebuilt.url, result.url)

        let defaults = try bridge.analyze(text: fixture("chaos-orb"), league: "Standard", language: "en")
        XCTAssertEqual(defaults.query["query"]["minimum"], .null)
    }

    @MainActor
    func testSearchOptionsCanIncludeNonMerchantListingsAndChooseWhereTheyCollapse() async throws {
        let bridge = try NativeBridge()
        let applicationCollapse = try bridge.analyze(
            text: fixture("rare-ring"),
            league: "Standard",
            language: "en",
            options: NativeSearchOptions(merchantOnly: false, collapseListings: "app")
        )
        XCTAssertEqual(applicationCollapse.query["query"]["status"]["option"].string, "available")
        XCTAssertEqual(applicationCollapse.query["query"]["filters"]["trade_filters"]["filters"]["collapse"], .null)

        let serverCollapse = try bridge.analyze(
            text: fixture("rare-ring"),
            league: "Standard",
            language: "en",
            options: NativeSearchOptions(merchantOnly: false, collapseListings: "api")
        )
        XCTAssertEqual(serverCollapse.query["query"]["filters"]["trade_filters"]["filters"]["collapse"]["option"].string, "true")
    }

    @MainActor
    func testSearchStatRangeChangesGeneratedModifierBounds() async throws {
        let bridge = try NativeBridge()
        let itemText = try fixture("rare-ring").replacingOccurrences(
            of: "+70 to maximum Life", with: "+70(60-79) to maximum Life"
        )
        let narrow = try bridge.analyze(
            text: itemText, league: "Standard", language: "en",
            options: NativeSearchOptions(searchStatRange: 0)
        )
        let wide = try bridge.analyze(
            text: itemText, league: "Standard", language: "en",
            options: NativeSearchOptions(searchStatRange: 25)
        )
        let narrowPreset = try XCTUnwrap(narrow.presets.first(where: { $0.id == "filters.preset_pseudo" }))
        let widePreset = try XCTUnwrap(wide.presets.first(where: { $0.id == narrowPreset.id }))
        let narrowLife = try XCTUnwrap(narrowPreset.stats.first(where: { $0["tradeId"].array.contains(.string("pseudo.pseudo_total_life")) }))
        let wideLife = try XCTUnwrap(widePreset.stats.first(where: { $0["tradeId"].array.contains(.string("pseudo.pseudo_total_life")) }))
        let narrowMinimum = try XCTUnwrap(narrowLife["roll"]["min"].number)
        let wideMinimum = try XCTUnwrap(wideLife["roll"]["min"].number)
        XCTAssertGreaterThan(narrowMinimum, wideMinimum)
        XCTAssertEqual(narrow.item.id, wide.item.id)
    }

    @MainActor
    func testEditedItemLevelRangeRoundTripsAndDisabledFilterIsOmitted() async throws {
        let bridge = try NativeBridge()
        let result = try bridge.analyze(text: fixture("rare-ring"), league: "Standard", language: "en")
        var preset = try XCTUnwrap(result.presets.first(where: { $0.id == result.activePreset }))
        preset.filters["itemLevel"] = .object([
            "value": .number(82), "max": .number(85), "disabled": .bool(false)
        ])

        let edited = try bridge.buildQuery(preset: preset, league: result.league, language: result.language)
        let itemLevel = edited.query["query"]["filters"]["misc_filters"]["filters"]["ilvl"]
        XCTAssertEqual(itemLevel["min"].number, 82)
        XCTAssertEqual(itemLevel["max"].number, 85)

        preset.filters["itemLevel"]["max"] = .null
        let unbounded = try bridge.buildQuery(preset: preset, league: result.league, language: result.language)
        XCTAssertEqual(unbounded.query["query"]["filters"]["misc_filters"]["filters"]["ilvl"]["min"].number, 82)
        XCTAssertEqual(unbounded.query["query"]["filters"]["misc_filters"]["filters"]["ilvl"]["max"], .null)

        preset.filters["itemLevel"]["max"] = .number(80)
        XCTAssertThrowsError(try bridge.buildQuery(preset: preset, league: result.league, language: result.language)) { error in
            XCTAssertTrue(error.localizedDescription.contains("Minimum cannot exceed maximum"))
        }
        preset.filters["itemLevel"]["disabled"] = .bool(true)
        let disabled = try bridge.buildQuery(preset: preset, league: result.league, language: result.language)
        XCTAssertEqual(disabled.query["query"]["filters"]["misc_filters"]["filters"]["ilvl"], .null)
    }

    @MainActor
    func testUnidentifiedUniqueDecodesCandidatesAndResolvesAChosenIdentity() async throws {
        let bridge = try NativeBridge()
        let text = """
        Item Class: Rings
        Rarity: Unique
        Amethyst Ring
        --------
        Item Level: 85
        --------
        { Implicit Modifier — Chaos, Resistance }
        +23% to Chaos Resistance
        --------
        Unidentified
        """
        let unresolved = try bridge.analyze(text: text, league: "Standard", language: "en")
        XCTAssertEqual(unresolved.requiresIdentification, true)
        XCTAssertEqual(unresolved.shouldAutoSearch, false)
        XCTAssertTrue(unresolved.presets.isEmpty)
        XCTAssertEqual(unresolved.query, .null)
        XCTAssertEqual(unresolved.url, "")
        let candidates = try XCTUnwrap(unresolved.uniqueCandidates)
        XCTAssertGreaterThan(candidates.count, 1)
        let candidate = try XCTUnwrap(candidates.first(where: { $0.name == "Ming's Heart" }))

        let resolved = try bridge.resolveUnique(
            text: text, league: "Standard", language: "en", uniqueRefName: candidate.id,
            options: NativeSearchOptions(currency: "divine")
        )
        XCTAssertNotEqual(resolved.requiresIdentification, true)
        XCTAssertEqual(resolved.item.name, "Ming's Heart")
        XCTAssertEqual(resolved.item.identity, resolved.item.id)
        XCTAssertFalse(resolved.presets.isEmpty)
        XCTAssertEqual(resolved.kind, "trade")
        XCTAssertEqual(resolved.query["query"]["filters"]["trade_filters"]["filters"]["price"]["option"].string, "divine")
        XCTAssertThrowsError(try bridge.resolveUnique(text: text, league: "Standard", language: "en", uniqueRefName: "Tabula Rasa"))
    }

    @MainActor
    func testRareItemDetailsAndPseudoStatsDecodeWithoutLosingRanges() async throws {
        let bridge = try NativeBridge()
        let result = try bridge.analyze(text: fixture("rare-ring"), league: "Standard", language: "en")
        XCTAssertEqual(result.item.name, "Havoc Circle")
        XCTAssertEqual(result.item.baseType, "Coral Ring")
        XCTAssertEqual(result.item.category, "Ring")
        XCTAssertEqual(result.item.itemLevel, 85)
        XCTAssertEqual(result.item.modifiers.count, 6)
        XCTAssertEqual(result.item.modifiers.last?.text, "Adds 5 to 10 Physical Damage to Attacks")
        XCTAssertTrue(result.item.unknownModifiers.isEmpty)
        let stats = queryStats(result.query)
        XCTAssertEqual(stats.first(where: { $0["id"].string == "pseudo.pseudo_total_life" })?["value"]["min"].number, 100)
        XCTAssertEqual(stats.first(where: { $0["id"].string == "pseudo.pseudo_total_elemental_resistance" })?["value"]["min"].number, 97)
    }

    @MainActor
    func testEditedNativeFiltersAndBlankBoundsRoundTripIntoQuery() async throws {
        let bridge = try NativeBridge()
        let result = try bridge.analyze(text: fixture("rare-ring"), league: "Standard", language: "en")
        var preset = try XCTUnwrap(result.presets.first(where: { $0.id == result.activePreset }))
        let lifeIndex = try XCTUnwrap(preset.stats.firstIndex(where: { $0["tradeId"].array.contains(.string("pseudo.pseudo_total_life")) }))
        var life = preset.stats[lifeIndex]
        var roll = life["roll"]
        roll["min"] = .number(80)
        roll["max"] = .number(140)
        life["roll"] = roll
        life["disabled"] = .bool(false)
        preset.stats[lifeIndex] = life
        var trade = preset.filters["trade"]
        trade["offline"] = .bool(true)
        preset.filters["trade"] = trade

        let query = try bridge.buildQuery(preset: preset, league: "A League / 測試", language: result.language)
        let filter = try XCTUnwrap(queryStats(query.query).first(where: { $0["id"].string == "pseudo.pseudo_total_life" }))
        XCTAssertEqual(filter["value"]["min"].number, 80)
        XCTAssertEqual(filter["value"]["max"].number, 140)
        XCTAssertEqual(filter["disabled"].bool, false)
        XCTAssertEqual(query.query["query"]["status"]["option"].string, "any")
        XCTAssertTrue(query.url.contains("A%20League%20%2F%20"))

        roll["min"] = .string("")
        roll["max"] = .string("")
        life["roll"] = roll
        life["disabled"] = .bool(true)
        preset.stats[lifeIndex] = life
        let cleared = try bridge.buildQuery(preset: preset, league: "Standard", language: result.language)
        let clearedFilter = try XCTUnwrap(queryStats(cleared.query).first(where: { $0["id"].string == "pseudo.pseudo_total_life" }))
        XCTAssertEqual(clearedFilter["value"]["min"], .null)
        XCTAssertEqual(clearedFilter["value"]["max"], .null)
        XCTAssertEqual(clearedFilter["disabled"].bool, true)
    }

    @MainActor
    func testGroupedNativeJSONPreservesParentAndChildEnablement() async throws {
        let bridge = try NativeBridge()
        let result = try bridge.analyze(text: fixture("rare-ring"), league: "Standard", language: "en")
        var preset = try XCTUnwrap(result.presets.first(where: { $0.id == result.activePreset }))
        var life = try XCTUnwrap(preset.stats.first(where: { $0["tradeId"].array.contains(.string("pseudo.pseudo_total_life")) }))
        var resistance = try XCTUnwrap(preset.stats.first(where: { $0["tradeId"].array.contains(.string("pseudo.pseudo_total_elemental_resistance")) }))
        life["disabled"] = .bool(false)
        resistance["disabled"] = .bool(true)
        var meta = life
        meta["tradeId"] = .array([.string("item.count_one_group")])
        meta["disabled"] = .bool(false)
        preset.stats = [.object(["group": .string("one"), "meta": meta, "stats": .array([life, resistance]), "expanded": .bool(true)])]

        let query = try bridge.buildQuery(preset: preset, league: "Standard", language: result.language)
        let group = try XCTUnwrap(query.query["query"]["stats"].array.first(where: { $0["type"].string == "count" }))
        XCTAssertEqual(group["value"]["min"].number, 1)
        XCTAssertEqual(group["disabled"].bool, false)
        XCTAssertEqual(group["filters"].array.map { $0["disabled"].bool }, [false, true])

        meta["disabled"] = .bool(true)
        preset.stats[0]["meta"] = meta
        let disabled = try bridge.buildQuery(preset: preset, league: "Standard", language: result.language)
        XCTAssertEqual(disabled.query["query"]["stats"].array.first(where: { $0["type"].string == "count" })?["disabled"].bool, true)
    }

    @MainActor
    func testEnabledReversedRangeReportsValidationError() async throws {
        let bridge = try NativeBridge()
        let result = try bridge.analyze(text: fixture("rare-ring"), league: "Standard", language: "en")
        var preset = try XCTUnwrap(result.presets.first(where: { $0.id == result.activePreset }))
        let index = try XCTUnwrap(preset.stats.firstIndex(where: { $0["tradeId"].array.contains(.string("pseudo.pseudo_total_life")) }))
        var stat = preset.stats[index]
        var roll = stat["roll"]
        roll["min"] = .number(120)
        roll["max"] = .number(80)
        stat["roll"] = roll
        stat["disabled"] = .bool(false)
        preset.stats[index] = stat
        XCTAssertThrowsError(try bridge.buildQuery(preset: preset, league: "Standard", language: "en")) { error in
            XCTAssertTrue(error.localizedDescription.contains("Minimum cannot exceed maximum"))
        }
        stat["disabled"] = .bool(true)
        preset.stats[index] = stat
        XCTAssertNoThrow(try bridge.buildQuery(preset: preset, league: "Standard", language: "en"))
    }

    @MainActor
    func testReducedModifiersRunInJavaScriptCoreAndInvertNumericBounds() async throws {
        let bridge = try NativeBridge()
        let result = try bridge.analyze(text: fixture("mings-heart"), league: "Standard", language: "en")
        XCTAssertEqual(result.item.name, "Ming's Heart")
        var preset = try XCTUnwrap(result.presets.first(where: { $0.id == result.activePreset }))
        let index = try XCTUnwrap(preset.stats.firstIndex(where: { $0["text"].string == "#% reduced maximum Life" }))
        var stat = preset.stats[index]
        let tradeID = try XCTUnwrap(stat["tradeId"].array.first?.string)
        XCTAssertEqual(stat["roll"]["isNegated"].bool, true)
        var roll = stat["roll"]
        roll["min"] = .number(15)
        roll["max"] = .number(20)
        stat["roll"] = roll
        stat["disabled"] = .bool(false)
        preset.stats[index] = stat
        let query = try bridge.buildQuery(preset: preset, league: "Standard", language: result.language)
        let filter = try XCTUnwrap(queryStats(query.query).first(where: { $0["id"].string == tradeID }))
        XCTAssertEqual(filter["value"]["min"].number, -20)
        XCTAssertEqual(filter["value"]["max"].number, -15)
    }

    @MainActor
    func testChineseAndEnglishItemsUseCanonicalQueriesAcrossOneContext() async throws {
        let bridge = try NativeBridge()
        for name in ["chaos-orb", "tabula-rasa", "rare-ring"] {
            let chinese = try bridge.analyze(text: fixture(name + "-zh"), league: "Standard", language: "cmn-Hant")
            let english = try bridge.analyze(text: fixture(name), league: "Standard", language: "en")
            XCTAssertEqual(chinese.item.id, english.item.id)
            XCTAssertNotEqual(chinese.item.name, english.item.name)
            XCTAssertEqual(chinese.query, english.query)
            XCTAssertEqual(chinese.language, "cmn-Hant")
            let preset = try XCTUnwrap(chinese.presets.first(where: { $0.id == chinese.activePreset }))
            let rebuilt = try bridge.buildQuery(preset: preset, league: "Standard", language: chinese.language)
            XCTAssertEqual(rebuilt.query, chinese.query)
        }
    }

    @MainActor
    func testInputErrorsAreRecoverableWithoutPoisoningJavaScriptContext() async throws {
        let bridge = try NativeBridge()
        for input in ["", "not a Path of Exile item", String(repeating: "x", count: 131_073)] {
            XCTAssertThrowsError(try bridge.analyze(text: input, league: "Standard", language: "en")) { error in
                XCTAssertFalse(error.localizedDescription.isEmpty)
            }
        }
        let ordinary = try fixture("rare-ring").split(separator: "\n").filter { !$0.hasPrefix("{") }.joined(separator: "\n")
        XCTAssertThrowsError(try bridge.analyze(text: ordinary, league: "Standard", language: "en")) { error in
            XCTAssertTrue(error.localizedDescription.contains("advanced modifier"))
        }
        XCTAssertThrowsError(try bridge.analyze(text: fixture("chaos-orb"), league: "Standard", language: "fr"))
        let recovered = try bridge.analyze(text: fixture("chaos-orb"), league: "Standard", language: "en")
        XCTAssertEqual(recovered.item.name, "Chaos Orb")
    }

    private func fixture(_ name: String) throws -> String {
        let nativeDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: nativeDirectory.appendingPathComponent("bridge/test/fixtures/\(name).txt"), encoding: .utf8)
    }

    private func queryStats(_ value: JSONValue) -> [JSONValue] {
        value["query"]["stats"].array.flatMap { $0["filters"].array }
    }
}
