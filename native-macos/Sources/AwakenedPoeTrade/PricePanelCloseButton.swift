import AppKit
import SwiftUI

/// A native control keeps a click in the transparent header from becoming a window drag.
struct PricePanelCloseButton: NSViewRepresentable {
    var action: () -> Void

    func makeNSView(context: Context) -> CloseButton {
        let button = CloseButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(systemSymbolName: "xmark.square.fill", accessibilityDescription: "Close price check")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        button.contentTintColor = NSColor(red: 160 / 255, green: 174 / 255, blue: 192 / 255, alpha: 1)
        button.toolTip = "Close price check (Esc)"
        button.setAccessibilityLabel("Close price check")
        button.setAccessibilityIdentifier("price-panel-close")
        button.target = button
        button.action = #selector(CloseButton.closePanel(_:))
        button.onClose = action
        return button
    }

    func updateNSView(_ button: CloseButton, context: Context) {
        button.onClose = action
    }

    final class CloseButton: NSButton {
        var onClose: (() -> Void)?

        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        @objc func closePanel(_ sender: Any?) { onClose?() }
    }
}
