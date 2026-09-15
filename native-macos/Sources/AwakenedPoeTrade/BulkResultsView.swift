import SwiftUI
import TradeCore

struct BulkResultsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedOffer: TradeExchangeOffer?
    @State private var showSearchOptions = false

    private var canSearch: Bool { !model.queryJSON.isEmpty && !model.isSearching }
    private var showSeller: Bool { model.sellerDisplay != "none" }
    private var includesOffline: Bool { model.activePreset?.filters["trade"]["offline"].bool ?? false }
    private var currencies: [String] {
        switch model.activePreset?.tradeTag {
        case "chaos": return ["divine"]
        case "divine": return ["chaos"]
        default: return ["chaos", "divine"]
        }
    }
    private var offers: [TradeExchangeOffer] {
        Array((model.exchangePage?.offers ?? []).filter { $0.exchangeCurrency == model.selectedExchangeCurrency }.prefix(20))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            actions
            if let page = model.exchangePage {
                HStack(spacing: 6) {
                    ForEach(currencies, id: \.self) { currency in
                        Button { model.selectExchangeCurrency(currency) } label: {
                            Text(currency.capitalized)
                        }
                        .buttonStyle(PoeButtonStyle(active: model.selectedExchangeCurrency == currency))
                        .disabled(model.isSearching)
                        .accessibilityLabel("\(currency.capitalized) exchange offers")
                        .accessibilityValue(model.selectedExchangeCurrency == currency ? "Selected" : "")
                    }
                    Spacer(minLength: 0)
                    Text("\(offers.count) shown").font(.system(size: 10)).foregroundStyle(PoeTheme.muted)
                }
                if offers.isEmpty, !model.isSearching {
                    Text(page.total == 0 ? "No matching exchange offers." : "No offers returned for this currency.")
                        .foregroundStyle(PoeTheme.secondary).padding(.vertical, 6)
                } else {
                    VStack(spacing: 0) {
                        headings
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            VStack(spacing: 0) {
                                ForEach(Array(offers.enumerated()), id: \.element.id) { index, offer in
                                    offerRow(offer, now: context.date)
                                        .background(index.isMultiple(of: 2) ? PoeTheme.stripe : PoeTheme.background)
                                }
                            }
                        }
                    }
                }
                HStack {
                    Spacer(minLength: 0)
                    Menu {
                        Picker("Seller", selection: $model.sellerDisplay) {
                            Text("Hidden").tag("none")
                            Text("Account name").tag("account")
                            Text("Character name").tag("ign")
                        }
                    } label: { Text("Seller") }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(PoeTheme.muted)
                    .accessibilityLabel("Seller display")
                }.font(.system(size: 10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .popover(item: $selectedOffer, arrowEdge: .trailing) { offer in offerDetails(offer) }
        .sheet(isPresented: $showSearchOptions) { TradeOptionsView(model: model) }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if model.isSearching {
                ProgressView().controlSize(.small).scaleEffect(0.8).frame(width: 16, height: 16)
                    .accessibilityLabel("Searching exchange offers")
                Button("Cancel") { model.cancelSearch() }.buttonStyle(PoeButtonStyle())
                    .accessibilityLabel("Cancel exchange search")
            } else if let page = model.exchangePage {
                Text("Matched \(page.total.formatted())").foregroundStyle(PoeTheme.muted).lineLimit(1)
                    .help("Total returned for this API query across its requested currencies")
                availabilityMenu
            } else {
                Button { model.search() } label: { Text("Search").frame(width: 64) }
                    .buttonStyle(PoeButtonStyle(active: true)).disabled(!canSearch)
                    .accessibilityLabel("Search exchange offers")
            }
            if model.exchangePage == nil {
                Button { showSearchOptions = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 12))
                }.buttonStyle(PoeButtonStyle()).help("Search options")
                    .accessibilityLabel("Search options")
            }
            Spacer(minLength: 0)
            Button { model.openTrade() } label: {
                HStack(spacing: 4) {
                    Text("Trade")
                    Image(systemName: "arrow.up.right.square").font(.system(size: 11))
                }
            }.buttonStyle(PoeButtonStyle()).disabled(model.queryJSON.isEmpty)
                .help("Open this exchange search on the Path of Exile trade site")
                .accessibilityLabel("Open exchange trade site")
            if model.exchangePage != nil {
                Button { model.search() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 12)
                }.buttonStyle(PoeButtonStyle()).disabled(!canSearch)
                    .accessibilityLabel("Refresh exchange offers")
            }
        }.frame(minHeight: 28)
    }

    private var availabilityMenu: some View {
        Menu {
            Button("Online") { setAvailability(false) }
            Button("Any") { setAvailability(true) }
            Divider()
            Button("Search options…") { showSearchOptions = true }
        } label: { Text(includesOffline ? "Any" : "Online") }
            .menuStyle(.borderlessButton).fixedSize().foregroundStyle(PoeTheme.secondary)
            .disabled(!canSearch).accessibilityLabel("Exchange seller availability")
            .accessibilityValue(includesOffline ? "Any" : "Online")
    }

    private func setAvailability(_ offline: Bool) {
        guard includesOffline != offline else { return }
        model.updateTradeFilter(key: "offline", value: .bool(offline))
        model.updateTradeFilter(key: "listed", value: offline ? .string("2months") : .null)
        model.search()
    }

    private var headings: some View {
        HStack(spacing: 0) {
            cell("Price", width: 62, alignment: .leading)
                .help("\(model.selectedExchangeCurrency) per item")
            cell("Pay / bulk", width: 86)
            cell("Stock", width: 43)
            cell("Fulfill", width: 40)
            Text("Listed").padding(.leading, 14)
                .frame(width: showSeller ? 62 : nil, alignment: .leading)
                .frame(maxWidth: showSeller ? nil : .infinity, alignment: .leading)
            if showSeller { Text("Seller").padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading) }
            Color.clear.frame(width: 18)
        }.foregroundStyle(PoeTheme.muted).lineLimit(1).minimumScaleFactor(0.8)
            .frame(height: 23).accessibilityHidden(true)
    }

    private func offerRow(_ offer: TradeExchangeOffer, now: Date) -> some View {
        let age = ListingAge(indexed: offer.indexed, now: now)
        return Button { selectedOffer = offer } label: {
            HStack(spacing: 0) {
                cell(number(offer.unitPrice), width: 62, alignment: .leading)
                cell("\(number(offer.exchangeAmount)) / \(number(offer.itemAmount))", width: 86)
                cell(number(offer.stock), width: 43)
                cell(number(floor(offer.stock / offer.itemAmount)), width: 40)
                    .foregroundStyle(offer.stock < offer.itemAmount ? Color.orange : PoeTheme.text)
                HStack(spacing: 4) {
                    Circle().fill(statusColor(offer)).frame(width: 6, height: 6)
                    Text(age.compact).font(.system(size: 11)).foregroundStyle(PoeTheme.secondary)
                    if !showSeller && isOwnOffer(offer) { Text("You").font(.system(size: 9)).foregroundStyle(PoeTheme.blue) }
                }.padding(.horizontal, 4)
                    .frame(width: showSeller ? 62 : nil, alignment: .leading)
                    .frame(maxWidth: showSeller ? nil : .infinity, alignment: .leading)
                if showSeller {
                    Text(isOwnOffer(offer) ? "You" : sellerName(offer))
                        .font(.system(size: 11)).foregroundStyle(isOwnOffer(offer) ? PoeTheme.blue : PoeTheme.secondary)
                        .padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
                }
                Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(PoeTheme.muted).frame(width: 18)
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain).font(PoeTheme.numbers).lineLimit(1).frame(height: 25)
            .help("\(offer.account) · \(statusName(offer))\n\(number(offer.exchangeAmount)) \(offer.exchangeCurrency) for \(number(offer.itemAmount)) items\n\(age.description)")
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default) { selectedOffer = offer }
            .accessibilityIdentifier("trade.exchange.\(offer.id)")
            .accessibilityLabel("Exchange offer from \(offer.account)")
            .accessibilityValue("\(number(offer.unitPrice)) \(offer.exchangeCurrency) per item; pay \(number(offer.exchangeAmount)) for \(number(offer.itemAmount)); stock \(number(offer.stock)); fulfills \(number(floor(offer.stock / offer.itemAmount))) trades; \(statusName(offer)); \(age.description)")
            .accessibilityHint("Show seller details")
    }

    private func offerDetails(_ offer: TradeExchangeOffer) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Exchange offer")
                Spacer(minLength: 0)
                Button { selectedOffer = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close exchange details")
            }
            Text("\(number(offer.exchangeAmount)) \(offer.exchangeCurrency) for \(number(offer.itemAmount)) \(offer.itemCurrency ?? "items")")
                .foregroundStyle(PoeTheme.blue)
            Text("Account: \(offer.account)").textSelection(.enabled)
            if let character = offer.lastCharacterName { Text("Character: \(character)").textSelection(.enabled) }
            Text("\(statusName(offer)) · Stock \(number(offer.stock))")
            if offer.stock < offer.itemAmount {
                Text("Stock is below the listed bulk amount.").foregroundStyle(PoeTheme.secondary)
            }
            if let indexed = offer.indexed { Text("Listed: \(indexed)").foregroundStyle(PoeTheme.secondary) }
            if let whisper = offer.whisper, !whisper.isEmpty {
                Text(whisper).font(.system(size: 11)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.copyWhisper(offer) } label: { Label("Copy whisper", systemImage: "doc.on.doc") }
                    .buttonStyle(PoeButtonStyle(active: true))
                    .help("Copy a whisper for the listed bulk amount: \(number(offer.itemAmount)) items")
            } else {
                Text("Open Trade to choose a quantity and prepare a whisper.")
                    .font(.system(size: 11)).foregroundStyle(PoeTheme.secondary)
                Button { model.openTrade() } label: { Label("Open exchange on Trade", systemImage: "arrow.up.right.square") }
                    .buttonStyle(PoeButtonStyle(active: true))
            }
        }.font(PoeTheme.font).foregroundStyle(PoeTheme.text).padding(14)
            .frame(width: 330).background(PoeTheme.background)
    }

    private func cell(_ text: String, width: CGFloat, alignment: Alignment = .trailing) -> some View {
        Text(text).padding(.horizontal, 4).frame(width: width, alignment: alignment).minimumScaleFactor(0.7)
    }
    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...4)))
    }
    private func isOwnOffer(_ offer: TradeExchangeOffer) -> Bool {
        !model.accountName.isEmpty && offer.account.caseInsensitiveCompare(model.accountName) == .orderedSame
    }
    private func sellerName(_ offer: TradeExchangeOffer) -> String {
        model.sellerDisplay == "ign" ? (offer.lastCharacterName ?? offer.account) : offer.account
    }
    private func statusName(_ offer: TradeExchangeOffer) -> String {
        offer.accountStatus == "afk" ? "Away" : offer.accountStatus == "online" ? "Online" : "Offline"
    }
    private func statusColor(_ offer: TradeExchangeOffer) -> Color {
        offer.accountStatus == "afk" ? Color(hex: 0xed8936) : offer.accountStatus == "online" ? Color(hex: 0x48bb78) : Color(hex: 0xe53e3e)
    }
}
