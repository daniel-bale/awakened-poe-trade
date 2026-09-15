import AppKit
import ApplicationServices
import Carbon
import Combine
import TradeCore

enum CheckShortcut: String, CaseIterable, Identifiable {
    case ctrlD, optionD, commandD
    var id: String { rawValue }
    var title: String {
        switch self {
        case .ctrlD: return "⌃D"
        case .optionD: return "⌥D"
        case .commandD: return "⌘D"
        }
    }
    var carbonModifier: UInt32 {
        switch self {
        case .ctrlD: return UInt32(controlKey)
        case .optionD: return UInt32(optionKey)
        case .commandD: return UInt32(cmdKey)
        }
    }
}

private let checkShortcutSignature: OSType = 0x41504F45 // APOE
private let checkShortcutIdentifier: UInt32 = 1

private func checkShortcutEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ context: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let context else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let result = GetEventParameter(
        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
        nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier
    )
    guard result == noErr,
          identifier.signature == checkShortcutSignature,
          identifier.id == checkShortcutIdentifier else { return OSStatus(eventNotHandledErr) }
    let integration = Unmanaged<MacIntegration>.fromOpaque(context).takeUnretainedValue()
    Task { @MainActor [weak integration] in integration?.performCheckShortcut() }
    return noErr
}

/// Preserves each available representation, including image and rich-text data.
private struct ClipboardSnapshot {
    let changeCount: Int
    let items: [[NSPasteboard.PasteboardType: Data]]
    let isComplete: Bool

    init(pasteboard: NSPasteboard) {
        changeCount = pasteboard.changeCount
        var complete = true
        items = (pasteboard.pasteboardItems ?? []).map { item in
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    representations[type] = data
                } else {
                    complete = false
                }
            }
            return representations
        }
        isComplete = complete
    }

    func restore(to pasteboard: NSPasteboard, capturedChangeCount: Int, whileActive: () -> Bool) {
        guard isComplete, ItemCaptureSession.shouldRestoreClipboard(
            capturedChangeCount: capturedChangeCount,
            currentChangeCount: pasteboard.changeCount
        ) else { return }
        let restoredItems = items.map { representations in
            let item = NSPasteboardItem()
            for (type, data) in representations { item.setData(data, forType: type) }
            return item
        }
        // No suspension between checking ownership and restoring the clipboard.
        guard pasteboard.changeCount == capturedChangeCount, whileActive() else { return }
        pasteboard.clearContents()
        if !restoredItems.isEmpty { pasteboard.writeObjects(restoredItems) }
    }
}

@MainActor
final class MacIntegration: ObservableObject {
    @Published var shortcutStatus = "⌃D is available while Path of Exile is active"
    @Published var accessibilityGranted: Bool
    @Published var captureStatus = "Hover an item in Path of Exile and press ⌃D"
    @Published var isCapturing = false

    var restoreClipboard = true
    private var shortcut: CheckShortcut = .ctrlD
    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var checkAction: ((Result<String, Error>) -> Void)?
    private var activationObserver: NSObjectProtocol?
    private var captureTask: Task<Void, Never>?
    private var captureID: UUID?
    private var captureProcessID: pid_t?
    private var captureStartedAt: TimeInterval?
    private static var mainWindowOpener: (() -> Void)?
    private static weak var priceWindow: NSWindow?
    private static var windowCloseObserver: NSObjectProtocol?
    private static let gameBundleID = "com.GGG.PathOfExile"

    init() {
        accessibilityGranted = AXIsProcessTrusted()
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let activatedProcessID = app?.processIdentifier
            let observedAt = ProcessInfo.processInfo.systemUptime
            MainActor.assumeIsolated {
                self?.frontmostApplicationChanged(activatedProcessID: activatedProcessID, observedAt: observedAt)
            }
        }
    }

    func registerCheckShortcut(
        _ shortcut: CheckShortcut = .ctrlD,
        action: @escaping (Result<String, Error>) -> Void
    ) {
        cancelCapture(.cancelled)
        removeCheckShortcut()
        self.shortcut = shortcut
        checkAction = action
        refreshAccessibilityPermission()
        updateRegistration()
    }

    func updateCheckShortcut(_ shortcut: CheckShortcut) {
        cancelCapture(.cancelled)
        removeCheckShortcut()
        self.shortcut = shortcut
        captureStatus = "Hover an item in Path of Exile and press \(shortcut.title)"
        updateRegistration()
    }

    func refreshAccessibilityPermission() {
        accessibilityGranted = AXIsProcessTrusted()
    }

    /// Invoke only from an explicit user action, never at launch or on a hot key.
    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(options)
        updateRegistration()
    }

    /// Invoke only from an explicit user action in the app.
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    private func frontmostApplicationChanged(activatedProcessID: pid_t?, observedAt: TimeInterval) {
        refreshAccessibilityPermission()
        if let captureProcessID,
           (Self.frontmostGame?.processIdentifier != captureProcessID
            || (observedAt >= (captureStartedAt ?? observedAt) && activatedProcessID != captureProcessID)) {
            cancelCapture(.gameChanged)
        }
        updateRegistration()
    }

    private func updateRegistration() {
        guard checkAction != nil else { return }
        guard Self.frontmostGame != nil else {
            removeCheckShortcut()
            shortcutStatus = Self.gameIsRunning
                ? "\(shortcut.title) is available while Path of Exile is active"
                : "Start Path of Exile to use \(shortcut.title)"
            return
        }
        if hotKey == nil {
            var eventType = EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)
            )
            let installResult = InstallEventHandler(
                GetApplicationEventTarget(), checkShortcutEventHandler, 1, &eventType,
                Unmanaged.passUnretained(self).toOpaque(), &eventHandler
            )
            guard installResult == noErr else {
                shortcutStatus = "Could not register \(shortcut.title) (error \(installResult))"
                return
            }
            let identifier = EventHotKeyID(signature: checkShortcutSignature, id: checkShortcutIdentifier)
            let registerResult = RegisterEventHotKey(
                UInt32(kVK_ANSI_D), shortcut.carbonModifier, identifier,
                GetApplicationEventTarget(), 0, &hotKey
            )
            guard registerResult == noErr else {
                removeCheckShortcut()
                shortcutStatus = "\(shortcut.title) is already in use. Choose another shortcut in Settings."
                return
            }
        }
        shortcutStatus = accessibilityGranted
            ? "Hover an item and press \(shortcut.title)"
            : "\(shortcut.title) needs Accessibility permission to copy the hovered item"
    }

    fileprivate func performCheckShortcut() {
        guard !isCapturing, let game = Self.frontmostGame else { return }
        refreshAccessibilityPermission()
        guard accessibilityGranted else {
            captureStatus = ItemCaptureFailure.accessibilityRequired.localizedDescription
            checkAction?(.failure(ItemCaptureFailure.accessibilityRequired))
            return
        }
        let id = UUID()
        captureID = id
        captureProcessID = game.processIdentifier
        captureStartedAt = ProcessInfo.processInfo.systemUptime
        isCapturing = true
        captureStatus = "Release \(shortcut.title) to copy the hovered item…"
        captureTask = Task { [weak self] in
            guard let self else { return }
            await self.captureItem(processID: game.processIdentifier, id: id)
        }
    }

    private func captureItem(processID: pid_t, id: UUID) async {
        let pasteboard = NSPasteboard.general
        var session = ItemCaptureSession(
            gameProcessID: processID, startedAt: captureStartedAt ?? ProcessInfo.processInfo.systemUptime
        )
        var snapshot: ClipboardSnapshot?
        var copyWasSent = false
        var copyBaseline = pasteboard.changeCount
        do {
            while !Task.isCancelled, captureID == id {
                let decision: ItemCaptureDecision
                if !copyWasSent {
                    copyBaseline = pasteboard.changeCount
                    decision = session.pollKeysReleased(
                        Self.shortcutKeysAreReleased,
                        frontmostProcessID: Self.frontmostGame?.processIdentifier,
                        now: ProcessInfo.processInfo.systemUptime,
                        clipboardChangeCount: copyBaseline
                    )
                } else {
                    let changeCount = pasteboard.changeCount
                    let readText = pasteboard.string(forType: .string)
                    // Ignore a read that raced a producer writing another item.
                    let text = changeCount == pasteboard.changeCount ? readText : nil
                    decision = session.pollClipboard(
                        frontmostProcessID: Self.frontmostGame?.processIdentifier,
                        now: ProcessInfo.processInfo.systemUptime,
                        changeCount: changeCount, text: text
                    )
                }
                switch decision {
                case .waiting:
                    try await Task.sleep(nanoseconds: 10_000_000)
                case .sendCopy:
                    snapshot = restoreClipboard ? ClipboardSnapshot(pasteboard: pasteboard) : nil
                    if copyBaseline != pasteboard.changeCount
                        || (snapshot != nil && snapshot?.changeCount != copyBaseline) {
                        finishCapture(.failure(ItemCaptureFailure.cancelled), id: id)
                        return
                    }
                    guard Self.frontmostGame?.processIdentifier == processID else {
                        finishCapture(.failure(ItemCaptureFailure.gameChanged), id: id)
                        return
                    }
                    guard Self.shortcutKeysAreReleased else {
                        finishCapture(.failure(ItemCaptureFailure.keysStillHeld), id: id)
                        return
                    }
                    guard Self.sendCopy(to: processID) else {
                        finishCapture(.failure(ItemCaptureFailure.eventCreationFailed), id: id)
                        return
                    }
                    copyWasSent = true
                    captureStatus = "Copying the hovered item…"
                case .captured(let text, let changeCount):
                    guard Self.frontmostGame?.processIdentifier == processID else {
                        finishCapture(.failure(ItemCaptureFailure.gameChanged), id: id)
                        return
                    }
                    snapshot?.restore(to: pasteboard, capturedChangeCount: changeCount) {
                        Self.frontmostGame?.processIdentifier == processID
                    }
                    guard Self.frontmostGame?.processIdentifier == processID else {
                        finishCapture(.failure(ItemCaptureFailure.gameChanged), id: id)
                        return
                    }
                    finishCapture(.success(text), id: id)
                    return
                case .failed(let error):
                    finishCapture(.failure(error), id: id)
                    return
                }
            }
        } catch {
            // Focus/reconfiguration already finishes the attempt synchronously.
            if captureID == id { finishCapture(.failure(ItemCaptureFailure.cancelled), id: id) }
        }
    }

    private static var shortcutKeysAreReleased: Bool {
        let modifiers: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]
        return !CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(kVK_ANSI_D))
            && CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty
    }

    private static func sendCopy(to processID: pid_t) -> Bool {
        guard let source = CGEventSource(stateID: .privateState),
              let controlDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Control), keyDown: true),
              let cDown = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: true),
              let cUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: false),
              let controlUp = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_Control), keyDown: false) else {
            return false
        }
        controlDown.flags = .maskControl
        controlDown.type = .flagsChanged
        cDown.flags = .maskControl
        cUp.flags = .maskControl
        controlUp.flags = []
        controlUp.type = .flagsChanged
        // Target the game PID so a simultaneous focus switch cannot deliver
        // the shortcut to another app. This is exactly one Ctrl+C sequence.
        for event in [controlDown, cDown, cUp, controlUp] { event.postToPid(processID) }
        return true
    }

    private func finishCapture(_ result: Result<String, Error>, id: UUID) {
        guard captureID == id else { return }
        captureID = nil
        captureProcessID = nil
        captureStartedAt = nil
        captureTask = nil
        isCapturing = false
        switch result {
        case .success: captureStatus = "Copied the hovered item"
        case .failure(let error): captureStatus = error.localizedDescription
        }
        checkAction?(result)
    }

    private func cancelCapture(_ error: ItemCaptureFailure) {
        guard let id = captureID else { return }
        captureTask?.cancel()
        finishCapture(.failure(error), id: id)
    }

    private func removeCheckShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        hotKey = nil
        eventHandler = nil
    }

    static func configureMainWindowOpener(_ action: @escaping () -> Void) {
        mainWindowOpener = action
    }

    static func registerPriceWindow(_ window: NSWindow) {
        guard priceWindow !== window else { return }
        if let windowCloseObserver { NotificationCenter.default.removeObserver(windowCloseObserver) }
        priceWindow = window
        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                if priceWindow === window { priceWindow = nil }
            }
        }
    }

    static func bringToFront() {
        NSApp.activate(ignoringOtherApps: true)
        // A hidden window cannot become main until it is ordered on screen.
        // Keep its identity so reopening restores the same panel.
        if let window = priceWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            mainWindowOpener?()
        }
    }

    static func dismissToGame() {
        priceWindow?.orderOut(nil)
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == gameBundleID
        }?.activate(options: [])
    }

    static var gameIsRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == gameBundleID }
    }

    private static var frontmostGame: NSRunningApplication? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == gameBundleID else { return nil }
        return app
    }

    deinit {
        captureTask?.cancel()
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var model: AppModel?
    private var panelController: PricePanelController?
    private var statusItem: NSStatusItem?
    private var statusMenu: NSMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = AppModel()
        self.model = model
        configureMenus()
        let controller = PricePanelController(model: model)
        panelController = controller
        controller.show()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.show()
        return false
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === statusMenu, let model {
            menu.items.first?.title = "Hover an item in PoE, then press \(model.shortcut.title)"
        }
    }

    private func configureMenus() {
        let mainMenu = NSMenu()
        let applicationMenu = NSMenu(title: "Awakened PoE Trade")
        applicationMenu.addItem(menuItem("About Awakened PoE Trade", action: "orderFrontStandardAboutPanel:"))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(menuItem("Settings…", action: "showSettings:", key: ",", target: self))
        applicationMenu.addItem(.separator())
        let services = NSMenu(title: "Services")
        addSubmenu(services, to: applicationMenu)
        NSApp.servicesMenu = services
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(menuItem("Hide Awakened PoE Trade", action: "hide:", key: "h"))
        applicationMenu.addItem(menuItem("Hide Others", action: "hideOtherApplications:", key: "h", modifiers: [.command, .option]))
        applicationMenu.addItem(menuItem("Show All", action: "unhideAllApplications:"))
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(menuItem("Quit Awakened PoE Trade", action: "terminate:", key: "q"))
        addSubmenu(applicationMenu, to: mainMenu)

        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(menuItem("New Price Check", action: "newPriceCheck:", key: "n", target: self))
        fileMenu.addItem(menuItem("Check Clipboard", action: "checkClipboard:", key: "d", modifiers: .control, target: self))
        fileMenu.addItem(.separator())
        fileMenu.addItem(menuItem("Close", action: "performClose:", key: "w"))
        addSubmenu(fileMenu, to: mainMenu)

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(menuItem("Undo", action: "undo:", key: "z"))
        editMenu.addItem(menuItem("Redo", action: "redo:", key: "z", modifiers: [.command, .shift]))
        editMenu.addItem(.separator())
        editMenu.addItem(menuItem("Cut", action: "cut:", key: "x"))
        editMenu.addItem(menuItem("Copy", action: "copy:", key: "c"))
        editMenu.addItem(menuItem("Paste", action: "paste:", key: "v"))
        editMenu.addItem(menuItem("Select All", action: "selectAll:", key: "a"))
        addSubmenu(editMenu, to: mainMenu)

        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(menuItem("Show Awakened PoE Trade", action: "showPriceCheck:", target: self))
        addSubmenu(viewMenu, to: mainMenu)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(menuItem("Minimize", action: "performMiniaturize:", key: "m"))
        windowMenu.addItem(menuItem("Zoom", action: "performZoom:"))
        windowMenu.addItem(.separator())
        windowMenu.addItem(menuItem("Bring All to Front", action: "arrangeInFront:"))
        addSubmenu(windowMenu, to: mainMenu)
        NSApp.windowsMenu = windowMenu
        NSApp.mainMenu = mainMenu

        let statusMenu = NSMenu(title: "Awakened PoE Trade")
        let hint = NSMenuItem(title: "Hover an item in PoE, then press \(model?.shortcut.title ?? "⌃D")", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        statusMenu.addItem(hint)
        statusMenu.addItem(menuItem("Check Clipboard", action: "checkClipboard:", target: self))
        statusMenu.addItem(menuItem("Show Awakened PoE Trade", action: "showPriceCheck:", target: self))
        statusMenu.addItem(.separator())
        statusMenu.addItem(menuItem("Settings…", action: "showSettings:", target: self))
        statusMenu.addItem(menuItem("Quit Awakened PoE Trade", action: "terminate:", key: "q"))
        statusMenu.delegate = self
        self.statusMenu = statusMenu
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "flame", accessibilityDescription: "Awakened PoE Trade")
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = "Awakened PoE Trade"
        statusItem.menu = statusMenu
        self.statusItem = statusItem
    }

    private func addSubmenu(_ submenu: NSMenu, to menu: NSMenu) {
        let item = NSMenuItem(title: submenu.title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    private func menuItem(
        _ title: String, action: String, key: String = "",
        modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: Selector(action), keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    @objc private func newPriceCheck(_ sender: Any?) {
        model?.newCheck()
        panelController?.show()
    }

    @objc private func checkClipboard(_ sender: Any?) {
        model?.pasteAndCheck()
        panelController?.show()
    }

    @objc private func showPriceCheck(_ sender: Any?) { panelController?.show() }

    @objc private func showSettings(_ sender: Any?) {
        panelController?.show()
        model?.showSettings = true
    }
}
