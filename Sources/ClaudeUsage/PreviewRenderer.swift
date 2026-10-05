import AppKit
import ClaudeUsageCore
import SwiftUI

/// `ClaudeUsage --render-preview <directory>` draws the menu bar meters, popover and settings
/// with sample data into PNG files. Used for screenshots and to check rendering in CI.
@MainActor
enum PreviewRenderer {
    static func runIfRequested(arguments: [String]) -> Int32? {
        if let flag = arguments.firstIndex(of: "--render-icon") {
            return renderIcon(arguments: arguments, flag: flag)
        }
        guard let flag = arguments.firstIndex(of: "--render-preview") else { return nil }
        guard flag + 1 < arguments.count else {
            FileHandle.standardError.write(Data("usage: ClaudeUsage --render-preview <output-directory>\n".utf8))
            return 64
        }
        let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            for file in try render(into: directory) {
                print("Wrote \(file.path)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Preview failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    // MARK: - App icon

    /// `ClaudeUsage --render-icon <AppIcon.iconset>` writes the PNGs `iconutil` turns into the app icon.
    private static func renderIcon(arguments: [String], flag: Int) -> Int32 {
        guard flag + 1 < arguments.count else {
            FileHandle.standardError.write(Data("usage: ClaudeUsage --render-icon <AppIcon.iconset>\n".utf8))
            return 64
        }
        let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for points in [16, 32, 128, 256, 512] {
                for scale in [1, 2] {
                    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
                    let size = NSSize(width: points, height: points)
                    let rep = bitmap(size: size, scale: CGFloat(scale)) { drawIcon(in: NSRect(origin: .zero, size: size)) }
                    guard let png = rep.representation(using: .png, properties: [:]) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                    try png.write(to: directory.appendingPathComponent(name))
                }
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("Icon rendering failed: \(error.localizedDescription)\n".utf8))
            return 1
        }
    }

    /// Three concentric usage rings on a dark rounded square, following the macOS icon grid.
    private static func drawIcon(in rect: NSRect) {
        let unit = rect.width / 1024
        let body = NSRect(x: rect.minX + 100 * unit, y: rect.minY + 100 * unit, width: 824 * unit, height: 824 * unit)
        let shape = NSBezierPath(roundedRect: body, xRadius: 185 * unit, yRadius: 185 * unit)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.shadowBlurRadius = 24 * unit
        shadow.shadowOffset = NSSize(width: 0, height: -10 * unit)
        shadow.set()
        NSColor(srgbRed: 0.10, green: 0.10, blue: 0.12, alpha: 1).setFill()
        shape.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGradient(
            starting: NSColor(srgbRed: 0.20, green: 0.19, blue: 0.24, alpha: 1),
            ending: NSColor(srgbRed: 0.08, green: 0.08, blue: 0.10, alpha: 1)
        )?.draw(in: shape, angle: -90)

        let center = NSPoint(x: body.midX, y: body.midY)
        let rings: [(radius: CGFloat, fraction: CGFloat, color: NSColor)] = [
            (292, 0.78, NSColor(srgbRed: 0.91, green: 0.47, blue: 0.35, alpha: 1)),
            (212, 0.55, NSColor(srgbRed: 0.95, green: 0.72, blue: 0.29, alpha: 1)),
            (132, 0.32, NSColor(srgbRed: 0.36, green: 0.75, blue: 0.66, alpha: 1)),
        ]
        let lineWidth = 58 * unit
        for ring in rings {
            let radius = ring.radius * unit
            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            ring.color.withAlphaComponent(0.18).setStroke()
            track.stroke()

            let arc = NSBezierPath()
            arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - 360 * ring.fraction, clockwise: true)
            arc.lineWidth = lineWidth
            arc.lineCapStyle = .round
            ring.color.setStroke()
            arc.stroke()
        }
    }

    // MARK: - Sample data

    static let now = ISO8601.date(from: "2026-10-04T13:00:00Z") ?? Date()

    /// One line of `claude -p /usage --output-format stream-json`, as Claude Code prints it.
    static let sampleSnapshot: UsageSnapshot = {
        let line = #"{"type":"assistant","usage_report":{"rate_limits":{"limits":["#
            + #"{"kind":"session","group":"session","percent":23,"resets_at":"2026-10-04T15:14:00Z","severity":"normal","is_active":true},"#
            + #"{"kind":"weekly_all","group":"weekly","percent":71,"resets_at":"2026-10-07T09:00:00Z","severity":"warning","is_active":false},"#
            + #"{"kind":"weekly_scoped","group":"weekly","percent":94,"resets_at":"2026-10-07T09:00:00Z","scope":{"model":{"display_name":"Sonnet"}},"severity":"critical","is_active":false},"#
            + #"{"kind":"weekly_scoped","group":"weekly","percent":8,"resets_at":"2026-10-07T09:00:00Z","scope":{"model":{"display_name":"Fable"}},"severity":"normal","is_active":false}"#
            + #"],"extra_usage":null}}}"#
        let fetchedAt = now.addingTimeInterval(-90)
        return (try? ClaudeUsageReport.snapshot(fromStreamJSON: line, fetchedAt: fetchedAt))
            ?? UsageSnapshot(meters: [], fetchedAt: fetchedAt)
    }()

    // MARK: - Rendering

    private static func render(into directory: URL) throws -> [URL] {
        var written: [URL] = []
        func write(_ rep: NSBitmapImageRep, _ name: String) throws {
            guard let png = rep.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let url = directory.appendingPathComponent(name)
            try png.write(to: url)
            written.append(url)
        }

        try write(menuBarSheet(), "menubar.png")
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try write(popover(appearance: appearance, snapshot: sampleSnapshot, error: nil), "popover-\(name).png")
        }
        try write(popover(appearance: .aqua, snapshot: sampleSnapshot, error: .usageUnavailable(nil)), "popover-error.png")
        try write(popover(appearance: .aqua, snapshot: nil, error: .notSignedIn), "popover-empty.png")
        try write(settingsWindow(), "settings.png")
        let iconSize = NSSize(width: 256, height: 256)
        try write(bitmap(size: iconSize, scale: 1) { drawIcon(in: NSRect(origin: .zero, size: iconSize)) }, "icon.png")
        return written
    }

    /// Every menu bar style on light and dark menu bars, drawn at 4x so details are visible.
    private static func menuBarSheet() -> NSBitmapImageRep {
        let meters = sampleSnapshot.relevantMeters.map { MenuBarMeter($0) }
        let variants: [MenuBarOptions] = [
            MenuBarOptions(style: .adaptive, showPercentages: false, showGlyphs: true, dimmed: false),
            MenuBarOptions(style: .colorful, showPercentages: false, showGlyphs: true, dimmed: false),
            MenuBarOptions(style: .monochrome, showPercentages: false, showGlyphs: true, dimmed: false),
            MenuBarOptions(style: .adaptive, showPercentages: true, showGlyphs: false, dimmed: false),
            MenuBarOptions(style: .adaptive, showPercentages: false, showGlyphs: true, dimmed: true),
        ]
        let placeholders = [
            MenuBarMeter(glyph: MeterID.sessionGlyph, percent: nil),
            MenuBarMeter(glyph: MeterID.weeklyGlyph, percent: nil),
        ]

        let rowHeight = MeterRenderer.height(for: variants[0])
        let columnWidth: CGFloat = 260
        let rows = variants.count + 1
        let size = NSSize(width: columnWidth * 2, height: rowHeight * CGFloat(rows))

        return bitmap(size: size, scale: 4) {
            for (column, appearanceName) in [NSAppearance.Name.vibrantLight, .vibrantDark].enumerated() {
                guard let appearance = NSAppearance(named: appearanceName) else { continue }
                appearance.performAsCurrentDrawingAppearance {
                    let background = NSRect(x: CGFloat(column) * columnWidth, y: 0, width: columnWidth, height: size.height)
                    (column == 0 ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.17, alpha: 1)).setFill()
                    background.fill()

                    var items: [([MenuBarMeter], MenuBarOptions)] = variants.map { (meters, $0) }
                    items.append((placeholders, MenuBarOptions(style: .adaptive, showPercentages: false, showGlyphs: true, dimmed: true)))
                    for (row, item) in items.enumerated() {
                        let itemSize = MeterRenderer.size(for: item.0, options: item.1)
                        let y = size.height - rowHeight * CGFloat(row + 1)
                        let rect = NSRect(x: background.minX + 8, y: y, width: itemSize.width, height: rowHeight)
                        MeterRenderer.draw(item.0, options: item.1, in: rect, baseColor: .labelColor)
                    }
                }
            }
        }
    }

    private static func popover(
        appearance: NSAppearance.Name,
        snapshot: UsageSnapshot?,
        error: UsageError?
    ) throws -> NSBitmapImageRep {
        let settings = AppSettings(defaults: previewDefaults())
        let store = UsageStore(settings: settings, previewSnapshot: snapshot, planName: "Max", error: error)
        let view = UsagePopoverView(store: store, settings: settings, openSettings: {}, quit: {}, fixedNow: now)
            .background(Color(nsColor: .windowBackgroundColor))
        return try snapshotView(NSHostingView(rootView: view), appearance: appearance)
    }

    private static func settingsWindow() throws -> NSBitmapImageRep {
        let settings = AppSettings(defaults: previewDefaults())
        let store = UsageStore(settings: settings, previewSnapshot: sampleSnapshot, planName: "Max")
        let view = SettingsView(settings: settings, store: store)
        return try snapshotView(NSHostingView(rootView: view), appearance: .aqua)
    }

    // MARK: - Helpers

    private static func previewDefaults() -> UserDefaults {
        let name = "ClaudeUsagePreview-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name) ?? .standard
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private static func snapshotView(_ view: NSView, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        view.appearance = NSAppearance(named: appearance)
        let size = view.fittingSize
        guard size.width > 0, size.height > 0 else { throw CocoaError(.featureUnsupported) }
        view.frame = NSRect(origin: .zero, size: size)

        // Host the view in an off-screen window so AppKit and SwiftUI lay it out fully.
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.appearance = view.appearance
        window.contentView = view
        window.orderBack(nil)
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        view.layoutSubtreeIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.featureUnsupported)
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func bitmap(size: NSSize, scale: CGFloat, draw: () -> Void) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )!
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        draw()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }
}
