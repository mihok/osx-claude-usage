import AppKit
import ClaudeUsageCore
import Combine
import SwiftUI

/// Owns the menu bar item: draws the meters and shows the popover or context menu.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let store: UsageStore
    private let settings: AppSettings
    private let openSettings: () -> Void
    private var cancellables = Set<AnyCancellable>()
    private var outsideClickMonitor: Any?
    private var appearanceObservation: NSKeyValueObservation?
    private var tick: Timer?
    private var lastRendered: (meters: [MenuBarMeter], options: MenuBarOptions)?
    private var popoverClosedAt = Date.distantPast

    init(store: UsageStore, settings: AppSettings, openSettings: @escaping () -> Void) {
        self.store = store
        self.settings = settings
        self.openSettings = openSettings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.autosaveName = "ClaudeUsageMeters"
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.imagePosition = .imageOnly
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                Task { @MainActor in self?.updateButton(force: true) }
            }
        }

        let hosting = NSHostingController(
            rootView: UsagePopoverView(
                store: store,
                settings: settings,
                openSettings: { [weak self] in self?.showSettings() },
                quit: { NSApp.terminate(nil) }
            )
        )
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        store.objectWillChange
            .merge(with: settings.objectWillChange)
            .debounce(for: .milliseconds(30), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateButton() }
            .store(in: &cancellables)

        // Re-evaluate staleness and tooltips even when nothing new arrives.
        tick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateButton() }
        }
        updateButton(force: true)
    }

    // MARK: - Drawing

    private func updateButton(force: Bool = false) {
        guard let button = statusItem.button else { return }
        let menuBarMeters: [MenuBarMeter]
        if store.snapshot != nil {
            menuBarMeters = store.menuBarMeters.map { MenuBarMeter(glyph: $0.glyph, percent: $0.percent) }
        } else {
            let glyphs = [MeterID.session: "5h", MeterID.weekly: "7d"]
            menuBarMeters = settings.placeholderMeterIDs.map { MenuBarMeter(glyph: glyphs[$0] ?? "", percent: nil) }
        }
        let options = MenuBarOptions(
            style: settings.meterStyle,
            showPercentages: settings.showPercentages,
            showGlyphs: settings.showGlyphs,
            dimmed: store.snapshot == nil || store.isStale
        )

        if force || lastRendered?.meters != menuBarMeters || lastRendered?.options != options {
            button.image = MeterRenderer.image(for: menuBarMeters, options: options)
            lastRendered = (menuBarMeters, options)
        }
        button.toolTip = tooltip()
        button.setAccessibilityLabel(accessibilityLabel())
    }

    private func tooltip() -> String {
        var lines: [String] = []
        if let snapshot = store.snapshot {
            let now = Date()
            for meter in snapshot.relevantMeters {
                let reset = meter.resetsAt.map { " · resets in \(UsageFormatting.duration($0.timeIntervalSince(now)))" } ?? ""
                lines.append("\(meter.title): \(UsageFormatting.percent(meter.percent))\(reset)")
            }
            if store.isStale {
                lines.append("Last updated \(UsageFormatting.age(of: snapshot.fetchedAt))")
            }
        }
        if let error = store.lastError {
            lines.append(error.localizedDescription)
        }
        return lines.isEmpty ? "Claude Usage – loading…" : lines.joined(separator: "\n")
    }

    private func accessibilityLabel() -> String {
        guard let snapshot = store.snapshot else { return "Claude usage, loading" }
        let parts = settings.menuBarMeters(from: snapshot).map { "\($0.title) \(Int($0.percent.rounded())) percent" }
        return "Claude usage: " + parts.joined(separator: ", ")
    }

    // MARK: - Interaction

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if Date().timeIntervalSince(popoverClosedAt) > 0.25 {
            // The click that dismissed a transient popover must not immediately reopen it.
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        store.refreshIfStale()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
        // A transient popover in a background app does not always see clicks elsewhere.
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.popover.performClose(nil) }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        popoverClosedAt = Date()
        statusItem.button?.highlight(false)
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    private func showContextMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        let refresh = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(settingsMenuItem), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Claude Usage", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        // Attach the menu only for this click so a left click keeps opening the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func refreshNow() {
        store.refreshNow()
    }

    @objc private func settingsMenuItem() {
        showSettings()
    }

    private func showSettings() {
        popover.performClose(nil)
        openSettings()
    }
}
