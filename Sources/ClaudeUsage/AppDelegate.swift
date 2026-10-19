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
        if InstallLocation.isDiskImage, !confirmRunningFromDiskImage() {
            NSApp.terminate(nil)
            return
        }
        guard replaceOtherInstances() else {
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

    /// Quits copies started before this one, so opening a newly installed version replaces the
    /// one in the menu bar. False if a newer copy is starting, which takes over instead.
    private func replaceOtherInstances() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let current = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != current.processIdentifier }
        guard !others.isEmpty else { return true }
        let launched = current.launchDate ?? Date()
        if others.contains(where: { ($0.launchDate ?? .distantPast) > launched }) { return false }

        for other in others { other.terminate() }
        let deadline = Date().addingTimeInterval(2)
        while others.contains(where: { !$0.isTerminated }), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        for other in others where !other.isTerminated { other.forceTerminate() }
        return true
    }

    /// Asks to install the app before running it from the disk image it was downloaded in.
    private func confirmRunningFromDiskImage() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Move Claude Usage to Applications"
        alert.informativeText = "Claude Usage is running from the disk image. Drag it into the Applications folder and open it from there. "
            + "Otherwise it stops when the disk image is ejected and can't start at login."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Run Anyway")
        // The app has no Dock icon, so bring the alert forward explicitly.
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        return alert.runModal() == .alertSecondButtonReturn
    }
}

enum InstallLocation {
    /// Whether the app was opened straight from its disk image. macOS also runs downloaded apps
    /// that haven't been moved from a temporary read-only copy ("App Translocation").
    static var isDiskImage: Bool {
        let bundle = Bundle.main.bundleURL
        if bundle.path.contains("/AppTranslocation/") { return true }
        let values = try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        return values?.volumeIsReadOnly == true
    }
}

@MainActor
final class SettingsWindowController {
    private let window: NSWindow
    private let model: SettingsModel

    init(settings: AppSettings, store: UsageStore) {
        model = SettingsModel()
        let hosting = NSHostingController(rootView: SettingsView(settings: settings, store: store, model: model))
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
