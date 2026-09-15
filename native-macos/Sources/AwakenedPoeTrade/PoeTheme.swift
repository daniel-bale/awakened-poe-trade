import AppKit
import CoreText
import SwiftUI

enum PoeTheme {
    static let background = Color(hex: 0x2d3748)
    static let dark = Color(hex: 0x1a202c)
    static let border = Color(hex: 0x4a5568)
    static let text = Color(hex: 0xedf2f7)
    static let secondary = Color(hex: 0xa0aec0)
    static let muted = Color(hex: 0x718096)
    static let stripe = Color(hex: 0x353f52)
    static let blue = Color(hex: 0x63b3ed)
    static let font = Font.custom("Fontin-SmallCaps", size: 14)
    static let numbers = Font.custom("Exo2-SemiBold", size: 13)

    static func registerFonts() {
        for name in ["Fontin-SmallCaps-Hinted", "Exo2-Regular", "Exo2-SemiBold"] {
            guard let url = Bundle.main.resourceURL?.appendingPathComponent("fonts/\(name).ttf") else { continue }
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255, opacity: 1)
    }
}

struct PoeButtonStyle: ButtonStyle {
    var active = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(PoeTheme.font).foregroundStyle(PoeTheme.text)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(configuration.isPressed ? PoeTheme.muted : (active ? PoeTheme.border : PoeTheme.dark), in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(active ? PoeTheme.secondary : .clear, lineWidth: 1))
    }
}

struct PoeCheckboxStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: configuration.isOn ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13)).foregroundStyle(configuration.isOn ? PoeTheme.text : PoeTheme.muted).frame(width: 16)
                configuration.label
            }
        }.buttonStyle(.plain).accessibilityValue(configuration.isOn ? "On" : "Off")
    }
}

struct ChipFlow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? 428, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(width: bounds.width, subviews: subviews)
        for (index, point) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0
        var positions: [CGPoint] = []
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += lineHeight + spacing; lineHeight = 0 }
            positions.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return (CGSize(width: width, height: y + lineHeight), positions)
    }
}

func rarityColor(_ rarity: String) -> Color {
    switch rarity.lowercased() {
    case "unique": return Color(hex: 0xaf6025)
    case "rare": return Color(hex: 0xffff77)
    case "magic": return Color(hex: 0x8888ff)
    case "currency": return Color(hex: 0xaa9e82)
    default: return PoeTheme.text
    }
}

struct MessageBanner: View {
    let text: String
    let symbol: String
    let color: Color
    var body: some View {
        Label(text, systemImage: symbol).font(.system(size: 12)).foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true).padding(8)
            .frame(maxWidth: .infinity, alignment: .leading).background(PoeTheme.dark)
    }
}
