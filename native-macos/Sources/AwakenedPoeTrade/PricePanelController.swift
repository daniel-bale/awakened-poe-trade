import AppKit
import SwiftUI

/// Own the window so removing its native frame cannot remove keyboard eligibility.
@MainActor
final class PricePanelController: NSWindowController, NSWindowDelegate {
    private static let frameName = NSWindow.FrameAutosaveName("NativePricePanel")

    init(model: AppModel) {
        let window = PricePanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 720),
            styleMask: [.borderless, .resizable, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Awakened PoE Trade"
        window.identifier = NSUserInterfaceItemIdentifier("main-price-panel")
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .floating
        window.collectionBehavior.insert(.fullScreenAuxiliary)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentMinSize = NSSize(width: 440, height: 500)
        window.contentMaxSize = NSSize(width: 640, height: CGFloat.greatestFiniteMagnitude)

        let content = MainView(model: model)
            .tint(PoeTheme.secondary)
            .preferredColorScheme(.dark)
            .frame(minWidth: 440, idealWidth: 460, maxWidth: 640, minHeight: 500)
            .task { await model.refreshLeagues() }
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(NSSize(width: 460, height: 720))

        super.init(window: window)
        window.delegate = self
        MacIntegration.registerPriceWindow(window)
        MacIntegration.configureMainWindowOpener { [weak self] in self?.show() }

        if !window.setFrameUsingName(Self.frameName) { window.center() }
        window.setFrameAutosaveName(Self.frameName)
    }

    required init?(coder: NSCoder) { return nil }

    func show() {
        guard let window else { return }
        MacIntegration.registerPriceWindow(window)
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        MacIntegration.dismissToGame()
        return false
    }

    private final class PricePanel: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }

        override func performClose(_ sender: Any?) {
            guard attachedSheet == nil else { return }
            MacIntegration.dismissToGame()
        }

        override func cancelOperation(_ sender: Any?) {
            guard attachedSheet == nil else {
                super.cancelOperation(sender)
                return
            }
            MacIntegration.dismissToGame()
        }
    }
}
