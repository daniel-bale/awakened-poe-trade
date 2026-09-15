import SwiftUI
import TradeCore

struct TradeOptionsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var offline = false
    @State private var listed = ""
    @State private var currency = ""
    @State private var merchantOnly = true
    @State private var onlineInLeague = false
    @State private var collapseMerchant = false
    @State private var sourceText = ""
    @State private var sourcePresetID = ""

    init(model: AppModel) {
        self.model = model
        let trade = model.activePreset?.filters["trade"] ?? .null
        _listed = State(initialValue: trade["listed"].string ?? "")
        _offline = State(initialValue: trade["offline"].bool ?? false)
        _currency = State(initialValue: trade["currency"].string ?? "")
        _merchantOnly = State(initialValue: trade["merchantOnly"].bool ?? true)
        _onlineInLeague = State(initialValue: trade["onlineInLeague"].bool ?? false)
        _collapseMerchant = State(initialValue: trade["collapseMerchant"].bool ?? false)
        _sourceText = State(initialValue: model.analysis?.item.rawText ?? "")
        _sourcePresetID = State(initialValue: model.presetID)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Search options").font(.headline)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Apply & Search") { apply() }.keyboardShortcut(.defaultAction)
                    .disabled(model.activePreset == nil)
            }.padding(16)
            Form {
                Section("Availability") {
                    Toggle("Include offline sellers", isOn: $offline)
                        .onChange(of: offline) { _, value in
                            if model.queryKind == "trade" { listed = value ? "2months" : "" }
                        }
                    if model.queryKind == "bulk" {
                        Toggle("Online in this league", isOn: $onlineInLeague).disabled(offline)
                    } else {
                        Toggle("Merchant listings only", isOn: $merchantOnly).disabled(offline)
                        Picker("Listed", selection: $listed) {
                            Text("Any time").tag("")
                            Text("Last 24 hours").tag("1day")
                            Text("Last 3 days").tag("3days")
                            Text("Last week").tag("1week")
                            Text("Last 2 weeks").tag("2weeks")
                            Text("Last month").tag("1month")
                            Text("Last 2 months").tag("2months")
                        }
                    }
                }
                if model.queryKind == "trade" {
                    Section("Price") {
                        CurrencyPicker(selection: $currency)
                        Toggle("Group identical merchant listings", isOn: $collapseMerchant)
                    }
                }
                Section {
                    Text("League: \(model.effectiveLeague)")
                    Text("Use the league selector at the top of the price check to change league.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped)
        }.frame(width: 460, height: model.queryKind == "bulk" ? 330 : 470)
    }

    private func apply() {
        guard model.analysis?.item.rawText == sourceText, model.presetID == sourcePresetID else { dismiss(); return }
        model.updateTradeFilters([
            "offline": .bool(offline), "listed": listed.isEmpty ? .null : .string(listed),
            "currency": currency.isEmpty ? .null : .string(currency), "merchantOnly": .bool(merchantOnly),
            "onlineInLeague": .bool(onlineInLeague), "collapseMerchant": .bool(collapseMerchant)
        ])
        dismiss()
        model.search()
    }
}

struct CurrencyPicker: View {
    @Binding var selection: String
    var body: some View {
        Picker("Price currency", selection: $selection) {
            Text("Any currency").tag("")
            Text("Chaos Orb").tag("chaos")
            Text("Divine Orb").tag("divine")
            Text("Chaos or Divine").tag("chaos_divine")
        }
    }
}

struct TradeSessionControls: View {
    @ObservedObject var model: AppModel
    @ObservedObject var session: TradeBrowserSession
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(session.status).font(.system(size: 12)).foregroundStyle(.secondary)
            if !compact {
                Text("Private leagues require a Path of Exile account with access. Sign in in this app’s trade browser; a Safari sign-in uses a separate session.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Open Trade Session…") { model.openTradeSession() }
                if !model.queryJSON.isEmpty {
                    Button("Retry Search") { model.retryWithTradeSession() }
                        .disabled(model.isSearching || !session.isReadyForRequests)
                }
            }.controlSize(.small)
        }
    }
}
