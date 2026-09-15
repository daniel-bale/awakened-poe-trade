import Foundation
import JavaScriptCore

public enum JSONValue: Codable, Equatable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    public subscript(key: String) -> JSONValue {
        get { if case .object(let v) = self { return v[key] ?? .null }; return .null }
        set { if case .object(var v) = self { v[key] = newValue; self = .object(v) } }
    }
    public var array: [JSONValue] { if case .array(let v) = self { return v }; return [] }
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var number: Double? { if case .number(let v) = self { return v }; return nil }
    public func encoded(pretty: Bool = false) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}

public struct NativeItem: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let baseType: String
    public let rarity: String
    public let category: String?
    public let itemLevel: Int?
    public let icon: String?
    public let properties: [ItemProperty]
    public let modifiers: [ItemModifier]
    public let unknownModifiers: [String]
    public let rawText: String
    public let identity: String?
    public let dustEquivalent: Int?
    public let market: MarketItemMetadata?
}

public struct ItemProperty: Codable, Sendable { public let label: String; public let value: String }
public struct ItemModifier: Codable, Sendable { public let text: String; public let type: String }

public struct NativePreset: Codable, Identifiable, Sendable {
    public let id: String
    public let title: String
    public var filters: JSONValue
    public var stats: [JSONValue]
    public var tradeTag: String?
}

public struct NativeSearchOptions: Codable, Sendable {
    public var merchantOnly: Bool
    public var currency: String?
    public var collapseListings: String
    public var activateStockFilter: Bool
    public var searchStatRange: Double

    public init(
        merchantOnly: Bool = true,
        currency: String? = nil,
        collapseListings: String = "api",
        activateStockFilter: Bool = false,
        searchStatRange: Double = 10
    ) {
        self.merchantOnly = merchantOnly
        self.currency = currency
        self.collapseListings = collapseListings
        self.activateStockFilter = activateStockFilter
        self.searchStatRange = searchStatRange
    }

    fileprivate var jsonValue: JSONValue {
        .object([
            "merchantOnly": .bool(merchantOnly),
            "currency": currency.map(JSONValue.string) ?? .null,
            "collapseListings": .string(collapseListings),
            "activateStockFilter": .bool(activateStockFilter),
            "searchStatRange": .number(searchStatRange)
        ])
    }
}

public struct NativeAnalysis: Codable, Sendable {
    public let language: String
    public let league: String
    public let item: NativeItem
    public var presets: [NativePreset]
    public let activePreset: String
    public let query: JSONValue
    public let url: String
    public let kind: String?
    public let requiresIdentification: Bool?
    public let uniqueCandidates: [NativeUniqueCandidate]?
    public let shouldAutoSearch: Bool?
}

public struct NativeUniqueCandidate: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let icon: String?
}

public struct NativeQuery: Codable, Sendable {
    public let query: JSONValue
    public let url: String
    public let kind: String?
}

public enum NativeBridgeError: LocalizedError {
    case unavailable, invalidInput(String), script(String)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "The item database is missing. Rebuild the native app with scripts/package-app.sh."
        case .invalidInput(let message), .script(let message): return message
        }
    }
}

/// JavaScriptCore executes the repository's parser and query builder locally. No web view or Node runtime.
@MainActor public final class NativeBridge {
    private let context: JSContext

    public init() throws {
        let packagedBundle = Bundle.main.resourceURL
            .flatMap { Bundle(url: $0.appendingPathComponent("AwakenedPoeTradeNative_TradeCore.bundle")) }
        guard let url = (packagedBundle ?? Bundle.module).url(forResource: "trade-core", withExtension: "js"),
              let context = JSContext() else { throw NativeBridgeError.unavailable }
        self.context = context
        context.evaluateScript("var console = { log: function(){}, warn: function(){}, error: function(){} }; ")
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8))
        if let error = context.exception { throw NativeBridgeError.script(error.toString() ?? "Could not load the item parser.") }
        guard context.objectForKeyedSubscript("NativeTrade")?.isObject == true else { throw NativeBridgeError.unavailable }
    }

    public func analyze(text: String, league: String, language: String, options: NativeSearchOptions = .init()) throws -> NativeAnalysis {
        try call("analyze", input: analysisInput(text: text, league: league, language: language, options: options))
    }

    public func resolveUnique(text: String, league: String, language: String, uniqueRefName: String, options: NativeSearchOptions = .init()) throws -> NativeAnalysis {
        var input = try analysisInput(text: text, league: league, language: language, options: options)
        input["uniqueRefName"] = .string(uniqueRefName)
        return try call("resolveUnique", input: input)
    }

    public func buildQuery(preset: NativePreset, league: String, language: String) throws -> NativeQuery {
        var input: JSONValue = .object(["language": .string(language), "league": .string(league), "filters": preset.filters, "stats": .array(preset.stats)])
        if let tradeTag = preset.tradeTag { input["tradeTag"] = .string(tradeTag) }
        return try call("buildQuery", input: input)
    }

    private func analysisInput(text: String, league: String, language: String, options: NativeSearchOptions) throws -> JSONValue {
        guard text.utf8.count <= 131_072 else { throw NativeBridgeError.invalidInput("This text is too long to be an item. Copy a single item from Path of Exile.") }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw NativeBridgeError.invalidInput("Copy an item in Path of Exile first, or paste its item text below.") }
        return .object([
            "text": .string(text),
            "league": .string(league),
            "language": .string(language),
            "options": options.jsonValue
        ])
    }

    private func call<T: Decodable>(_ method: String, input: JSONValue) throws -> T {
        context.exception = nil
        guard let result = context.objectForKeyedSubscript("NativeTrade")?.invokeMethod(method, withArguments: [try input.encoded()])?.toString(),
              let data = result.data(using: .utf8) else {
            throw NativeBridgeError.script(context.exception?.toString() ?? "The item parser did not return a result.")
        }
        if let error = context.exception { throw NativeBridgeError.script(error.toString() ?? "The item parser failed.") }
        let envelope = try JSONDecoder().decode(JSONValue.self, from: data)
        guard envelope["ok"].bool == true else {
            throw NativeBridgeError.invalidInput(envelope["error"].string ?? "Could not read this item. Copy a complete item in the selected game language.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
