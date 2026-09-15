import SwiftUI
import TradeCore

struct MainView: View {
    @ObservedObject var model: AppModel
    @State private var showHistory = false
    @State private var showGuide = false
    @State private var showItemText = false
    @State private var showLeaguePicker = false

    var body: some View {
        VStack(spacing: 0) {
            titlebar
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let error = model.error { MessageBanner(text: error, symbol: "exclamationmark.triangle", color: Color(hex: 0xfc8181)) }
                    if let notice = model.notice { Text(notice).font(.system(size: 11)).foregroundStyle(PoeTheme.secondary) }
                    if model.needsTradeSession {
                        TradeSessionControls(model: model, session: model.tradeSession, compact: true)
                            .padding(10).background(PoeTheme.dark)
                    }
                    if let analysis = model.analysis {
                        itemName(analysis.item)
                        if analysis.requiresIdentification == true {
                            uniqueChooser(analysis)
                        } else {
                            MarketDataView(item: analysis.item, metadata: analysis.item.market,
                                           league: model.effectiveLeague, language: analysis.language,
                                           isPublicLeague: model.leagues.contains(model.effectiveLeague),
                                           presetID: model.presetID,
                                           stackCount: model.activePreset?.filters["stackSize"]["value"].number,
                                           exchangeCurrency: model.queryKind == "bulk" ? model.selectedExchangeCurrency : nil)
                            FilterPanel(model: model).id(analysis.item.rawText + model.presetID)
                            if model.queryKind == "bulk" { BulkResultsView(model: model) }
                            else { TradeResultsView(model: model) }
                        }
                        DisclosureGroup("Item description", isExpanded: $showItemText) {
                            VStack(alignment: .leading, spacing: 7) {
                                Text(analysis.item.name + " · " + analysis.item.baseType).foregroundStyle(rarityColor(analysis.item.rarity))
                                ForEach(Array(analysis.item.properties.enumerated()), id: \.offset) { _, property in
                                    HStack { Text(property.label).foregroundStyle(PoeTheme.secondary); Spacer(); Text(property.value).font(PoeTheme.numbers) }
                                }
                                Rectangle().fill(PoeTheme.border).frame(height: 1)
                                ForEach(Array(analysis.item.modifiers.enumerated()), id: \.offset) { _, modifier in
                                    Text(modifier.text).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                }
                            }.padding(8).background(PoeTheme.dark)
                        }.foregroundStyle(PoeTheme.muted)
                    } else { emptyState }
                }.padding(16)
            }
            HStack(spacing: 8) {
                ShortcutHint(integration: model.integration, shortcut: model.shortcut)
                Spacer(minLength: 0)
                Button { model.showSettings = true } label: { Image(systemName: "gearshape.fill").font(.system(size: 12)) }.buttonStyle(.plain).help("Settings")
            }.padding(.horizontal, 12).padding(.vertical, 6).background(PoeTheme.dark)
        }
        .font(PoeTheme.font).foregroundStyle(PoeTheme.text).background(PoeTheme.background)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .onAppear {
            model.integration.refreshAccessibilityPermission()
        }
        .onExitCommand { MacIntegration.dismissToGame() }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model) }
        .sheet(isPresented: $showHistory) { HistoryView(model: model) }
        .sheet(isPresented: $showGuide) { GuideView(model: model) }
        .sheet(isPresented: $showLeaguePicker) { LeagueSelectionView(model: model) }
    }

    private var titlebar: some View {
        HStack(spacing: 0) {
            PricePanelHeaderDragArea().frame(width: 8, height: 28)
            Menu {
                Button("Check Clipboard") { model.pasteAndCheck() }
                Button("Paste Item Text…") { model.newCheck() }
                Divider()
                Button("Recent Items…") { showHistory = true }
                Button("Settings…") { model.showSettings = true }
                Button("How to Use…") { showGuide = true }
                Divider()
                Button("Quit") { NSApp.terminate(nil) }
            } label: { Image(systemName: "line.3.horizontal").font(.system(size: 12)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 28, height: 28).help("Menu")
            PricePanelHeaderDragArea().frame(minWidth: 44, maxWidth: .infinity).frame(height: 28)
            Button { showLeaguePicker = true } label: {
                HStack(spacing: 4) {
                    Text(model.effectiveLeague.isEmpty ? "Choose league" : model.effectiveLeague).lineLimit(1).truncationMode(.tail)
                    Image(systemName: "chevron.down").font(.system(size: 8))
                }.frame(width: 220, height: 28).contentShape(Rectangle())
            }.buttonStyle(.plain).help("Choose league: " + model.effectiveLeague).accessibilityLabel("Choose league: " + model.effectiveLeague)
            PricePanelHeaderDragArea().frame(minWidth: 44, maxWidth: .infinity).frame(height: 28)
            PricePanelCloseButton { MacIntegration.dismissToGame() }
                .frame(width: 28, height: 28)
            PricePanelHeaderDragArea().frame(width: 8, height: 28)
        }.foregroundStyle(PoeTheme.secondary).frame(height: 28).background(PoeTheme.dark)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Awakened PoE Trade").font(.custom("Fontin-SmallCaps", size: 19))
            Text("Hover an item in Path of Exile and press \(model.shortcut.title).")
            Text("Copies the item and opens its price check in one action.").foregroundStyle(PoeTheme.secondary)
            CapturePermissionView(integration: model.integration)
            Rectangle().fill(PoeTheme.border).frame(height: 1)
            HStack {
                Text("Item text").foregroundStyle(PoeTheme.secondary)
                Spacer()
                Picker("Item language", selection: $model.language) {
                    Text("English").tag("en"); Text("繁體中文").tag("cmn-Hant")
                }.labelsHidden().frame(width: 110).controlSize(.small)
            }
            TextEditor(text: $model.inputText).font(.system(size: 11, design: .monospaced)).scrollContentBackground(.hidden)
                .padding(6).frame(minHeight: 150).background(PoeTheme.dark).accessibilityLabel("Item text")
            HStack {
                Button("Check Clipboard") { model.pasteAndCheck() }.buttonStyle(PoeButtonStyle())
                Spacer()
                Button("Check Text") { model.checkText() }.buttonStyle(PoeButtonStyle(active: true))
                    .disabled(model.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            Button("Load example") { model.loadExample() }.buttonStyle(.plain).foregroundStyle(PoeTheme.muted)
        }.padding(.top, 4)
    }

    private func itemName(_ item: NativeItem) -> some View {
        let filters = model.activePreset?.filters ?? .null
        let relaxed = filters["searchRelaxed"]["disabled"].bool == false
        let active = filters[relaxed ? "searchRelaxed" : "searchExact"]
        let title = active["name"].string ?? active["baseType"].string ?? active["category"].string.map { "Any \($0)" } ?? item.name
        return HStack(spacing: 0) {
            Button(title) {
                guard case .object = filters["searchRelaxed"] else { return }
                model.updateItemFilter(key: "searchRelaxed", enabled: !relaxed)
            }
                .buttonStyle(PoeButtonStyle(active: !relaxed)).lineLimit(1)
                .help(item.name + "\n" + item.baseType)
            if let corrupted = filters["corrupted"]["value"].bool {
                Menu {
                    Button("Any corruption") { setCorruption(nil) }
                    Button("Not corrupted") { setCorruption(false) }
                    Button("Corrupted") { setCorruption(true) }
                } label: {
                    Text(filters["corrupted"]["exact"].bool == false && corrupted ? "Any corruption" : corrupted ? "Corrupted" : "Not corrupted")
                }.menuStyle(.borderlessButton).fixedSize()
                    .foregroundStyle(corrupted ? Color(hex: 0xf56565) : PoeTheme.muted).padding(.horizontal, 8)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setCorruption(_ value: Bool?) {
        guard var preset = model.activePreset, let sourceText = model.analysis?.item.rawText else { return }
        var filter = preset.filters["corrupted"]
        filter["exact"] = .bool(value != nil); filter["value"] = .bool(value ?? true)
        preset.filters["corrupted"] = filter
        model.replaceActivePreset(preset, sourceText: sourceText, sourcePresetID: model.presetID)
    }

    private func uniqueChooser(_ analysis: NativeAnalysis) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Which unique item is this?").foregroundStyle(PoeTheme.secondary)
            Text("The item is unidentified. Choose its identity to build the matching search.")
                .font(.system(size: 11)).foregroundStyle(PoeTheme.muted)
            ForEach(analysis.uniqueCandidates ?? []) { candidate in
                Button { model.resolveUnique(candidate.id) } label: {
                    HStack {
                        if let icon = candidate.icon, let url = URL(string: icon) {
                            AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Color.clear }
                                .frame(width: 28, height: 32)
                        }
                        Text(candidate.name).foregroundStyle(rarityColor("Unique"))
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 10))
                    }.padding(8).contentShape(Rectangle())
                }.buttonStyle(.plain).background(PoeTheme.dark)
            }
        }
    }
}

struct ShortcutHint: View {
    @ObservedObject var integration: MacIntegration
    let shortcut: CheckShortcut
    var body: some View {
        HStack(spacing: 6) {
            Text(shortcut.title).font(.system(size: 10, weight: .semibold, design: .monospaced))
            Text(integration.isCapturing ? integration.captureStatus : integration.shortcutStatus)
                .font(.system(size: 10)).lineLimit(2).foregroundStyle(PoeTheme.muted)
        }.help(integration.shortcutStatus)
    }
}

struct CapturePermissionView: View {
    @ObservedObject var integration: MacIntegration
    var body: some View {
        if !integration.accessibilityGranted {
            VStack(alignment: .leading, spacing: 8) {
                Text("Enable Accessibility once to let the shortcut copy the hovered item.").font(.system(size: 12)).foregroundStyle(PoeTheme.secondary)
                Button("Enable One-Step Shortcut…") { integration.requestAccessibilityPermission() }.buttonStyle(PoeButtonStyle(active: true))
            }.padding(10).background(PoeTheme.dark)
        }
    }
}
