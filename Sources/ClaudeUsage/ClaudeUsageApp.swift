import AppKit

@main
enum ClaudeUsageApp {
    @MainActor
    static func main() {
        if let status = PreviewRenderer.runIfRequested(arguments: CommandLine.arguments) {
            exit(status)
        }

        let app = NSApplication.shared
        // Menu bar only: no Dock icon or app menu.
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) {
            app.run()
        }
    }
}
