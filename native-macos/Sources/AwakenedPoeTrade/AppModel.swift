import AppKit
import SwiftUI
import TradeCore

enum AppSection: String, CaseIterable, Identifiable {
    case check = "Price check", history = "Recent items", guide = "How to use"
    var id: Self { self }
    var symbol: String {
        switch self { case .check: return "tag"; case .history: return "clock"; case .guide: return "book" }
    }
}

struct RecentItem: Codable, Identifiable {
    var id: UUID = UUID()
    let name: String
    let baseType: String
    let rarity: String
    let text: String
    let language: String
    let date: Date
}

@MainActor final class AppModel: ObservableObject {
    @Published var section: AppSection? = .check
    @Published var inputText = ""
    @Published var analysis: NativeAnalysis?
    @Published var presetID = ""
    @Published var error: String?
    @Published var notice: String?
    @Published var queryJSON = ""
    @Published var searchPage: TradeSearchPage?
    @Published var exchangePage: TradeExchangePage?
    @Published var selectedExchangeCurrency = "chaos"
    @Published var isSearching = false
    @Published var isLoadingMore = false
    @Published var needsTradeSession = false
    @Published var queryKind = "trade"
    @Published var isLoadingLeagues = false
    @Published var leagueError: String?
    @Published var leagues = ["Standard", "Hardcore"]
    @Published var history: [RecentItem] = []
    @Published var showSettings = false
    @Published var shortcut: CheckShortcut { didSet { defaults.set(shortcut.rawValue, forKey: "checkShortcut"); integration.updateCheckShortcut(shortcut) } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: "restoreClipboard"); integration.restoreClipboard = restoreClipboard } }
    @Published var smartSearch: Bool { didSet { defaults.set(smartSearch, forKey: "smartSearch") } }
    @Published var league: String { didSet { defaults.set(league, forKey: "league"); rebuildQuery() } }
    @Published var language: String { didSet { defaults.set(language, forKey: "language") } }
    @Published var rememberHistory: Bool { didSet { defaults.set(rememberHistory, forKey: "rememberHistory") } }
    @Published var appearance: String { didSet { defaults.set(appearance, forKey: "appearance") } }
    @Published var merchantOnly: Bool { didSet { defaults.set(merchantOnly, forKey: "merchantOnly") } }
    @Published var defaultCurrency: String { didSet { defaults.set(defaultCurrency, forKey: "defaultCurrency") } }
    @Published var collapseListings: String { didSet { defaults.set(collapseListings, forKey: "collapseListings") } }
    @Published var activateStockFilter: Bool { didSet { defaults.set(activateStockFilter, forKey: "activateStockFilter") } }
    @Published var searchStatRange: Double { didSet { defaults.set(searchStatRange, forKey: "searchStatRange") } }
    @Published var extraRequestDelay: Double { didSet { defaults.set(extraRequestDelay, forKey: "extraRequestDelay") } }
    @Published var accountName: String { didSet { defaults.set(accountName, forKey: "accountName") } }
    @Published var sellerDisplay: String { didSet { defaults.set(sellerDisplay, forKey: "sellerDisplay") } }
    @Published var useBrowserSession: Bool { didSet { defaults.set(useBrowserSession, forKey: "useBrowserSession"); invalidateSearch() } }
    @Published var builtInBrowser: Bool { didSet { defaults.set(builtInBrowser, forKey: "builtInBrowser") } }
    let integration = MacIntegration()
    let tradeSession = TradeBrowserSession()
    private let defaults = UserDefaults.standard
    private var bridge: NativeBridge?
    private let client = TradeClient()
    private var searchTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var loadMoreGeneration = UUID()
    private var resultTransport: (any TradeHTTPTransport)?
    private var builtQueryURL: URL?
    private var exchangeCache: [String: TradeExchangePage] = [:]
    private var searchGeneration = UUID()

    init() {
        shortcut = CheckShortcut(rawValue: UserDefaults.standard.string(forKey: "checkShortcut") ?? "") ?? .ctrlD
        restoreClipboard = UserDefaults.standard.object(forKey: "restoreClipboard") as? Bool ?? true
        smartSearch = UserDefaults.standard.object(forKey: "smartSearch") as? Bool ?? true
        league = UserDefaults.standard.string(forKey: "league") ?? "Standard"
        language = UserDefaults.standard.string(forKey: "language") ?? "en"
        rememberHistory = UserDefaults.standard.object(forKey: "rememberHistory") as? Bool ?? true
        appearance = UserDefaults.standard.string(forKey: "appearance") ?? "system"
        merchantOnly = UserDefaults.standard.object(forKey: "merchantOnly") as? Bool ?? true
        defaultCurrency = UserDefaults.standard.string(forKey: "defaultCurrency") ?? ""
        collapseListings = UserDefaults.standard.string(forKey: "collapseListings") ?? "api"
        activateStockFilter = UserDefaults.standard.bool(forKey: "activateStockFilter")
        searchStatRange = min(50, max(0, UserDefaults.standard.object(forKey: "searchStatRange") as? Double ?? 10))
        extraRequestDelay = min(10, max(0, UserDefaults.standard.double(forKey: "extraRequestDelay")))
        accountName = UserDefaults.standard.string(forKey: "accountName") ?? ""
        sellerDisplay = UserDefaults.standard.string(forKey: "sellerDisplay") ?? "none"
        useBrowserSession = UserDefaults.standard.bool(forKey: "useBrowserSession")
        builtInBrowser = UserDefaults.standard.bool(forKey: "builtInBrowser")
        if let cached = UserDefaults.standard.stringArray(forKey: "cachedLeagues"), !cached.isEmpty {
            leagues = cached
        }
        if let data = UserDefaults.standard.data(forKey: "recentItems") {
            history = (try? JSONDecoder().decode([RecentItem].self, from: data)) ?? []
        }
        do { bridge = try NativeBridge() } catch { self.error = error.localizedDescription }
        integration.restoreClipboard = restoreClipboard
        integration.registerCheckShortcut(shortcut) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let text):
                inputText = text
                checkText()
                MacIntegration.bringToFront()
                if smartSearch, analysis?.shouldAutoSearch == true, analysis?.requiresIdentification != true {
                    search()
                }
            case .failure(let failure):
                error = failure.localizedDescription
                if (failure as? ItemCaptureFailure)?.shouldPresentApp != false { MacIntegration.bringToFront() }
            }
        }
    }

    var colorScheme: ColorScheme? { appearance == "dark" ? .dark : appearance == "light" ? .light : nil }
    var effectiveLeague: String {
        let trimmed = league.trimmingCharacters(in: .whitespacesAndNewlines)
        return ["標準模式": "Standard", "專家模式": "Hardcore"][trimmed] ?? trimmed
    }
    var activePreset: NativePreset? { analysis?.presets.first { $0.id == presetID } }
    var isPrivateLeague: Bool { effectiveLeague.range(of: #"\(PL\d+\)$"#, options: [.regularExpression, .caseInsensitive]) != nil }
    var usesTradeSession: Bool { useBrowserSession || isPrivateLeague }
    var searchOptions: NativeSearchOptions {
        NativeSearchOptions(merchantOnly: merchantOnly, currency: defaultCurrency.isEmpty ? nil : defaultCurrency,
                            collapseListings: collapseListings, activateStockFilter: activateStockFilter,
                            searchStatRange: searchStatRange)
    }
    var browserURL: URL? {
        if let page = searchPage { return TradeClient.resultURL(league: effectiveLeague, searchID: page.searchID) }
        if let page = exchangePage { return TradeClient.exchangeResultURL(league: effectiveLeague, searchID: page.searchID) }
        return queryJSON.isEmpty ? nil : builtQueryURL
    }

    func pasteAndCheck() {
        section = .check
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            error = "The clipboard has no item text. Hover an item in Path of Exile and copy it first."
            return
        }
        inputText = text
        checkText()
    }

    func checkText() {
        let previousIdentity = analysis?.item.id
        let previousCurrency = activePreset?.filters["trade"]["currency"]
        invalidateSearch()
        error = nil
        notice = nil
        guard let bridge else { error = NativeBridgeError.unavailable.localizedDescription; return }
        do {
            var result = try bridge.analyze(text: inputText, league: effectiveLeague, language: language, options: searchOptions)
            if result.item.id == previousIdentity, let previousCurrency {
                for index in result.presets.indices {
                    var trade = result.presets[index].filters["trade"]
                    trade["currency"] = previousCurrency
                    result.presets[index].filters["trade"] = trade
                }
            }
            analysis = result
            presetID = result.activePreset
            section = .check
            rebuildQuery()
            if rememberHistory {
                history.removeAll { $0.text == inputText && $0.language == language }
                history.insert(RecentItem(name: result.item.name, baseType: result.item.baseType, rarity: result.item.rarity, text: inputText, language: language, date: Date()), at: 0)
                history = Array(history.prefix(50))
                persistHistory()
            }
        } catch {
            analysis = nil
            queryJSON = ""
            self.error = error.localizedDescription
        }
    }

    func openRecent(_ item: RecentItem) {
        language = item.language
        inputText = item.text
        checkText()
    }

    func newCheck() {
        invalidateSearch()
        inputText = ""; analysis = nil; queryJSON = ""; builtQueryURL = nil; error = nil; notice = nil; needsTradeSession = false; section = .check
    }

    func loadExample() {
        language = "en"
        inputText = """
        Item Class: Body Armours
        Rarity: Unique
        Tabula Rasa
        Simple Robe
        --------
        Sockets: W-W-W-W-W-W
        --------
        Item Level: 80
        --------
        Corrupted
        """
        checkText()
        notice = "Example item loaded. Search to request current listings."
    }

    func selectPreset(_ id: String) { presetID = id; rebuildQuery() }

    func replaceActivePreset(_ preset: NativePreset, sourceText: String, sourcePresetID: String) {
        guard analysis?.item.rawText == sourceText, presetID == sourcePresetID,
              let index = analysis?.presets.firstIndex(where: { $0.id == sourcePresetID }) else { return }
        if let previous = analysis?.presets[index], previous.filters == preset.filters,
           previous.stats == preset.stats, previous.tradeTag == preset.tradeTag { return }
        analysis?.presets[index] = preset
        rebuildQuery()
    }

    func resolveUnique(_ id: String) {
        guard let bridge, let source = analysis, source.requiresIdentification == true else { return }
        do {
            analysis = try bridge.resolveUnique(text: source.item.rawText, league: effectiveLeague,
                                                language: source.language, uniqueRefName: id, options: searchOptions)
            presetID = analysis?.activePreset ?? ""
            rebuildQuery()
            if smartSearch { search() }
        } catch { self.error = error.localizedDescription }
    }

    func updateStat(index: Int, child: Int? = nil, field: String, value: JSONValue) {
        guard let pi = analysis?.presets.firstIndex(where: { $0.id == presetID }),
              var preset = analysis?.presets[pi], preset.stats.indices.contains(index) else { return }
        if let child {
            var children = preset.stats[index]["stats"].array
            guard children.indices.contains(child) else { return }
            setField(&children[child], field: field, value: value)
            preset.stats[index]["stats"] = .array(children)
        } else if preset.stats[index]["group"].string != nil {
            var meta = preset.stats[index]["meta"]
            setField(&meta, field: field, value: value)
            preset.stats[index]["meta"] = meta
        } else { setField(&preset.stats[index], field: field, value: value) }
        guard analysis?.presets[pi].stats != preset.stats else { return }
        analysis?.presets[pi] = preset
        rebuildQuery()
    }

    private func setField(_ stat: inout JSONValue, field: String, value: JSONValue) {
        if field == "disabled" { stat[field] = value }
        else { var roll = stat["roll"]; roll[field] = value; stat["roll"] = roll; stat["disabled"] = .bool(false) }
    }

    func updateItemFilter(key: String, enabled: Bool) {
        guard let pi = analysis?.presets.firstIndex(where: { $0.id == presetID }), var preset = analysis?.presets[pi] else { return }
        guard preset.filters[key]["disabled"].bool != !enabled else { return }
        var filter = preset.filters[key]; filter["disabled"] = .bool(!enabled); preset.filters[key] = filter
        analysis?.presets[pi] = preset
        rebuildQuery()
    }

    func updateItemFilterValue(key: String, value: JSONValue) {
        guard let pi = analysis?.presets.firstIndex(where: { $0.id == presetID }), var preset = analysis?.presets[pi] else { return }
        guard preset.filters[key]["value"] != value else { return }
        var filter = preset.filters[key]; filter["value"] = value; preset.filters[key] = filter
        analysis?.presets[pi] = preset
        rebuildQuery()
    }

    func updateTradeFilter(key: String, value: JSONValue) {
        updateTradeFilters([key: value])
    }

    func updateTradeFilters(_ values: [String: JSONValue]) {
        guard let pi = analysis?.presets.firstIndex(where: { $0.id == presetID }), var preset = analysis?.presets[pi] else { return }
        var trade = preset.filters["trade"]
        for (key, value) in values { trade[key] = value }
        guard trade != preset.filters["trade"] else { return }
        preset.filters["trade"] = trade
        analysis?.presets[pi] = preset
        rebuildQuery()
    }

    func rebuildQuery() {
        invalidateSearch()
        queryJSON = ""; builtQueryURL = nil
        guard let bridge, let preset = activePreset, let analysis else { return }
        guard !effectiveLeague.isEmpty else { queryJSON = ""; error = "Choose a league before searching."; return }
        do {
            let result = try bridge.buildQuery(preset: preset, league: effectiveLeague, language: analysis.language)
            queryJSON = try result.query.encoded(pretty: true)
            queryKind = result.kind ?? "trade"
            builtQueryURL = URL(string: result.url)
            error = nil
        } catch { queryJSON = ""; self.error = error.localizedDescription }
    }

    func search(exchangeCurrency: String? = nil) {
        guard !queryJSON.isEmpty, !isSearching else { return }
        if usesTradeSession, !tradeSession.isReadyForRequests {
            needsTradeSession = true
            notice = "Open the trade session, sign in for your private league, then return here and retry the search."
            tradeSession.openLogin()
            return
        }
        error = nil; notice = nil; searchPage = nil; isSearching = true
        if exchangeCurrency == nil { exchangePage = nil; exchangeCache = [:] }
        needsTradeSession = false
        cancelLoadMore()
        let generation = UUID(); searchGeneration = generation
        let query = exchangeCurrency.map { exchangeQuery(currency: $0) } ?? queryJSON
        let selectedLeague = effectiveLeague, kind = queryKind
        let transport: (any TradeHTTPTransport)? = usesTradeSession ? tradeSession : nil
        let extraDelay = extraRequestDelay
        let groupMerchants = activePreset?.filters["trade"]["collapseMerchant"].bool ?? false
        searchTask = Task { [weak self] in
            guard let self else { return }
            do {
                await client.setExtraDelay(extraDelay)
                if kind == "bulk" {
                    let page = try await client.exchange(queryJSON: query, league: selectedLeague, transport: transport)
                    guard !Task.isCancelled, searchGeneration == generation else { return }
                    for currency in page.requestedCurrencies {
                        let count = page.offers.filter { $0.exchangeCurrency == currency }.count
                        if page.requestedCurrencies.count == 1 || !(currency == "chaos" && count < 20 && page.total > 100) {
                            exchangeCache[currency] = page
                        }
                    }
                    if page.requestedCurrencies.count == 1 { selectedExchangeCurrency = page.requestedCurrencies[0] }
                    exchangePage = page
                    if exchangeCurrency == nil, exchangeCache[selectedExchangeCurrency] == nil,
                       page.requestedCurrencies.contains(selectedExchangeCurrency) {
                        let narrowed = try await client.exchange(queryJSON: exchangeQuery(currency: selectedExchangeCurrency),
                                                                 league: selectedLeague, transport: transport)
                        guard !Task.isCancelled, searchGeneration == generation else { return }
                        exchangeCache[selectedExchangeCurrency] = narrowed
                        exchangePage = narrowed
                    }
                } else {
                    let page = try await client.search(queryJSON: query, league: selectedLeague, transport: transport,
                                                       collapseMerchant: groupMerchants)
                    guard !Task.isCancelled, searchGeneration == generation else { return }
                    searchPage = page
                }
                resultTransport = transport
            } catch {
                guard !Task.isCancelled, searchGeneration == generation else { return }
                handleTradeFailure(error)
            }
            if searchGeneration == generation { isSearching = false }
        }
    }

    func cancelSearch() { invalidateSearch(); notice = "Search cancelled." }
    private func invalidateSearch() {
        cancelLoadMore(); resultTransport = nil
        exchangePage = nil; exchangeCache = [:]
        searchGeneration = UUID(); searchTask?.cancel(); searchTask = nil; isSearching = false; searchPage = nil
    }

    func loadMoreListings() {
        guard let page = searchPage, page.hasMore, !isLoadingMore, !isSearching else { return }
        isLoadingMore = true; error = nil
        let generation = searchGeneration, transport = resultTransport
        let loadGeneration = UUID(); loadMoreGeneration = loadGeneration
        loadMoreTask = Task { [weak self] in
            guard let self else { return }
            defer { if searchGeneration == generation, loadMoreGeneration == loadGeneration { isLoadingMore = false } }
            do {
                let expanded = try await client.fetchMore(page: page, transport: transport)
                guard !Task.isCancelled, searchGeneration == generation, loadMoreGeneration == loadGeneration else { return }
                searchPage = expanded
            } catch {
                guard !Task.isCancelled, searchGeneration == generation, loadMoreGeneration == loadGeneration else { return }
                handleTradeFailure(error)
            }
        }
    }

    func cancelLoadMore() { loadMoreGeneration = UUID(); loadMoreTask?.cancel(); loadMoreTask = nil; isLoadingMore = false }

    private func handleTradeFailure(_ error: Error) {
        self.error = error.localizedDescription
        if case let TradeClientError.http(statusCode, _, _) = error,
           statusCode == 401 || statusCode == 403 || (statusCode == 400 && isPrivateLeague) {
            needsTradeSession = true
            notice = statusCode == 400
                ? "The trade service rejected this query. For a private league, check the exact league name and sign in with an account that can access it."
                : "Complete sign-in or browser verification in this app’s trade session, then retry."
        } else if error is TradeBrowserError { needsTradeSession = true }
    }

    func copyWhisper(_ listing: TradeListing) {
        copyWhisperText(listing.whisper)
    }

    func copyWhisper(_ offer: TradeExchangeOffer) { copyWhisperText(offer.whisper) }

    private func copyWhisperText(_ text: String?) {
        guard let text, !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        notice = "Whisper copied. Paste it into the game when you’re ready."
    }

    func selectExchangeCurrency(_ currency: String) {
        guard !isSearching, ["chaos", "divine"].contains(currency) else { return }
        selectedExchangeCurrency = currency
        if let page = exchangeCache[currency] { exchangePage = page }
        else { search(exchangeCurrency: currency) }
    }

    private func exchangeQuery(currency: String) -> String {
        guard let data = queryJSON.data(using: .utf8),
              var value = try? JSONDecoder().decode(JSONValue.self, from: data) else { return queryJSON }
        var query = value["query"]
        query["have"] = .array([.string(currency)])
        value["query"] = query
        return (try? value.encoded()) ?? queryJSON
    }

    func openTradeSession() {
        if !useBrowserSession { useBrowserSession = true }
        tradeSession.openLogin()
    }

    func retryWithTradeSession() {
        if !useBrowserSession { useBrowserSession = true }
        search()
    }

    func refreshLeagues() async {
        guard !isLoadingLeagues else { return }
        isLoadingLeagues = true
        defer { isLoadingLeagues = false }
        do {
            await client.setExtraDelay(extraRequestDelay)
            let transport: (any TradeHTTPTransport)? = usesTradeSession && tradeSession.isReadyForRequests ? tradeSession : nil
            let loaded = try await client.leagues(transport: transport)
            guard !loaded.isEmpty else {
                leagueError = "No leagues were returned. Refresh the list or enter a league name below."
                return
            }
            leagues = loaded
            defaults.set(loaded, forKey: "cachedLeagues")
            leagueError = nil
        } catch is CancellationError {
            // Dismissing the picker should not replace a useful cached list with an error.
        } catch {
            leagueError = "Could not refresh leagues. Showing the last available list; you can enter a league name below. " + error.localizedDescription
        }
    }

    func openTrade() {
        guard let url = browserURL else { return }
        if builtInBrowser || usesTradeSession { tradeSession.openTrade(url); return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.open(url, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.error = "Could not open the trade site: " + error.localizedDescription }
                else { self?.notice = "Opened the search in your default browser." }
            }
        }
    }
    func copyQuery() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(queryJSON, forType: .string)
        notice = "Trade query copied."
    }
    func clearHistory() { history = []; persistHistory() }
    private func persistHistory() {
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: "recentItems") }
    }
}
