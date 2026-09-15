import SwiftUI
import TradeCore

struct FilterPanel: View {
    @ObservedObject var model: AppModel
    @State private var collapsed = false
    @State private var showHidden = false
    @State private var showSources = false
    @State private var expandedGroups: [String: Bool] = [:]
    private let itemKeys = [("linkedSockets", "Linked"), ("mapTier", "Map tier"), ("areaLevel", "Area level"), ("sentinelCharge", "Charge"), ("itemLevel", "Item level"), ("stackSize", "Stock"), ("whiteSockets", "White sockets"), ("gemLevel", "Gem level"), ("quality", "Quality")]
    private let booleanKeys = [("unidentified", "Identified"), ("mirrored", "Mirrored"), ("split", "Split"), ("imbuedGem", "Imbued gem"), ("fractured", "Fractured"), ("foulborn", "Foulborn"), ("vestigial", "Vestigial")]

    var body: some View {
        if let analysis = model.analysis, let preset = model.activePreset {
            VStack(alignment: .leading, spacing: 0) {
                ChipFlow {
                    let search = activeSearch(preset)
                    if case .object = preset.filters[search]["sub"] {
                        let sub = preset.filters[search]["sub"]
                        Button(sub["name"].string ?? sub["baseType"].string ?? "Variant") {
                            mutate { $0.filters[search]["sub"]["disabled"] = .bool(sub["disabled"].bool == false) }
                        }.buttonStyle(PoeButtonStyle(active: sub["disabled"].bool == false))
                    }
                    ForEach(itemKeys, id: \.0) { key, title in
                        if case .object = preset.filters[key] { numericChip(key, title: title, filter: preset.filters[key]) }
                    }
                    ForEach(Array(preset.filters["influences"].array.enumerated()), id: \.offset) { index, influence in
                        Button(influence["value"].string ?? "Influence") {
                            mutate {
                                var values = $0.filters["influences"].array
                                guard values.indices.contains(index) else { return }
                                values[index]["disabled"] = .bool(influence["disabled"].bool == false)
                                $0.filters["influences"] = .array(values)
                            }
                        }.buttonStyle(PoeButtonStyle(active: influence["disabled"].bool == false))
                    }
                    if preset.filters["rarity"]["value"].string == "magic" { logicalChip("rarity", title: "Magic", filter: preset.filters["rarity"]) }
                    if case .object = preset.filters["veiled"] { logicalChip("veiled", title: "Veiled", filter: preset.filters["veiled"]) }
                    if case .object = preset.filters["foil"] { logicalChip("foil", title: "Foil", filter: preset.filters["foil"]) }
                    if let reward = preset.filters["mapCompletionReward"]["name"].string {
                        Text("Reward: " + reward).foregroundStyle(PoeTheme.secondary).padding(.horizontal, 6).help("This map's completion reward")
                    }
                    if case .object = preset.filters["mapBlighted"] { mapVariant(preset.filters["mapBlighted"]) }
                    if booleanKeys.contains(where: { preset.filters[$0.0] != .null }) {
                        Menu {
                            ForEach(booleanKeys, id: \.0) { key, title in
                                if case .object = preset.filters[key] {
                                    Menu("\(title): \(booleanLabel(key, filter: preset.filters[key]))") {
                                        Button("Any") { setBoolean(key, value: .null) }
                                        Button("Yes") { setBoolean(key, value: .bool(true)) }
                                        Button("No") { setBoolean(key, value: .bool(false)) }
                                    }
                                }
                            }
                        } label: { Text("Item options"); Image(systemName: "chevron.down").font(.system(size: 8)) }
                        .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 8).padding(.vertical, 4).background(PoeTheme.dark, in: RoundedRectangle(cornerRadius: 3))
                    }
                    if !preset.stats.isEmpty || analysis.presets.count > 1 {
                        Button { collapsed.toggle() } label: {
                            let count = preset.stats.filter { ($0["group"] == .null ? $0["disabled"] : $0["meta"]["disabled"]).bool == false }.count
                            Text(count == 0 ? "No mods selected" : "\(count) mods selected")
                            Image(systemName: collapsed ? "chevron.down" : "chevron.up").font(.system(size: 8))
                        }.buttonStyle(PoeButtonStyle())
                    }
                }.padding(.bottom, 12)

                if !collapsed {
                    if analysis.presets.count > 1 {
                        HStack(spacing: 1) {
                            Rectangle().fill(PoeTheme.border).frame(width: 20, height: 1)
                            ForEach(analysis.presets) { p in
                                Button(p.title) { model.selectPreset(p.id) }.buttonStyle(PoeButtonStyle(active: p.id == model.presetID))
                            }
                            Rectangle().fill(PoeTheme.border).frame(height: 1)
                        }
                    }
                    ForEach(Array(preset.stats.enumerated()), id: \.offset) { index, stat in
                        if stat["group"].string != nil {
                            if visible(stat["meta"]) {
                                let expanded = expandedGroups["\(preset.id):\(index)"] ?? stat["expanded"].bool ?? false
                                statRow(stat["meta"], index: index, expanded: expanded)
                                if expanded {
                                    ForEach(Array(stat["stats"].array.enumerated()), id: \.offset) { child, nested in
                                        if visible(nested) { statRow(nested, index: index, child: child).padding(.leading, 16) }
                                    }
                                }
                            }
                        } else if visible(stat) { statRow(stat, index: index) }
                    }
                    if !preset.stats.isEmpty {
                        HStack(spacing: 8) {
                            Button { collapsed = true } label: { Text("Collapse"); Image(systemName: "chevron.up").font(.system(size: 8)) }.buttonStyle(PoeButtonStyle())
                            Spacer(minLength: 0)
                            Toggle("Hidden", isOn: $showHidden).toggleStyle(PoeCheckboxStyle()).help("Show hidden filters")
                            Toggle("Mods", isOn: $showSources).toggleStyle(PoeCheckboxStyle()).help("Show the modifiers contributing to each filter")
                        }.foregroundStyle(PoeTheme.muted).padding(.top, 6)
                    }
                }
                ForEach(Array(analysis.item.unknownModifiers.enumerated()), id: \.offset) { _, text in
                    Label("Not included: " + text, systemImage: "questionmark.square").font(.system(size: 11)).foregroundStyle(Color(hex: 0xfc8181)).padding(.vertical, 5)
                        .help("Unrecognized modifier; excluded from the search")
                }
            }.onChange(of: analysis.item.rawText) { _, _ in collapsed = false; showHidden = false; showSources = false; expandedGroups = [:] }
        }
    }

    private func activeSearch(_ preset: NativePreset) -> String { preset.filters["searchRelaxed"]["disabled"].bool == false ? "searchRelaxed" : "searchExact" }

    private func mutate(_ update: (inout NativePreset) -> Void) {
        guard var preset = model.activePreset, let sourceText = model.analysis?.item.rawText else { return }
        let sourceID = preset.id
        update(&preset)
        model.replaceActivePreset(preset, sourceText: sourceText, sourcePresetID: sourceID)
    }

    private func mutateStat(index: Int, child: Int?, _ update: (inout JSONValue) -> Void) {
        mutate { preset in
            guard preset.stats.indices.contains(index) else { return }
            if let child {
                var children = preset.stats[index]["stats"].array
                guard children.indices.contains(child) else { return }
                update(&children[child]); preset.stats[index]["stats"] = .array(children)
            } else if preset.stats[index]["group"] != .null { update(&preset.stats[index]["meta"]) }
            else { update(&preset.stats[index]) }
        }
    }

    private func numericChip(_ key: String, title: String, filter: JSONValue) -> some View {
        let enabled = filter["disabled"].bool == false
        let sourceText = model.analysis?.item.rawText
        let sourcePreset = model.presetID
        return HStack(spacing: 2) {
            Button(title) { model.updateItemFilter(key: key, enabled: !enabled) }.buttonStyle(.plain).padding(.leading, 6)
            FilterNumberField(value: filter["value"], placeholder: "min", enabled: enabled, submit: {
                guard model.analysis?.item.rawText == sourceText, model.presetID == sourcePreset else { return }; model.search()
            }, onFocus: {
                guard model.analysis?.item.rawText == sourceText, model.presetID == sourcePreset else { return }
                model.updateItemFilter(key: key, enabled: true)
            }) { value in
                guard model.analysis?.item.rawText == sourceText, model.presetID == sourcePreset else { return }
                mutate { $0.filters[key]["value"] = value.number.map(JSONValue.number) ?? .number(0); $0.filters[key]["disabled"] = .bool(value.number == nil) }
            }.frame(width: 36).accessibilityLabel("\(title) minimum")
            if key == "itemLevel" || key == "areaLevel" || filter["max"] != .null {
                Text("–").foregroundStyle(PoeTheme.muted)
                FilterNumberField(value: filter["max"], placeholder: "max", enabled: enabled, submit: {
                    guard model.analysis?.item.rawText == sourceText, model.presetID == sourcePreset else { return }; model.search()
                }, onFocus: {
                    guard model.analysis?.item.rawText == sourceText, model.presetID == sourcePreset else { return }
                    model.updateItemFilter(key: key, enabled: true)
                }) { value in
                    guard model.analysis?.item.rawText == sourceText, model.presetID == sourcePreset else { return }
                    mutate { $0.filters[key]["max"] = value; $0.filters[key]["disabled"] = .bool(false) }
                }.frame(width: 36).accessibilityLabel("\(title) maximum")
            }
        }.padding(.trailing, 2).padding(.vertical, 1).background(PoeTheme.dark, in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(enabled ? PoeTheme.secondary : .clear, lineWidth: 1))
    }

    private func logicalChip(_ key: String, title: String, filter: JSONValue) -> some View {
        Button(title) { model.updateItemFilter(key: key, enabled: filter["disabled"].bool != false) }
            .buttonStyle(PoeButtonStyle(active: filter["disabled"].bool == false))
    }

    private func booleanLabel(_ key: String, filter: JSONValue) -> String {
        if case .object(let values) = filter, let value = values["nativeValue"] { return value.bool.map { $0 ? "Yes" : "No" } ?? "Any" }
        if key == "unidentified" { return filter["disabled"].bool == false ? "No" : "Any" }
        if ["mirrored", "split", "imbuedGem"].contains(key) { return filter["disabled"].bool == true ? "No" : "Any" }
        return filter["value"].bool == false ? "No" : "Any"
    }

    private func setBoolean(_ key: String, value: JSONValue) { mutate { $0.filters[key]["nativeValue"] = value } }

    private func mapVariant(_ filter: JSONValue) -> some View {
        Menu {
            Button("Any map") { mutate { $0.filters["mapBlighted"]["value"] = .null } }
            Button("Not blighted") { mutate { $0.filters["mapBlighted"]["value"] = .bool(false) } }
            Button("Blighted") { mutate { $0.filters["mapBlighted"]["value"] = .string("Blighted") } }
            Button("Blight-ravaged") { mutate { $0.filters["mapBlighted"]["value"] = .string("Blight-ravaged") } }
        } label: { Text(filter["value"].string ?? (filter["value"].bool == false ? "Not blighted" : "Any map")) }
            .menuStyle(.borderlessButton).fixedSize().padding(.horizontal, 8).padding(.vertical, 4).background(PoeTheme.dark, in: RoundedRectangle(cornerRadius: 3))
    }

    private func visible(_ stat: JSONValue) -> Bool { showHidden || stat["hidden"].string == nil || stat["disabled"].bool == false }

    private func statRow(_ stat: JSONValue, index: Int, child: Int? = nil, expanded: Bool? = nil) -> some View {
        let enabled = stat["disabled"].bool == false
        let label = displayText(stat)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Toggle(isOn: Binding(get: { enabled }, set: { value in
                    mutateStat(index: index, child: child) { $0["disabled"] = .bool(!value) }
                    if expanded != nil && value { expandedGroups["\(model.presetID):\(index)"] = true }
                })) {
                    Text(label).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(label)
                }.toggleStyle(PoeCheckboxStyle())
                Spacer(minLength: 0)
                if let expanded {
                    Button { expandedGroups["\(model.presetID):\(index)"] = !expanded } label: { Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.system(size: 9)) }
                        .buttonStyle(.plain).accessibilityLabel(expanded ? "Collapse modifier group" : "Expand modifier group")
                }
                if case .object = stat["roll"] {
                    HStack(spacing: 1) { numberField(stat, field: "min", index: index, child: child); numberField(stat, field: "max", index: index, child: child) }
                } else if !statOptions(stat).isEmpty {
                    Menu {
                        ForEach(statOptions(stat), id: \.0) { value, title in
                            Button(title) { mutateStat(index: index, child: child) { $0["option"]["value"] = .number(value); $0["disabled"] = .bool(false) } }
                        }
                    } label: { Text(statOptions(stat).first { $0.0 == stat["option"]["value"].number }?.1 ?? "Option") }
                        .menuStyle(.borderlessButton).fixedSize().foregroundStyle(enabled ? PoeTheme.text : PoeTheme.muted)
                }
            }
            HStack(spacing: 4) {
                let tag = stat["tag"].string ?? ""
                if tag != "property" && !tag.isEmpty {
                    Text(tag).font(.system(size: 9)).foregroundStyle(tag == "crafted" ? Color(hex: 0xebf8ff) : PoeTheme.muted)
                        .padding(.horizontal, 3).background(tag == "crafted" ? Color(hex: 0x3182ce) : PoeTheme.dark, in: RoundedRectangle(cornerRadius: 2))
                }
                if let tier = stat["sources"].array.compactMap({ $0["modifier"]["info"]["tier"].number }).first {
                    Text("T\(tier.formatted())").font(.system(size: 9)).foregroundStyle(Color(hex: 0xecc94b))
                }
                if let low = stat["roll"]["bounds"]["min"].number, let high = stat["roll"]["bounds"]["max"].number {
                    if model.analysis?.item.rarity == "Unique" && low < high {
                        rollSlider(stat, low: low, high: high, index: index, child: child)
                    } else { Text("\(low.formatted())–\(high.formatted())").font(.system(size: 9)).foregroundStyle(PoeTheme.muted) }
                }
                if let quality = stat["nativeQuality"].number { Text("Q\(quality.formatted())").font(.system(size: 9)).foregroundStyle(PoeTheme.muted).help("The trade site compares this property at \(quality.formatted())% quality.") }
                if let hidden = stat["hidden"].string { Image(systemName: "eye.slash").font(.system(size: 9)).foregroundStyle(PoeTheme.muted).help(hidden) }
                Spacer()
            }.padding(.leading, 20)
            if !stat["nativeOils"].array.isEmpty {
                HStack(spacing: 3) {
                    Text("Anoint:").foregroundStyle(PoeTheme.muted)
                    ForEach(Array(stat["nativeOils"].array.enumerated()), id: \.offset) { _, oil in
                        if let icon = oil["icon"].string, let url = URL(string: icon) {
                            AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Color.clear }.frame(width: 16, height: 18)
                        }
                        Text(oil["name"].string ?? "Oil").foregroundStyle(PoeTheme.secondary)
                    }
                }.font(.system(size: 9)).padding(.leading, 20).help("Oils needed to anoint this passive")
            }
            if showSources {
                ForEach(Array(stat["sources"].array.enumerated()), id: \.offset) { _, source in
                    Text(sourceText(source)).font(.system(size: 10)).foregroundStyle(PoeTheme.secondary).fixedSize(horizontal: false, vertical: true).padding(.leading, 20)
                }
            }
        }.padding(.vertical, 8).overlay(alignment: .bottom) { Rectangle().fill(PoeTheme.border).frame(height: 1) }
    }

    private func statOptions(_ stat: JSONValue) -> [(Double, String)] {
        if stat["tradeId"].array.contains(.string("item.has_empty_modifier")) { return [(0, "Any"), (1, "Prefix"), (2, "Suffix")] }
        if stat["tag"].string == "mercenary-support" && stat["option"] != .null { return [(1, "Required"), (0, "Optional")] }
        return []
    }

    private func rollSlider(_ stat: JSONValue, low: Double, high: Double, index: Int, child: Int?) -> some View {
        let field = stat["roll"]["min"].number == nil ? "max" : "min"
        let oneSided = (stat["roll"]["min"].number != nil) != (stat["roll"]["max"].number != nil)
        let value = stat["roll"][field].number ?? stat["roll"]["value"].number ?? low
        let sourceText = model.analysis?.item.rawText
        let sourcePreset = model.presetID
        return HStack(spacing: 2) {
            Text(low.formatted()).font(.system(size: 9))
            Slider(value: Binding(get: { min(high, max(low, value)) }, set: { value in
                guard model.analysis?.item.rawText == sourceText, model.presetID == sourcePreset else { return }
                let scale = stat["roll"]["dp"].bool == true ? 100.0 : 1.0
                let rounded = field == "min" ? floor(value * scale) / scale : ceil(value * scale) / scale
                model.updateStat(index: index, child: child, field: field, value: .number(rounded))
            }), in: low...high).controlSize(.mini).disabled(!oneSided)
                .accessibilityLabel("\(field == "min" ? "Minimum" : "Maximum") \(stat["text"].string ?? "roll") slider")
            Text(high.formatted()).font(.system(size: 9))
        }.frame(width: 154).foregroundStyle(PoeTheme.muted).help("Item roll: \((stat["roll"]["value"].number ?? 0).formatted()). Drag to set the selected bound; use both number fields for a range.")
    }

    private func sourceText(_ source: JSONValue) -> String {
        let stat = source["stat"]
        let text = stat["translation"]["string"].string ?? stat["stat"]["ref"].string ?? "Modifier"
        let value = stat["roll"]["value"].number.map { $0.formatted(.number.grouping(.never)) } ?? "#"
        let name = source["modifier"]["info"]["name"].string
        return (name.map { $0 + ": " } ?? "") + text.replacingOccurrences(of: "(?<![#])[+-]?#", with: value, options: .regularExpression)
    }

    private func displayText(_ stat: JSONValue) -> String {
        let text = (stat["not"].bool == true ? "Not: " : "") + (stat["text"].string ?? stat["statRef"].string ?? "Modifier")
        guard let roll = stat["roll"]["value"].number else { return text }
        return text.replacingOccurrences(of: "(?<![#])[+-]?#", with: roll.formatted(.number.grouping(.never)), options: .regularExpression)
    }

    private func numberField(_ stat: JSONValue, field: String, index: Int, child: Int?) -> some View {
        let sourceText = model.analysis?.item.rawText
        let sourcePreset = model.presetID
        return FilterNumberField(value: stat["roll"][field], placeholder: field, enabled: stat["disabled"].bool == false, defaultOnFocus: stat["roll"]["default"][field], submit: {
            guard model.analysis?.item.rawText == sourceText, model.presetID == sourcePreset else { return }; model.search()
        }, onFocus: {
            guard model.analysis?.item.rawText == sourceText, model.presetID == sourcePreset else { return }
            mutateStat(index: index, child: child) { $0["disabled"] = .bool(false) }
        }) { value in
            guard model.analysis?.item.rawText == sourceText, model.presetID == sourcePreset else { return }
            model.updateStat(index: index, child: child, field: field, value: value)
        }.frame(width: 48).accessibilityLabel("\(field == "min" ? "Minimum" : "Maximum") \(stat["text"].string ?? "modifier")")
    }
}

private struct FilterNumberField: View {
    let value: JSONValue
    let placeholder: String
    let enabled: Bool
    var defaultOnFocus: JSONValue? = nil
    var submit: (() -> Void)? = nil
    var onFocus: (() -> Void)? = nil
    let update: (JSONValue) -> Void
    @State private var draft = ""
    @FocusState private var focused: Bool
    private var formatted: String { value.number.map { $0.formatted(.number.grouping(.never)) } ?? "" }

    var body: some View {
        TextField(placeholder, text: $draft).textFieldStyle(.plain).focused($focused)
            .font(PoeTheme.numbers).multilineTextAlignment(.trailing).foregroundStyle(enabled ? PoeTheme.text : PoeTheme.muted)
            .padding(.horizontal, 4).frame(height: 24).background(PoeTheme.dark)
            .onAppear { draft = formatted }
            .onChange(of: value) { _, _ in if !focused { draft = formatted } }
            .onChange(of: focused) { _, isFocused in
                if isFocused {
                    if value.number == nil, let initial = defaultOnFocus?.number {
                        draft = initial.formatted(.number.grouping(.never)); update(.number(initial))
                    } else { onFocus?() }
                } else { commit() }
            }
            .onSubmit { commit(); submit?() }
            .onChange(of: draft) { _, text in
                guard focused else { return }
                let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
                if normalized.isEmpty { update(.string("")) }
                else if let number = Double(normalized), number.isFinite { update(.number(number)) }
            }
    }
    private func commit() {
        let normalized = draft.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        if normalized.isEmpty {
            if value.number != nil { update(.string("")) }
        } else if let number = Double(normalized), number.isFinite {
            if value.number != number { update(.number(number)) }
        } else {
            // The view's value may still be the snapshot from before this edit.
            // Only invalid input should revert; valid drafts must survive Return
            // and blur without emitting a second write of that stale value.
            draft = formatted
        }
    }
}
