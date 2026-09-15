import SwiftUI
import TradeCore

@MainActor final class MarketDataViewModel: ObservableObject {
    @Published var snapshot: MarketSnapshot?
    @Published var prediction: PricePrediction?
    @Published var loading = false
    @Published var marketError: String?
    @Published var predictionError: String?
    @Published var feedbackError: String?
    @Published var feedbackSent = false
    @Published var sendingFeedback = false
    private let client: MarketDataClient
    private var generation = UUID()

    init(client: MarketDataClient = .shared) { self.client = client }

    func load(itemText: String, league: String, allowed: Bool, predict: Bool) async {
        let token = UUID(); generation = token
        snapshot = nil; prediction = nil; marketError = nil; predictionError = nil
        feedbackError = nil; feedbackSent = false; loading = allowed
        guard allowed else { return }
        defer { if generation == token { loading = false } }
        do {
            let result = try await client.snapshot(league: league)
            guard !Task.isCancelled, generation == token else { return }
            snapshot = result
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            marketError = error.localizedDescription
        }
        guard predict, !Task.isCancelled, generation == token else { return }
        do {
            let result = try await client.predict(text: itemText, league: league, market: snapshot)
            guard !Task.isCancelled, generation == token else { return }
            prediction = result
        } catch {
            guard !Task.isCancelled, generation == token else { return }
            predictionError = error.localizedDescription
        }
    }

    func sendFeedback(_ option: PredictionFeedback, text: String, itemText: String, league: String) async {
        guard let prediction, !sendingFeedback, !feedbackSent else { return }
        let token = generation
        sendingFeedback = true; feedbackError = nil
        defer { sendingFeedback = false }
        do {
            try await client.sendFeedback(option, text: text, itemText: itemText, league: league, prediction: prediction)
            guard generation == token else { return }
            feedbackSent = true
        } catch { if generation == token { feedbackError = error.localizedDescription } }
    }
}

/// A native rendering of the Windows market/valuation panel, independent of trade credentials.
struct MarketDataView: View {
    let item: NativeItem
    let metadata: MarketItemMetadata?
    let league: String
    let language: String
    let isPublicLeague: Bool
    let presetID: String
    var stackCount: Double? = nil
    var exchangeCurrency: String? = nil
    @StateObject private var model = MarketDataViewModel()
    @AppStorage("requestPricePrediction") private var requestPrediction = false
    @State private var showContributions = false
    @State private var showRelated = false
    @State private var showFeedback = false
    @State private var feedbackOption: PredictionFeedback = .fair
    @State private var feedbackText = ""

    private var supportsMarket: Bool { isPublicLeague && !MarketDataClient.isPrivateLeague(league) }
    private var predictionEligible: Bool {
        metadata?.predictionEligible == true && language == "en" && supportsMarket && presetID != "filters.preset_base_item"
    }
    private var predicts: Bool { predictionEligible && requestPrediction }
    private var quote: MarketQuote? { model.snapshot?.quote(metadata?.query) }
    private var isBaseItemPrice: Bool {
        ["Normal", "Magic", "Rare"].contains(item.rarity) && [
            "Helmet", "Body Armour", "Gloves", "Boots", "Shield", "Amulet", "Belt", "Ring", "Quiver",
            "Claw", "Bow", "Sceptre", "Wand", "Fishing Rod", "Staff", "Warstaff", "Dagger", "Rune Dagger",
            "One-Handed Axe", "Two-Handed Axe", "One-Handed Mace", "Two-Handed Mace", "One-Handed Sword", "Two-Handed Sword"
        ].contains(item.category ?? "")
    }
    private var requestID: String { item.rawText + "\u{0}" + league + "\u{0}" + String(supportsMarket) + "\u{0}" + String(predicts) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(predicts ? "Getting market price and prediction…" : "Getting market price from poe.ninja…")
                        .foregroundStyle(PoeTheme.muted)
                }.font(.system(size: 11)).padding(.vertical, 4)
            }
            if predicts, let prediction = model.prediction {
                predictionPanel(prediction)
            } else if !predicts, let quote, let snapshot = model.snapshot {
                HStack(spacing: 12) {
                    Link(destination: quote.url) {
                        VStack(alignment: .leading, spacing: 2) {
                            if isBaseItemPrice { Text("Base item").font(.system(size: 11)).foregroundStyle(PoeTheme.secondary) }
                            Text(snapshot.price(quote.chaos, forceChaos: metadata?.query?.name == "Divine Orb").formatted(fraction: metadata?.stackSize != nil))
                                .font(.custom("Fontin-SmallCaps", size: 18)).foregroundStyle(PoeTheme.text)
                            Text("poe.ninja · \(league)").font(.system(size: 10)).foregroundStyle(PoeTheme.muted)
                        }
                    }.buttonStyle(.plain).help("Open this item's market history on poe.ninja")
                    Spacer(minLength: 0)
                    if let variation = quote.trendVariation {
                        Link(destination: quote.url) {
                            HStack(spacing: 6) {
                                VStack(spacing: 2) {
                                    Text("±\(Int(variation.rounded()))%")
                                    Text("7 days").font(.system(size: 10)).foregroundStyle(PoeTheme.muted)
                                }
                                MarketSparkline(values: quote.graph).frame(width: 58, height: 30)
                            }
                        }.buttonStyle(.plain).accessibilityLabel("Seven-day market trend, variation \(Int(variation.rounded())) percent")
                    }
                }.padding(.vertical, 4)
            }
            if let error = predicts ? model.predictionError : model.marketError {
                HStack(alignment: .top, spacing: 6) {
                    Text(error).foregroundStyle(PoeTheme.muted)
                    Spacer(minLength: 0)
                    Button("Retry") { Task { await refresh() } }.buttonStyle(PoeButtonStyle())
                }.font(.system(size: 11))
            }
            if let snapshot = model.snapshot, let rate = snapshot.divineChaos {
                HStack {
                    Menu {
                        Text("1 Divine Orb = \(MarketPrice.rounded(rate)) chaos")
                        ForEach(1...9, id: \.self) { numerator in
                            Text("\(Double(numerator) / 10, specifier: "%.1f") div → \(Int((rate * Double(numerator) / 10).rounded())) chaos")
                        }
                    } label: { Text("1 div ≈ \(MarketPrice.rounded(rate)) chaos") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Divine to Chaos conversion table")
                    Spacer(minLength: 0)
                    if quote == nil || predicts {
                        Link("poe.ninja", destination: URL(string: "https://poe.ninja/poe1/economy")!)
                            .font(.system(size: 10))
                    }
                }.foregroundStyle(PoeTheme.muted).font(.system(size: 11))
            }
            if let currency = exchangeCurrency, let ratio = model.snapshot?.marketRatio(query: metadata?.query, exchangeCurrency: currency) {
                HStack {
                    Text("Market ratio")
                    Spacer(minLength: 4)
                    Text("\(MarketPrice.rounded(ratio.exchangeAmount)) \(ratio.currency) / \(MarketPrice.rounded(ratio.itemAmount)) items")
                }.font(.system(size: 11)).foregroundStyle(PoeTheme.secondary).padding(6)
                    .background(PoeTheme.stripe)
                    .help("poe.ninja reference price: \(ratio.unitPrice.formatted(.number.precision(.significantDigits(1...6)))) \(ratio.currency) per item. This is not a seller listing.")
            }
            if let quote, let snapshot = model.snapshot, let metadata, metadata.stackSize != nil {
                HStack(spacing: 12) {
                    let count = stackCount ?? Double(metadata.stackSize ?? 1)
                    Text("You have ×\(MarketPrice.rounded(count)) → \(snapshot.price(quote.chaos * count, forceChaos: metadata.query?.name == "Divine Orb").display)")
                    if let max = metadata.stackMax {
                        Text("Stack ×\(max) → \(snapshot.price(quote.chaos * Double(max), forceChaos: metadata.query?.name == "Divine Orb").display)")
                    }
                }.font(.system(size: 11)).foregroundStyle(PoeTheme.secondary)
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(RoundedRectangle(cornerRadius: 2).stroke(PoeTheme.border, style: StrokeStyle(lineWidth: 1, dash: [3])))
            }
            if let dust = metadata?.dustEquivalent, dust > 0 {
                Text("Disenchanting → \(dust.formatted(.number.precision(.fractionLength(0)))) Thaumaturgic Dust")
                    .font(.system(size: 11)).foregroundStyle(PoeTheme.secondary)
            }
            if let metadata, !metadata.related.isEmpty, let snapshot = model.snapshot {
                DisclosureGroup("Related items", isExpanded: $showRelated) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(metadata.related.enumerated()), id: \.offset) { _, related in
                            if let quote = snapshot.quote(related.query) {
                                Link(destination: quote.url) {
                                    HStack {
                                        Text(related.name).lineLimit(2)
                                        Spacer(minLength: 4)
                                        Text(snapshot.price(quote.chaos).formatted(fraction: true)).fixedSize()
                                    }.padding(4).background(related.highlighted ? PoeTheme.stripe : .clear)
                                }.buttonStyle(.plain)
                            } else {
                                HStack { Text(related.name); Spacer(); Text("No market price").foregroundStyle(PoeTheme.muted) }
                            }
                        }
                    }.font(.system(size: 11)).padding(.top, 4)
                }.font(.system(size: 11)).foregroundStyle(PoeTheme.secondary)
            }
            if predictionEligible {
                Toggle("Price prediction · poeprices.info", isOn: $requestPrediction)
                    .toggleStyle(PoeCheckboxStyle()).font(.system(size: 11)).foregroundStyle(PoeTheme.muted)
                    .help("Sends this item's text to poeprices.info to estimate its value. Disabled by default.")
            }
        }
        .task(id: requestID) { await refresh() }
        .sheet(isPresented: $showFeedback) { feedbackSheet }
    }

    private func refresh() async {
        await model.load(itemText: item.rawText, league: league, allowed: supportsMarket, predict: predicts)
    }

    private func predictionPanel(_ prediction: PricePrediction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("≈ " + prediction.price.display).font(.custom("Fontin-SmallCaps", size: 18))
                    Link("Prediction by poeprices.info", destination: prediction.providerURL)
                        .font(.system(size: 10)).foregroundStyle(PoeTheme.muted)
                }
                Spacer()
                VStack(spacing: 2) {
                    Text("\(Int(prediction.confidence))%")
                        .foregroundStyle(prediction.confidence < 78 ? .orange : PoeTheme.text)
                    Text("Confidence").font(.system(size: 10)).foregroundStyle(PoeTheme.muted)
                }
            }
            DisclosureGroup("Contribution to predicted price", isExpanded: $showContributions) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(prediction.contributions.enumerated()), id: \.offset) { _, contribution in
                        HStack(alignment: .top, spacing: 8) {
                            Text("\(Int(contribution.percent))%").frame(width: 40, alignment: .trailing)
                                .foregroundStyle(PoeTheme.muted)
                            Text(contribution.name).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }.font(.system(size: 11)).padding(.vertical, 4)
            }.font(.system(size: 11))
            if model.feedbackSent {
                Text("Feedback sent to poeprices.info").font(.system(size: 10)).foregroundStyle(PoeTheme.muted)
            } else {
                Button("Give feedback to poeprices.info…") { feedbackText = ""; showFeedback = true }
                    .buttonStyle(PoeButtonStyle()).font(.system(size: 11))
            }
        }.padding(.vertical, 4)
    }

    private var feedbackSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Prediction feedback").font(.headline)
            Text("Send your assessment and this item description to poeprices.info.").font(.caption).foregroundStyle(.secondary)
            Picker("Predicted price", selection: $feedbackOption) {
                Text("Too low").tag(PredictionFeedback.low)
                Text("Fair").tag(PredictionFeedback.fair)
                Text("Too high").tag(PredictionFeedback.high)
            }.pickerStyle(.segmented)
            if feedbackOption != .fair {
                TextField("Why do you think so? (Optional)", text: $feedbackText, axis: .vertical).lineLimit(3...5)
            }
            if let error = model.feedbackError { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { showFeedback = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.sendingFeedback ? "Sending…" : "Send feedback") {
                    Task {
                        await model.sendFeedback(feedbackOption, text: feedbackText, itemText: item.rawText, league: league)
                        if model.feedbackSent { showFeedback = false }
                    }
                }.disabled(model.sendingFeedback).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 380)
    }
}

private struct MarketSparkline: View {
    let values: [Double?]
    var body: some View {
        GeometryReader { geometry in
            let points = values.compactMap { $0 }
            let low = points.min() ?? 0
            let high = points.max() ?? 1
            let range = max(high - low, 1)
            Path { path in
                for (index, value) in points.enumerated() {
                    let point = CGPoint(x: geometry.size.width * Double(index) / Double(max(points.count - 1, 1)),
                                        y: geometry.size.height * (1 - (value - low) / range))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }.stroke(PoeTheme.secondary, lineWidth: 1)
        }.accessibilityHidden(true)
    }
}
