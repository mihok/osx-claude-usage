import AppKit
import ClaudeUsageCore
import SwiftUI

extension MeterStyle {
    /// Arc colour in the menu bar. `base` is the menu bar's text colour (or black for templates).
    func menuBarColor(for level: MeterLevel, base: NSColor) -> NSColor {
        switch (self, level) {
        case (.monochrome, _): return base
        case (.adaptive, .normal): return base
        case (.colorful, .normal): return .systemGreen
        case (_, .elevated): return .systemOrange
        case (_, .critical): return .systemRed
        }
    }

    /// Arc colour inside the popover.
    func popoverColor(for level: MeterLevel) -> Color {
        switch (self, level) {
        case (.monochrome, _): return .primary
        case (.adaptive, .normal): return .accentColor
        case (.colorful, .normal): return .green
        case (_, .elevated): return .orange
        case (_, .critical): return .red
        }
    }
}

/// One ring in the menu bar.
struct MenuBarMeter: Equatable {
    var glyph: String
    /// nil draws an empty ring, used before the first refresh.
    var percent: Double?

    var level: MeterLevel { MeterLevel(percent: percent ?? 0) }
}

struct MenuBarOptions: Equatable {
    var style: MeterStyle
    var showPercentages: Bool
    var showGlyphs: Bool
    /// Fade the rings when the data is out of date.
    var dimmed: Bool
    /// Height of the menu bar being drawn into (`NSStatusBar.system.thickness`).
    var barHeight: CGFloat = MeterRenderer.standardBarHeight
}

/// Draws the row of circular meters shown in the menu bar.
enum MeterRenderer {
    /// The menu bar is 24pt tall on macOS 11 and later, and taller on MacBooks with a notch.
    static let standardBarHeight: CGFloat = 24
    /// Rings grow to this diameter where the menu bar has room for it.
    static let preferredRingDiameter: CGFloat = 24
    /// Kept clear above and below each ring so it never touches the menu bar's edges.
    static let verticalMargin: CGFloat = 1
    static let ringLineWidth: CGFloat = 3.3
    static let meterSpacing: CGFloat = 6
    static let textGap: CGFloat = 3
    static let horizontalInset: CGFloat = 1

    static let percentFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    static func ringDiameter(for options: MenuBarOptions) -> CGFloat {
        min(preferredRingDiameter, max(options.barHeight - verticalMargin * 2, 12))
    }

    static func height(for options: MenuBarOptions) -> CGFloat {
        ringDiameter(for: options) + verticalMargin * 2
    }

    static func glyphFont(for glyph: String) -> NSFont {
        let size: CGFloat = glyph.count > 1 ? 6.5 : 7.5
        let font = NSFont.systemFont(ofSize: size, weight: .bold)
        if let rounded = font.fontDescriptor.withDesign(.rounded), let roundedFont = NSFont(descriptor: rounded, size: size) {
            return roundedFont
        }
        return font
    }

    static func percentText(_ meter: MenuBarMeter) -> String {
        meter.percent.map(UsageFormatting.percent) ?? "–"
    }

    static func size(for meters: [MenuBarMeter], options: MenuBarOptions) -> NSSize {
        let diameter = ringDiameter(for: options)
        var width = horizontalInset * 2
        for (index, meter) in meters.enumerated() {
            if index > 0 { width += meterSpacing }
            width += diameter
            if options.showPercentages {
                width += textGap + textSize(percentText(meter)).width
            }
        }
        return NSSize(width: ceil(max(width, diameter + horizontalInset * 2)), height: height(for: options))
    }

    /// The status item image. Monochrome images are templates tinted by macOS; the other
    /// styles resolve dynamic colours at draw time so they follow the menu bar's appearance.
    static func image(for meters: [MenuBarMeter], options: MenuBarOptions) -> NSImage {
        let isTemplate = options.style == .monochrome
        let image = NSImage(size: size(for: meters, options: options), flipped: false) { rect in
            draw(meters, options: options, in: rect, baseColor: isTemplate ? .black : .labelColor)
            return true
        }
        image.isTemplate = isTemplate
        return image
    }

    /// Draws into the current graphics context. Colours resolve against the current drawing appearance.
    static func draw(_ meters: [MenuBarMeter], options: MenuBarOptions, in rect: NSRect, baseColor: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        defer { context.restoreGState() }
        if options.dimmed {
            context.setAlpha(0.45)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        defer {
            if options.dimmed { context.endTransparencyLayer() }
        }

        let diameter = ringDiameter(for: options)
        var x = rect.minX + horizontalInset
        let midY = rect.midY
        for (index, meter) in meters.enumerated() {
            if index > 0 { x += meterSpacing }
            let ringRect = NSRect(x: x, y: midY - diameter / 2, width: diameter, height: diameter)
            drawRing(meter, in: ringRect, options: options, baseColor: baseColor)
            x += diameter

            if options.showPercentages {
                x += textGap
                let text = percentText(meter)
                let color = meter.percent == nil || meter.level == .normal
                    ? baseColor
                    : options.style.menuBarColor(for: meter.level, base: baseColor)
                let attributes: [NSAttributedString.Key: Any] = [.font: percentFont, .foregroundColor: color]
                let baseline = midY - percentFont.capHeight / 2
                (text as NSString).draw(at: NSPoint(x: x, y: baseline + percentFont.descender), withAttributes: attributes)
                x += textSize(text).width
            }
        }
    }

    private static func drawRing(_ meter: MenuBarMeter, in ringRect: NSRect, options: MenuBarOptions, baseColor: NSColor) {
        let circleRect = ringRect.insetBy(dx: ringLineWidth / 2, dy: ringLineWidth / 2)
        let center = NSPoint(x: circleRect.midX, y: circleRect.midY)
        let radius = circleRect.width / 2

        let track = NSBezierPath(ovalIn: circleRect)
        track.lineWidth = ringLineWidth
        baseColor.withAlphaComponent(options.style == .monochrome ? 0.3 : 0.22).setStroke()
        track.stroke()

        if let percent = meter.percent, percent > 0 {
            let progress: NSBezierPath
            if percent >= 100 {
                progress = NSBezierPath(ovalIn: circleRect)
            } else {
                progress = NSBezierPath()
                // Keep tiny values visible as a dot rather than nothing.
                let sweep = max(percent / 100 * 360, 6)
                progress.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: 90 - sweep, clockwise: true)
                progress.lineCapStyle = .round
            }
            progress.lineWidth = ringLineWidth
            options.style.menuBarColor(for: meter.level, base: baseColor).setStroke()
            progress.stroke()
        }

        if options.showGlyphs, !meter.glyph.isEmpty {
            let font = glyphFont(for: meter.glyph)
            let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: baseColor]
            let text = meter.glyph as NSString
            let width = text.size(withAttributes: attributes).width
            let baseline = center.y - font.capHeight / 2
            text.draw(at: NSPoint(x: center.x - width / 2, y: baseline + font.descender), withAttributes: attributes)
        }
    }

    private static func textSize(_ text: String) -> NSSize {
        (text as NSString).size(withAttributes: [.font: percentFont])
    }
}
