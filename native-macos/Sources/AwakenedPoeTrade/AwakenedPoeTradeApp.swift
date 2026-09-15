import AppKit

@MainActor
@main
enum AwakenedPoeTradeApp {
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        PoeTheme.registerFonts()
        withExtendedLifetime(delegate) {
            application.run()
        }
    }
}
