import Foundation

/// Lenient ISO-8601 parsing for timestamps such as `2026-02-20T14:00:00.364238+00:00`.
///
/// Claude reports microsecond precision, which `ISO8601DateFormatter` does not
/// reliably accept, so the fractional part is split off and added back manually.
public enum ISO8601 {
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let lock = NSLock()

    public static func date(from string: String) -> Date? {
        var text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let timeSeparator = text.firstIndex(where: { $0 == "T" || $0 == "t" || $0 == " " }) else {
            return nil
        }
        // Normalise "2026-01-01 10:00:00" to the RFC 3339 form.
        text.replaceSubrange(timeSeparator...timeSeparator, with: "T")

        var fraction: Double = 0
        if let time = text.firstIndex(of: "T"), let dot = text[time...].firstIndex(of: ".") {
            var end = text.index(after: dot)
            while end < text.endIndex, text[end].isASCII, text[end].isNumber {
                end = text.index(after: end)
            }
            let digits = text[text.index(after: dot)..<end]
            if !digits.isEmpty {
                fraction = Double("0.\(digits)") ?? 0
            }
            text.removeSubrange(dot..<end)
        }

        lock.lock()
        defer { lock.unlock() }
        if let date = formatter.date(from: text) {
            return date.addingTimeInterval(fraction)
        }
        // No zone designator: Claude timestamps are UTC.
        if let date = formatter.date(from: text + "Z") {
            return date.addingTimeInterval(fraction)
        }
        return nil
    }

    /// Accepts ISO-8601 strings as well as Unix timestamps in seconds or milliseconds.
    public static func date(fromJSON value: Any?) -> Date? {
        if let string = value as? String {
            return date(from: string)
        }
        if let seconds = JSONValue.number(value) {
            return Date(unixTimestamp: seconds)
        }
        return nil
    }
}

extension Date {
    /// Interprets values above 10^11 as milliseconds, smaller ones as seconds.
    init(unixTimestamp value: Double) {
        self = Date(timeIntervalSince1970: value > 100_000_000_000 ? value / 1000 : value)
    }
}
