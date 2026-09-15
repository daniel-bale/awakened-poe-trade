import SwiftUI
import TradeCore

struct TradeResultsView: View {
    @ObservedObject var model: AppModel
    @State private var selectedListing: TradeListing?
    @State private var showSearchOptions = false

    private var showSeller: Bool { model.sellerDisplay != "none" }

    private var filters: JSONValue { model.activePreset?.filters ?? .null }
    private var showsStock: Bool { filters["stackSize"] != .null }
    private var showsItemLevel: Bool { filters["itemLevel"] != .null }
    private var isGem: Bool { model.analysis?.item.category == "Gem" }
    private var showsQuality: Bool { filters["quality"] != .null || isGem }
    private var includesOffline: Bool { filters["trade"]["offline"].bool ?? false }
    private var canSearch: Bool { !model.queryJSON.isEmpty && !model.isSearching && !model.isLoadingMore }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            actions
            if let page = model.searchPage {
                if page.listings.isEmpty {
                    Text(page.total == 0 ? "No matching listings." : "These listings are no longer available.")
                        .foregroundStyle(PoeTheme.secondary).padding(.vertical, 6)
                } else {
                    VStack(spacing: 0) {
                        headings
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            VStack(spacing: 0) {
                                ForEach(Array(page.groupedListings(collapseMerchant: filters["trade"]["collapseMerchant"].bool ?? false).enumerated()), id: \.element.id) { index, group in
                                    listingRow(group, now: context.date)
                                        .background(index.isMultiple(of: 2) ? PoeTheme.stripe : PoeTheme.background)
                                }
                            }
                        }
                    }
                }
                HStack(spacing: 8) {
                    if model.isLoadingMore {
                        ProgressView().controlSize(.small).frame(width: 14, height: 14)
                        Button("Cancel") { model.cancelLoadMore() }.buttonStyle(.plain)
                            .accessibilityLabel("Cancel loading more listings")
                    } else if page.hasMore {
                        Button("Load more") { model.loadMoreListings() }.buttonStyle(.plain)
                            .foregroundStyle(PoeTheme.blue).disabled(!canSearch)
                    }
                    Text("\(page.listings.count) loaded").foregroundStyle(PoeTheme.muted)
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
                }.font(.system(size: 10)).frame(minHeight: 18)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .popover(item: $selectedListing, arrowEdge: .trailing) { listing in listingDetails(listing) }
        .sheet(isPresented: $showSearchOptions) { TradeOptionsView(model: model) }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            if model.isSearching {
                ProgressView().controlSize(.small).scaleEffect(0.8)
                    .frame(width: 16, height: 16).accessibilityLabel("Searching trade listings")
                Button("Cancel") { model.cancelSearch() }
                    .buttonStyle(PoeButtonStyle()).accessibilityLabel("Cancel search")
            } else if let page = model.searchPage {
                Text("Matched \(page.total.formatted())")
                    .foregroundStyle(PoeTheme.muted).lineLimit(1)
                    .accessibilityLabel("\(page.total) matching listings")
                availabilityMenu
            } else {
                Button { model.search() } label: { Text("Search").frame(width: 64) }
                    .buttonStyle(PoeButtonStyle(active: true))
                    .disabled(!canSearch).opacity(canSearch ? 1 : 0.45)
                    .accessibilityLabel("Search trade listings")
            }
            if model.searchPage == nil {
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
            }
            .buttonStyle(PoeButtonStyle()).disabled(model.queryJSON.isEmpty).opacity(model.queryJSON.isEmpty ? 0.45 : 1)
            .help("Open this search on the Path of Exile trade site")
            .accessibilityLabel("Open trade site")
            if model.searchPage != nil {
                Button { model.search() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 12)
                }
                .buttonStyle(PoeButtonStyle()).disabled(!canSearch)
                .help("Refresh listings").accessibilityLabel("Refresh listings")
            }
        }
        .frame(minHeight: 28)
    }

    private var availabilityMenu: some View {
        Menu {
            Button { setAvailability(includeOffline: false) } label: {
                if !includesOffline { Label("Available", systemImage: "checkmark") }
                else { Text("Available") }
            }
            Button { setAvailability(includeOffline: true) } label: {
                if includesOffline { Label("Any", systemImage: "checkmark") }
                else { Text("Any") }
            }
            Divider()
            Button("Search options…") { showSearchOptions = true }
        } label: {
            Text(includesOffline ? "Any" : "Available")
        }
        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(PoeTheme.secondary)
        .disabled(!canSearch)
        .help("Choose available sellers or include offline sellers")
        .accessibilityLabel("Seller availability")
        .accessibilityValue(includesOffline ? "Any" : "Available")
    }

    private func setAvailability(includeOffline: Bool) {
        guard includesOffline != includeOffline else { return }
        model.updateTradeFilter(key: "offline", value: .bool(includeOffline))
        model.updateTradeFilter(key: "listed", value: includeOffline ? .string("2months") : .null)
        model.search()
    }

    private var headings: some View {
        HStack(spacing: 0) {
            heading("Price", width: 106, alignment: .leading)
            if showsStock { heading("Stock", width: 40) }
            if showsItemLevel { heading("iLvl", width: 32).help("Item level") }
            if isGem { heading("Level", width: 35).help("Gem level") }
            if showsQuality { heading("Quality", width: 44) }
            Text("Listed").padding(.leading, 14)
                .frame(width: showSeller ? 64 : nil, alignment: .leading)
                .frame(maxWidth: showSeller ? nil : .infinity, alignment: .leading)
            if showSeller {
                Text("Seller").padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
            }
            Color.clear.frame(width: 18)
        }
        .foregroundStyle(PoeTheme.muted).lineLimit(1).minimumScaleFactor(0.8)
        .frame(height: 23)
        .accessibilityHidden(true)
    }

    private func heading(_ title: String, width: CGFloat, alignment: Alignment = .trailing) -> some View {
        Text(title).padding(.horizontal, 4).frame(width: width, alignment: alignment)
    }

    private func listingRow(_ group: TradeListingGroup, now: Date) -> some View {
        let listing = group.listing
        let age = ListingAge(indexed: listing.indexed, now: now)
        return Button { selectedListing = listing } label: {
          HStack(spacing: 0) {
            HStack(spacing: 3) {
                Text(price(listing))
                if group.listedTimes > 2 { Text("×\(group.listedTimes)").font(.system(size: 10)).foregroundStyle(PoeTheme.secondary) }
                else if listing.fee == nil, listing.hasNote == false {
                    Image(systemName: "archivebox").font(.system(size: 9)).foregroundStyle(PoeTheme.muted)
                }
            }.padding(.horizontal, 4).frame(width: 106, alignment: .leading)
                .foregroundStyle(listing.priceAmount == nil ? PoeTheme.secondary : PoeTheme.text)
            if showsStock { numericCell(group.stock.map(String.init) ?? "—", width: 40) }
            if showsItemLevel { numericCell(listing.itemLevel.map(String.init) ?? "—", width: 32) }
            if isGem { numericCell(listing.gemLevel ?? "—", width: 35) }
            if showsQuality { numericCell(listing.quality ?? "—", width: 44).foregroundStyle(PoeTheme.blue) }
            HStack(spacing: 4) {
                Circle().fill(statusColor(listing))
                    .frame(width: 6, height: 6)
                Text(age.compact).font(.system(size: 11)).foregroundStyle(PoeTheme.secondary)
                if !showSeller && isOwnListing(listing) { Text("You").font(.system(size: 9)).foregroundStyle(PoeTheme.blue) }
            }
            .padding(.leading, 4).padding(.trailing, 4)
            .frame(width: showSeller ? 64 : nil, alignment: .leading)
            .frame(maxWidth: showSeller ? nil : .infinity, alignment: .leading)
            if showSeller {
                Text(isOwnListing(listing) ? "You" : sellerName(listing))
                    .font(.system(size: 11)).foregroundStyle(isOwnListing(listing) ? PoeTheme.blue : PoeTheme.secondary)
                    .padding(.horizontal, 4).frame(maxWidth: .infinity, alignment: .leading)
            }
            Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(PoeTheme.muted).frame(width: 18)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .lineLimit(1).frame(height: 25)
        .help("\(listing.itemName)\n\(listing.account) · \(statusName(listing))\n\(price(listing))\n\(listing.indexed.map { "Listed: \($0)" } ?? "Listing time unavailable")")
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default) { selectedListing = listing }
        .accessibilityIdentifier("trade.listing.\(listing.id)")
        .accessibilityLabel(listing.itemName)
        .accessibilityValue(accessibleListing(listing, age: age))
        .accessibilityHint("Show seller details and copy whisper")
    }

    private func listingDetails(_ listing: TradeListing) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top) {
                Text(listing.itemName).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { selectedListing = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Close listing details")
            }
            Text(price(listing)).foregroundStyle(PoeTheme.blue)
            detail("Account", value: listing.account)
            if let character = listing.lastCharacterName { detail("Character", value: character) }
            detail("Status", value: statusName(listing))
            if let indexed = listing.indexed { detail("Listed", value: indexed) }
            if let stash = listing.stashName { detail("Stash", value: stash) }
            if let fee = listing.fee { detail("Merchant fee", value: fee.formatted()) }
            if listing.fee == nil, listing.hasNote == false {
                Text("Price comes from the stash tab; the item has no individual price note.")
                    .font(.system(size: 11)).foregroundStyle(PoeTheme.secondary)
            }
            if let whisper = listing.whisper, !whisper.isEmpty {
                Text(whisper).font(.system(size: 11)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.copyWhisper(listing) } label: { Label("Copy whisper", systemImage: "doc.on.doc") }
                    .buttonStyle(PoeButtonStyle(active: true))
            } else {
                Text("No whisper text is available for this listing.")
                    .font(.system(size: 11)).foregroundStyle(PoeTheme.secondary)
            }
        }
        .font(PoeTheme.font).foregroundStyle(PoeTheme.text).padding(14)
        .frame(width: 330).background(PoeTheme.background)
    }

    private func detail(_ title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(PoeTheme.muted).frame(width: 78, alignment: .leading)
            Text(value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }.font(.system(size: 11))
    }

    private func sellerName(_ listing: TradeListing) -> String {
        model.sellerDisplay == "ign" ? (listing.lastCharacterName ?? listing.account) : listing.account
    }

    private func isOwnListing(_ listing: TradeListing) -> Bool {
        !model.accountName.isEmpty && listing.account.caseInsensitiveCompare(model.accountName) == .orderedSame
    }

    private func statusName(_ listing: TradeListing) -> String {
        listing.accountStatus == "afk" ? "Away" : listing.online ? "Online" : "Offline"
    }

    private func statusColor(_ listing: TradeListing) -> Color {
        listing.accountStatus == "afk" ? Color(hex: 0xed8936) : listing.online ? Color(hex: 0x48bb78) : Color(hex: 0xe53e3e)
    }

    private func numericCell(_ value: String, width: CGFloat) -> some View {
        Text(value).font(PoeTheme.numbers).padding(.horizontal, 4)
            .frame(width: width, alignment: .trailing).minimumScaleFactor(0.75)
    }

    private func price(_ listing: TradeListing) -> String {
        guard let amount = listing.priceAmount else { return "No price" }
        let number = amount.formatted(.number.precision(.significantDigits(1...15)))
        guard let currency = listing.priceCurrency, !currency.isEmpty else { return number }
        return "\(number) \(currency)"
    }

    private func accessibleListing(_ listing: TradeListing, age: ListingAge) -> String {
        var values = ["Price: \(price(listing))", statusName(listing), age.description]
        if showsStock, let stock = listing.stackSize { values.append("Stock: \(stock)") }
        if showsItemLevel, let level = listing.itemLevel { values.append("Item level: \(level)") }
        if isGem, let level = listing.gemLevel { values.append("Gem level: \(level)") }
        if showsQuality, let quality = listing.quality { values.append("Quality: \(quality)") }
        values.append("Seller: \(listing.account)")
        return values.joined(separator: ", ")
    }
}

struct ListingAge {
    let compact: String
    let description: String

    init(indexed: String?, now: Date) {
        guard let indexed, let date = Self.fractional.date(from: indexed) ?? Self.standard.date(from: indexed) else {
            compact = "—"
            description = "Listing time unavailable"
            return
        }
        let elapsed = now.timeIntervalSince(date)
        let seconds = abs(elapsed)
        let value: String
        if seconds < 60 { value = "<1m" }
        else if seconds < 3_600 { value = "\(Int(seconds / 60))m" }
        else if seconds < 86_400 { value = "\(Int(seconds / 3_600))h" }
        else { value = "\(Int(seconds / 86_400))d" }
        compact = elapsed < 0 ? "in \(value)" : value
        description = elapsed < 0 ? "Listing timestamp is \(value) in the future" : "Listed \(value) ago"
    }

    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let standard = ISO8601DateFormatter()
}
