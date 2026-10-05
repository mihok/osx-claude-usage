import Foundation

/// Stable identifiers for the limit windows Claude reports.
public enum MeterID {
    public static let session = "five_hour"
    public static let weekly = "seven_day"
    public static let weeklyOpus = "seven_day_opus"
    public static let weeklySonnet = "seven_day_sonnet"
    public static let extraUsage = "extra_usage"

    /// The two windows every plan has; always shown even when idle.
    public static let primary: [String] = [session, weekly]

    /// Labels drawn inside the session and weekly rings.
    public static let sessionGlyph = "5"
    public static let weeklyGlyph = "W"
}

/// One usage-limit window, e.g. the rolling 5-hour session.
public struct UsageMeter: Equatable, Identifiable, Sendable {
    /// Stable key, e.g. `five_hour`, `seven_day`, `seven_day_fable`.
    public let id: String
    /// Short name, e.g. "Session" or "Weekly · Sonnet".
    public let title: String
    /// One-line explanation of the window, e.g. "5-hour rolling window".
    public let detail: String
    /// Short label drawn inside the menu bar ring, e.g. "5" or "W".
    public let glyph: String
    /// Percent of the limit used, clamped to 0...100.
    public let percent: Double
    /// When the window resets, if Claude reported it.
    public let resetsAt: Date?
    /// Position relative to other meters (lower comes first).
    public let sortOrder: Int
    /// Claude's own reading of how close this limit is, when it gives one.
    public let severity: MeterLevel?

    public init(
        id: String,
        title: String,
        detail: String,
        glyph: String,
        percent: Double,
        resetsAt: Date?,
        sortOrder: Int,
        severity: MeterLevel? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.glyph = glyph
        self.percent = percent.isFinite ? min(max(percent, 0), 100) : 0
        self.resetsAt = resetsAt
        self.sortOrder = sortOrder
        self.severity = severity
    }

    public var fraction: Double { percent / 100 }

    /// Claude's severity when reported, otherwise derived from the percentage.
    public var level: MeterLevel { severity ?? MeterLevel(percent: percent) }

    public var isPrimary: Bool { MeterID.primary.contains(id) }

    /// Secondary windows (per-model caps, extra usage) are only worth showing once they are in use.
    public var isRelevant: Bool { isPrimary || percent > 0 || resetsAt != nil }
}

/// How close a meter is to its limit.
public enum MeterLevel: Int, Comparable, Sendable {
    case normal
    case elevated
    case critical

    public static let elevatedThreshold: Double = 70
    public static let criticalThreshold: Double = 90

    public init(percent: Double) {
        if percent >= MeterLevel.criticalThreshold {
            self = .critical
        } else if percent >= MeterLevel.elevatedThreshold {
            self = .elevated
        } else {
            self = .normal
        }
    }

    public static func < (lhs: MeterLevel, rhs: MeterLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Everything fetched in one refresh.
public struct UsageSnapshot: Equatable, Sendable {
    /// All meters Claude reported, sorted for display.
    public let meters: [UsageMeter]
    public let fetchedAt: Date

    public init(meters: [UsageMeter], fetchedAt: Date) {
        self.meters = meters.sorted {
            ($0.sortOrder, $0.title) < ($1.sortOrder, $1.title)
        }
        self.fetchedAt = fetchedAt
    }

    public func meter(id: String) -> UsageMeter? {
        meters.first { $0.id == id }
    }

    /// Meters worth showing: the primary windows plus any secondary window in use.
    public var relevantMeters: [UsageMeter] {
        meters.filter(\.isRelevant)
    }

    /// The soonest reset that is still in the future.
    public func nextReset(after now: Date) -> Date? {
        meters.compactMap(\.resetsAt).filter { $0 > now }.min()
    }

    /// The meter closest to its limit.
    public var mostConstrained: UsageMeter? {
        relevantMeters.max { $0.percent < $1.percent }
    }
}
