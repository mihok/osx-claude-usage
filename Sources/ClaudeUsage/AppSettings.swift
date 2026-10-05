import Combine
import ClaudeUsageCore
import Foundation

/// How the menu bar rings are coloured.
enum MeterStyle: String, CaseIterable, Identifiable {
    /// Menu bar text colour, turning orange then red near the limit.
    case adaptive
    /// Green, orange, red.
    case colorful
    /// A template image tinted entirely by macOS, like system icons.
    case monochrome

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .adaptive: return "Adaptive"
        case .colorful: return "Traffic light"
        case .monochrome: return "Monochrome"
        }
    }
}

/// User preferences, persisted in `UserDefaults`.
@MainActor
final class AppSettings: ObservableObject {
    static let refreshIntervals: [TimeInterval] = [60, 120, 300, 600, 900, 1800]

    private enum Key {
        static let claudePath = "claudePath"
        static let meterStyle = "meterStyle"
        static let showPercentages = "showPercentages"
        static let showGlyphs = "showGlyphs"
        static let refreshInterval = "refreshInterval"
        static let hiddenMeterIDs = "hiddenMeterIDs"
    }

    private let defaults: UserDefaults

    /// Where Claude Code is installed; empty means find it automatically.
    @Published var claudePath: String {
        didSet { defaults.set(claudePath, forKey: Key.claudePath) }
    }

    @Published var meterStyle: MeterStyle {
        didSet { defaults.set(meterStyle.rawValue, forKey: Key.meterStyle) }
    }

    /// Draw "42%" next to each ring.
    @Published var showPercentages: Bool {
        didSet { defaults.set(showPercentages, forKey: Key.showPercentages) }
    }

    /// Draw a short label ("5", "W", …) inside each ring.
    @Published var showGlyphs: Bool {
        didSet { defaults.set(showGlyphs, forKey: Key.showGlyphs) }
    }

    @Published var refreshInterval: TimeInterval {
        didSet { defaults.set(refreshInterval, forKey: Key.refreshInterval) }
    }

    /// Meters the user removed from the menu bar. Stored as hidden (not shown) so new
    /// limits Claude introduces appear automatically.
    @Published private(set) var hiddenMeterIDs: Set<String> {
        didSet { defaults.set(Array(hiddenMeterIDs).sorted(), forKey: Key.hiddenMeterIDs) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        claudePath = defaults.string(forKey: Key.claudePath) ?? ""
        meterStyle = defaults.string(forKey: Key.meterStyle).flatMap(MeterStyle.init(rawValue:)) ?? .adaptive
        showPercentages = defaults.object(forKey: Key.showPercentages) as? Bool ?? false
        showGlyphs = defaults.object(forKey: Key.showGlyphs) as? Bool ?? true
        let interval = defaults.double(forKey: Key.refreshInterval)
        refreshInterval = interval >= 60 ? interval : 300
        hiddenMeterIDs = Set(defaults.stringArray(forKey: Key.hiddenMeterIDs) ?? [MeterID.extraUsage])
    }

    func isShownInMenuBar(_ meterID: String) -> Bool {
        !hiddenMeterIDs.contains(meterID)
    }

    func setShownInMenuBar(_ shown: Bool, meterID: String) {
        if shown {
            hiddenMeterIDs.remove(meterID)
        } else {
            hiddenMeterIDs.insert(meterID)
        }
    }

    /// The meters to draw in the menu bar, in display order. Never empty when data exists,
    /// so the status item cannot disappear.
    func menuBarMeters(from snapshot: UsageSnapshot) -> [UsageMeter] {
        let relevant = snapshot.relevantMeters
        let shown = relevant.filter { isShownInMenuBar($0.id) }
        if !shown.isEmpty { return shown }
        return Array(relevant.prefix(1))
    }

    /// Placeholder ring IDs to draw before the first successful refresh.
    var placeholderMeterIDs: [String] {
        let shown = MeterID.primary.filter(isShownInMenuBar)
        return shown.isEmpty ? [MeterID.session] : shown
    }
}
