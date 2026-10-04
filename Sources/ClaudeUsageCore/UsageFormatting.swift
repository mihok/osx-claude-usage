import Foundation

public enum UsageFormatting {
    /// "42%". Values between 0 and 1 show as "<1%" so light use is still visible.
    public static func percent(_ value: Double) -> String {
        if value > 0, value < 1 { return "<1%" }
        return "\(Int(value.rounded()))%"
    }

    /// Compact duration such as "45m", "2h 14m" or "3d 4h".
    public static func duration(_ interval: TimeInterval) -> String {
        let minutes = Int((max(interval, 0) / 60).rounded(.up))
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 {
            let remainder = minutes % 60
            return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
        }
        let days = hours / 24
        let remainder = hours % 24
        return remainder == 0 ? "\(days)d" : "\(days)d \(remainder)h"
    }

    /// "Resets in 2h 14m · Tue 15:00" (time formatted for the user's locale).
    public static func resetDescription(
        _ resetsAt: Date?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        guard let resetsAt else { return "No active window" }
        let remaining = resetsAt.timeIntervalSince(now)
        if remaining <= 0 { return "Resetting now…" }

        let time = DateFormatter()
        time.calendar = calendar
        time.locale = locale
        time.timeZone = calendar.timeZone
        if calendar.isDate(resetsAt, inSameDayAs: now) {
            time.setLocalizedDateFormatFromTemplate("jmm")
        } else if remaining < 6 * 24 * 3600 {
            time.setLocalizedDateFormatFromTemplate("EEEjmm")
        } else {
            time.setLocalizedDateFormatFromTemplate("MMMdjmm")
        }
        return "Resets in \(duration(remaining)) · \(time.string(from: resetsAt))"
    }

    /// "just now", "5m ago", "2h ago".
    public static func age(of date: Date, now: Date = Date()) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 45 { return "just now" }
        let minutes = Int(elapsed / 60)
        if minutes < 60 { return "\(max(minutes, 1))m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}

/// Decides when the next automatic refresh happens.
public enum RefreshSchedule {
    public static let minimumDelay: TimeInterval = 15
    public static let maximumBackoff: TimeInterval = 3600
    /// How soon to re-check problems the user fixes on this Mac (signing in, pasting a cookie).
    public static let localRetryDelay: TimeInterval = 60

    /// - Parameters:
    ///   - interval: The user's refresh interval.
    ///   - error: The error from the last attempt, or nil if it succeeded.
    ///   - consecutiveFailures: Failed attempts in a row, including the last one.
    ///   - nextReset: The soonest future reset in the current snapshot.
    public static func nextDelay(
        interval: TimeInterval,
        error: UsageError?,
        consecutiveFailures: Int,
        nextReset: Date?,
        now: Date = Date()
    ) -> TimeInterval {
        let interval = max(interval, minimumDelay)
        guard let error else {
            // Refresh shortly after a window resets so the meter drops back without waiting.
            if let nextReset {
                let untilReset = nextReset.timeIntervalSince(now) + 20
                if untilReset > 0 { return max(min(interval, untilReset), minimumDelay) }
            }
            return interval
        }
        if error.isLocal {
            return min(interval, localRetryDelay)
        }
        // Exponential backoff for server-side failures, honouring Retry-After.
        let exponent = Double(min(max(consecutiveFailures - 1, 0), 8))
        var delay = min(interval * pow(2, exponent), maximumBackoff)
        delay = max(delay, interval)
        if let retryAfter = error.retryAfter {
            delay = max(delay, min(retryAfter, maximumBackoff * 6))
        }
        return delay
    }

    /// Whether a snapshot is old enough that the meters should look faded.
    public static func isStale(_ snapshot: UsageSnapshot, interval: TimeInterval, now: Date = Date()) -> Bool {
        now.timeIntervalSince(snapshot.fetchedAt) > max(interval * 3, 15 * 60)
    }
}
