import Foundation

/// Reads the output of `claude -p /usage --output-format stream-json --verbose`.
///
/// Claude Code attaches a structured `usage_report` to the message that carries the `/usage`
/// text. Its plan rows are the usage endpoint's `limits[]`, passed through as Claude sent them:
///
/// ```json
/// { "type": "assistant", "message": { … },
///   "usage_report": {
///     "session": { "total_cost_usd": 0, … },
///     "rate_limits": {
///       "limits": [
///         { "kind": "session", "group": "session", "percent": 23,
///           "resets_at": "2026-10-04T15:14:00Z", "severity": "normal", "is_active": true },
///         { "kind": "weekly_all", "group": "weekly", "percent": 71, … },
///         { "kind": "weekly_scoped", "group": "weekly", "percent": 94,
///           "scope": { "model": { "display_name": "Sonnet" } }, "severity": "critical", … }
///       ],
///       "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null, … }
///     } } }
/// ```
///
/// Older Claude Code versions print only text ("Current session: 23% used · resets …"), which is
/// used as a fallback without reset times.
public enum ClaudeUsageReport {
    public static func snapshot(
        fromStreamJSON output: String,
        stderr: String = "",
        fetchedAt: Date = Date()
    ) throws -> UsageSnapshot {
        var report: [String: Any]?
        var texts: [String] = []

        for line in output.split(whereSeparator: \.isNewline) {
            guard line.first == "{",
                  let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            else { continue }
            if let usageReport = JSONValue.object(object["usage_report"]) {
                report = usageReport
            }
            if JSONValue.string(object["type"]) == "result", let result = JSONValue.string(object["result"]) {
                texts.append(result)
            }
            if JSONValue.string(object["type"]) == "assistant",
               let content = JSONValue.object(object["message"])?["content"] as? [[String: Any]] {
                texts += content.compactMap { JSONValue.string($0["text"]) }
            }
        }
        let text = texts.joined(separator: "\n")

        if let report {
            guard let rateLimits = JSONValue.object(report["rate_limits"]),
                  let rows = JSONValue.array(rateLimits["limits"]) else {
                // Claude Code couldn't fetch the plan's usage this time.
                throw failure(text: text, stderr: stderr)
            }
            let meters = meters(fromRows: rows, extraUsage: JSONValue.object(rateLimits["extra_usage"]))
            guard !meters.isEmpty else { throw failure(text: text, stderr: stderr) }
            return UsageSnapshot(meters: meters, fetchedAt: fetchedAt)
        }

        let meters = meters(fromText: text)
        guard !meters.isEmpty else { throw failure(text: text, stderr: stderr) }
        return UsageSnapshot(meters: meters, fetchedAt: fetchedAt)
    }

    // MARK: - Structured rows

    static func meters(fromRows rows: [[String: Any]], extraUsage: [String: Any]?) -> [UsageMeter] {
        var meters: [UsageMeter] = []
        var seen = Set<String>()
        for row in rows {
            guard let meter = meter(fromRow: row), seen.insert(meter.id).inserted else { continue }
            meters.append(meter)
        }
        if let extra = extraUsage.flatMap(extraUsageMeter) {
            meters.append(extra)
        }
        return meters
    }

    static func meter(fromRow row: [String: Any]) -> UsageMeter? {
        guard let percent = JSONValue.number(row["percent"]) ?? JSONValue.number(row["utilization"]) else {
            return nil
        }
        let kind = JSONValue.string(row["kind"])?.lowercased() ?? ""
        let group = JSONValue.string(row["group"])?.lowercased() ?? ""
        let scope = JSONValue.object(row["scope"])
        let scopeName = JSONValue.string(JSONValue.object(scope?["model"])?["display_name"])
            ?? JSONValue.string(JSONValue.object(scope?["surface"])?["display_name"])

        let key: String
        switch kind {
        case "session" where scopeName == nil:
            key = MeterID.session
        case "weekly_all":
            key = MeterID.weekly
        default:
            let isSession = group == "session" || kind.hasPrefix("session")
            // Scoped rows are named after their model or surface; otherwise after the kind itself.
            var name = scopeName ?? kind
            for prefix in ["weekly_", "session_"] where scopeName == nil && name.hasPrefix(prefix) {
                name.removeFirst(prefix.count)
            }
            let slug = UsageText.slugify(WindowDescriptor.shortModelName(name))
            guard !slug.isEmpty else { return nil }
            key = "\(isSession ? MeterID.session : MeterID.weekly)_\(slug)"
        }

        guard let descriptor = WindowDescriptor(key: key, displayName: scopeName) else { return nil }
        return descriptor.meter(
            percent: percent,
            resetsAt: ISO8601.date(fromJSON: row["resets_at"]),
            severity: severity(JSONValue.string(row["severity"]))
        )
    }

    /// Claude grades each row itself; follow its reading where there is one.
    static func severity(_ value: String?) -> MeterLevel? {
        switch value?.lowercased() {
        case "critical", "exceeded", "error": return .critical
        case "warning", "elevated", "high": return .elevated
        case "normal", "ok", "low": return .normal
        default: return nil
        }
    }

    static func extraUsageMeter(_ extra: [String: Any]) -> UsageMeter? {
        guard JSONValue.bool(extra["is_enabled"]) == true else { return nil }
        let percent: Double
        if let used = JSONValue.number(extra["used_credits"]),
           let limit = JSONValue.number(extra["monthly_limit"]), limit > 0 {
            percent = used / limit * 100
        } else if let utilization = JSONValue.number(extra["utilization"]) {
            percent = utilization
        } else {
            return nil
        }
        return UsageMeter(
            id: MeterID.extraUsage,
            title: "Extra usage",
            detail: "Paid usage beyond your plan",
            glyph: "+",
            percent: percent,
            resetsAt: ISO8601.date(fromJSON: extra["resets_at"]),
            sortOrder: 90
        )
    }

    // MARK: - Text fallback

    /// Parses lines such as "Current week (Sonnet only): 94% used · resets Wed 9am".
    static func meters(fromText text: String) -> [UsageMeter] {
        var meters: [UsageMeter] = []
        var seen = Set<String>()
        for line in text.split(whereSeparator: \.isNewline) {
            let line = line.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Current "),
                  let colon = line.firstIndex(of: ":"),
                  let percentSign = line[colon...].firstIndex(of: "%"),
                  let percent = Double(line[line.index(after: colon)..<percentSign].trimmingCharacters(in: .whitespaces))
            else { continue }

            let title = line[..<colon]
            let key: String
            var displayName: String?
            if title == "Current session" {
                key = MeterID.session
            } else if title == "Current week (all models)" {
                key = MeterID.weekly
            } else if title.hasPrefix("Current week ("), title.hasSuffix(")") {
                var name = String(title.dropFirst("Current week (".count).dropLast())
                if name.hasSuffix(" only") { name.removeLast(" only".count) }
                displayName = WindowDescriptor.shortModelName(name)
                key = "\(MeterID.weekly)_\(UsageText.slugify(displayName ?? name))"
            } else {
                continue
            }
            guard let descriptor = WindowDescriptor(key: key, displayName: displayName),
                  seen.insert(key).inserted else { continue }
            meters.append(descriptor.meter(percent: percent, resetsAt: nil, severity: nil))
        }
        return meters
    }

    // MARK: - Errors

    /// Explains a run that produced no usage rows, using what Claude Code printed.
    static func failure(text: String, stderr: String) -> UsageError {
        let combined = (text + "\n" + stderr).lowercased()
        if combined.contains("not logged in") || combined.contains("please run /login")
            || combined.contains("run claude auth login") || combined.contains("login expired") {
            return .notSignedIn
        }
        let detail = [text, stderr]
            .flatMap { $0.split(whereSeparator: \.isNewline) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            // Skip the banner /usage prints before its rows.
            .first { !$0.isEmpty && !$0.hasPrefix("You are currently using") }
        return .usageUnavailable(detail.map { String($0.prefix(200)) })
    }
}

enum UsageText {
    static func slugify(_ text: String) -> String {
        var slug = ""
        var lastWasSeparator = false
        for scalar in text.lowercased().unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                slug.unicodeScalars.append(scalar)
                lastWasSeparator = false
            } else if !lastWasSeparator, !slug.isEmpty {
                slug.append("_")
                lastWasSeparator = true
            }
        }
        while slug.hasSuffix("_") { slug.removeLast() }
        return slug
    }
}

/// Display metadata derived from a window key such as `seven_day_sonnet`.
struct WindowDescriptor {
    let id: String
    let title: String
    let detail: String
    let glyph: String
    let sortOrder: Int

    private static let knownNames: [String: String] = [
        "opus": "Opus",
        "sonnet": "Sonnet",
        "haiku": "Haiku",
        "fable": "Fable",
        "mythos": "Mythos",
        "oauth_apps": "OAuth apps",
        "cowork": "Cowork",
    ]

    init?(key: String, displayName: String? = nil) {
        id = key
        switch key {
        case MeterID.session:
            title = "Session"
            detail = "Rolling 5-hour window"
            glyph = MeterID.sessionGlyph
            sortOrder = 0
            return
        case MeterID.weekly:
            title = "Weekly"
            detail = "All models · 7-day window"
            glyph = MeterID.weeklyGlyph
            sortOrder = 1
            return
        default:
            break
        }

        let isSession: Bool
        let suffix: String
        if key.hasPrefix(MeterID.weekly + "_") {
            isSession = false
            suffix = String(key.dropFirst(MeterID.weekly.count + 1))
        } else if key.hasPrefix(MeterID.session + "_") {
            isSession = true
            suffix = String(key.dropFirst(MeterID.session.count + 1))
        } else {
            return nil
        }
        guard !suffix.isEmpty else { return nil }

        let name = Self.shortModelName(displayName ?? Self.knownNames[suffix] ?? Self.prettify(suffix))
        title = "\(isSession ? "Session" : "Weekly") · \(name)"
        detail = "\(name) only · \(isSession ? "5-hour" : "7-day") window"
        glyph = String(name.prefix(1)).uppercased()
        switch suffix {
        case "opus": sortOrder = 10
        case "sonnet": sortOrder = 11
        default: sortOrder = isSession ? 5 : 20
        }
    }

    func meter(percent: Double, resetsAt: Date?, severity: MeterLevel?) -> UsageMeter {
        UsageMeter(
            id: id,
            title: title,
            detail: detail,
            glyph: glyph,
            percent: percent,
            resetsAt: resetsAt,
            sortOrder: sortOrder,
            severity: severity
        )
    }

    /// "Claude Fable" → "Fable": the brand prefix adds nothing in a menu bar.
    static func shortModelName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("Claude "), trimmed.count > 7 {
            return String(trimmed.dropFirst(7))
        }
        return trimmed
    }

    private static func prettify(_ suffix: String) -> String {
        let words = suffix.split(separator: "_").map(String.init)
        guard let first = words.first else { return suffix }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}
