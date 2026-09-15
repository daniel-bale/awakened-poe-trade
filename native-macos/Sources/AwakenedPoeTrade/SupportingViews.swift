import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var confirmClear = false
    var filtered: [RecentItem] { model.history.filter { searchText.isEmpty || ($0.name + " " + $0.baseType).localizedCaseInsensitiveContains(searchText) } }

    var body: some View {
        VStack(spacing: 12) {
            HStack { Text("Recent items").font(.headline); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            TextField("Find a recent item", text: $searchText).textFieldStyle(.roundedBorder)
            if filtered.isEmpty {
                ContentUnavailableView("No recent items", systemImage: "clock", description: Text("Your last 50 item checks appear here."))
            } else {
                List(filtered) { item in
                    Button { model.openRecent(item); dismiss() } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) { Text(item.name).foregroundStyle(rarityColor(item.rarity)); Text(item.baseType).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(item.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 3).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            HStack { Text("Saved on this Mac").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Clear History", role: .destructive) { confirmClear = true }.disabled(model.history.isEmpty) }
        }.padding(16).frame(width: 440, height: 500)
            .confirmationDialog("Clear all recent item checks?", isPresented: $confirmClear) {
                Button("Clear History", role: .destructive) { model.clearHistory() }
            }
    }
}

struct GuideView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("Price check").font(.headline); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            Text("Hover an item in Path of Exile and press \(model.shortcut.title).")
            Text("The app copies the hovered item with Ctrl+C, reads the fresh clipboard, and opens this panel. Smart search follows the Windows rules; other items open their filters for review.")
            Text("Enable Accessibility in Settings once for this combined shortcut. It is registered only while Path of Exile is focused, so your other apps keep their usual key bindings.")
            Text("Choose your league at the top. Click a modifier or edit its min/max bounds, then Search. Trade opens the same search in your browser. Esc closes the panel and returns to the game.")
            Text("For private leagues, open Settings → Trade account and sign in using the built-in browser. Return to the price check and retry after sign-in or verification.")
            Text("Alternatives: Option+D or Command+D, selectable in Settings. The manual Check Clipboard command remains available if you prefer copying with Ctrl+C yourself.")
            Spacer()
            Text("English and Traditional Chinese item text · Path of Exile 1").font(.caption).foregroundStyle(.secondary)
        }.font(.callout).padding(20).frame(width: 440, height: 530)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showLeaguePicker = false
    var body: some View {
        VStack(spacing: 0) {
            HStack { Text("Settings").font(.headline); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }.padding(16)
            Form {
                Section("One-step price check") {
                    Picker("Shortcut", selection: $model.shortcut) {
                        Text("Ctrl+D (Windows default)").tag(CheckShortcut.ctrlD)
                        Text("Option+D").tag(CheckShortcut.optionD)
                        Text("Command+D").tag(CheckShortcut.commandD)
                    }
                    Text("Hover an item, then press the shortcut. Active only while Path of Exile is focused.").font(.caption).foregroundStyle(.secondary)
                    ShortcutPermissionSettings(integration: model.integration)
                    Toggle("Restore clipboard after checking", isOn: $model.restoreClipboard)
                    Toggle("Smart initial search", isOn: $model.smartSearch)
                }
                Section("Game") {
                    Picker("Item language", selection: $model.language) { Text("English").tag("en"); Text("繁體中文").tag("cmn-Hant") }
                    HStack {
                        Text("League")
                        Spacer()
                        Button(model.effectiveLeague.isEmpty ? "Choose league…" : model.effectiveLeague + "…") { showLeaguePicker = true }
                            .lineLimit(2).accessibilityLabel("Choose league: " + model.effectiveLeague)
                    }
                    Text("Choose a public league or enter a private league name.").font(.caption).foregroundStyle(.secondary)
                }
                Section("History") {
                    Toggle("Save recent item checks", isOn: $model.rememberHistory)
                    Text("Stores up to 50 copied items on this Mac.").font(.caption).foregroundStyle(.secondary)
                }
                Section("Search defaults") {
                    Toggle("Merchant listings only", isOn: $model.merchantOnly)
                    CurrencyPicker(selection: $model.defaultCurrency)
                    Toggle("Use the copied stack size", isOn: $model.activateStockFilter)
                    HStack {
                        Text("Modifier range")
                        Slider(value: $model.searchStatRange, in: 0...50, step: 1)
                        Text("±\(Int(model.searchStatRange))%").monospacedDigit().frame(width: 48)
                    }
                    Picker("Group listings", selection: $model.collapseListings) {
                        Text("One per account from trade API").tag("api")
                        Text("Group matching listings in this app").tag("app")
                    }
                    HStack {
                        Text("Extra API delay")
                        Slider(value: $model.extraRequestDelay, in: 0...10, step: 0.5)
                        Text("\(model.extraRequestDelay, specifier: "%.1f") s").monospacedDigit().frame(width: 48)
                    }
                    Text("Defaults apply to the next copied item. Current search options are beside the Search button.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Trade account") {
                    TextField("Account name", text: $model.accountName)
                    Text("Used to mark your own listings. This field does not sign you in.").font(.caption).foregroundStyle(.secondary)
                    Picker("Seller names", selection: $model.sellerDisplay) {
                        Text("Hidden").tag("none")
                        Text("Account").tag("account")
                        Text("Character").tag("ign")
                    }
                    Toggle("Use built-in session for API requests", isOn: $model.useBrowserSession)
                    Toggle("Open trade links in built-in browser", isOn: $model.builtInBrowser)
                    TradeSessionControls(model: model, session: model.tradeSession)
                }
                Section("Price prediction") {
                    PredictionPreference()
                }
            }.formStyle(.grouped)
        }.frame(width: 490, height: 700)
            .sheet(isPresented: $showLeaguePicker) { LeagueSelectionView(model: model) }
    }
}

private struct PredictionPreference: View {
    @AppStorage("requestPricePrediction") private var enabled = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Request rare-item estimates from poeprices.info", isOn: $enabled)
            Text("Sends eligible English item descriptions to the price-prediction service. Disabled by default, as in Windows.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct ShortcutPermissionSettings: View {
    @ObservedObject var integration: MacIntegration
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(integration.accessibilityGranted ? "Accessibility enabled" : "Accessibility permission required", systemImage: integration.accessibilityGranted ? "checkmark.circle" : "hand.raised")
                .foregroundStyle(integration.accessibilityGranted ? .green : .orange).font(.caption)
            if !integration.accessibilityGranted {
                Text("Allows this app to send Ctrl+C to the game when you press the shortcut.").font(.caption).foregroundStyle(.secondary)
                Button("Enable Accessibility…") { integration.requestAccessibilityPermission() }
            }
            HStack {
                Button("Open Accessibility Settings") { integration.openAccessibilitySettings() }
                Button("Check Again") { integration.refreshAccessibilityPermission() }
            }.font(.caption)
            Text(integration.shortcutStatus).font(.caption).foregroundStyle(.secondary)
        }.onAppear { integration.refreshAccessibilityPermission() }
    }
}
