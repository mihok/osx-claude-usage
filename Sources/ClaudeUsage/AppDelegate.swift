import AppKit
import ServiceManagement
import SwiftUI

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: AppSettings!
    private var store: UsageStore!
    private var statusItemController: StatusItemController?
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if isAnotherInstanceRunning() {
            NSApp.terminate(nil)
            return
        }
        settings = AppSettings()
        store = UsageStore(settings: settings)
        statusItemController = StatusItemController(store: store, settings: settings) { [weak self] in
            self?.showSettings()
        }
        store.start()
    }

    private func showSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(settings: settings, store: store)
        }
        settingsWindowController?.show()
    }

    private func isAnotherInstanceRunning() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return false }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != me }
    }
}

@MainActor
final class SettingsWindowController {
    private let window: NSWindow

    init(settings: AppSettings, store: UsageStore) {
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, store: store))
        window = NSWindow(contentViewController: hosting)
        window.title = "Claude Usage Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
    }

    func show() {
        // The app has no Dock icon, so bring it forward explicitly.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.makeKeyAndOrderFront(nil)
    }
}
