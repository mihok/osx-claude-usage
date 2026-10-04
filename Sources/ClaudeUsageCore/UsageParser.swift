import Foundation

/// Turns the JSON returned by Claude's usage endpoints into a `UsageSnapshot`.
///
/// Both `api.anthropic.com/api/oauth/usage` and `claude.ai/api/organizations/{id}/usage`
/// return the same shape:
///
/// ```json
/// {
///   "five_hour":        { "utilization": 22.0, "resets_at": "2026-02-20T14:00:00.364238+00:00" },
///   "seven_day":        { "utilization": 49.0, "resets_at": "2026-02-24T10:00:01.364256+00:00" },
///   "seven_day_sonnet": { "utilization": 3.0,  "resets_at": null },
///   "extra_usage":      { "is_enabled": false, "utilization": null },
///   "limits": [ { "scope": { "model": { "display_name": "Fable" } }, "percent": 12, "resets_at": "…" } ]
/// }
/// ```
///
/// `utilization` and `percent` are percentages (0–100). Unknown keys are ignored so
/// new fields on Claude's side do not break parsing.
public enum UsageParser {
    public static func snapshot(from data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        try snapshot(from: JSONValue.parseObject(data), fetchedAt: fetchedAt)
    }

    public static func snapshot(from json: [String: Any], fetchedAt: Date = Date()) throws -> UsageSnapshot {
        var meters: [String: UsageMeter] = [:]

        // Rolling windows reported as top-level keys: five_hour, seven_day, seven_day_<model>, …
        for (key, value) in json {
            guard let window = JSONValue.object(value),
                  let descriptor = WindowDescriptor(key: key),
                  let percent = JSONValue.number(window["utilization"]) else { continue }
            meters[key] = descriptor.meter(
                percent: percent,
                resetsAt: ISO8601.date(fromJSON: window["resets_at"])
            )
        }

        // Model-scoped limits listed separately. Top-level keys win if both exist.
        for entry in JSONValue.array(json["limits"]) ?? [] {
            guard let meter = limitMeter(from: entry), meters[meter.id] == nil else { continue }
            meters[meter.id] = meter
        }

        // Pay-as-you-go usage beyond the plan, when the account has it switched on.
        if let extra = JSONValue.object(json[MeterID.extraUsage]),
           JSONValue.bool(extra["is_enabled"]) == true,
           let percent = JSONValue.number(extra["utilization"]) {
            meters[MeterID.extraUsage] = UsageMeter(
                id: MeterID.extraUsage,
                title: "Extra usage",
                detail: "Paid usage beyond your plan",
                glyph: "+",
                percent: percent,
                resetsAt: ISO8601.date(fromJSON: extra["resets_at"]),
                sortOrder: 90
            )
        }

        guard !meters.isEmpty else {
            throw UsageError.invalidResponse("The response did not contain any usage limits.")
        }
        return UsageSnapshot(meters: Array(meters.values), fetchedAt: fetchedAt)
    }

    // MARK: - Model-scoped limits

    private static func limitMeter(from entry: [String: Any]) -> UsageMeter? {
        let scope = JSONValue.object(entry["scope"])
        let model = JSONValue.object(scope?["model"])
        guard let name = JSONValue.string(model?["display_name"])
            ?? JSONValue.string(model?["name"])
            ?? JSONValue.string(entry["display_name"])
            ?? JSONValue.string(entry["name"]),
            let percent = JSONValue.number(entry["percent"]) ?? JSONValue.number(entry["utilization"])
        else { return nil }

        let modelName = WindowDescriptor.shortModelName(name)
        let slug = slugify(modelName)
        guard !slug.isEmpty else { return nil }
        let prefix = isSessionWindow(entry, scope: scope) ? MeterID.session : MeterID.weekly
        guard let descriptor = WindowDescriptor(key: "\(prefix)_\(slug)", displayName: modelName) else { return nil }
        return descriptor.meter(percent: percent, resetsAt: ISO8601.date(fromJSON: entry["resets_at"]))
    }

    /// Limits are weekly unless the entry says otherwise.
    private static func isSessionWindow(_ entry: [String: Any], scope: [String: Any]?) -> Bool {
        let keys = ["window", "period", "interval", "duration", "type", "kind", "limit_type"]
        let hints = keys.compactMap { JSONValue.string(entry[$0]) ?? JSONValue.string(scope?[$0]) }
        return hints.contains { hint in
            let hint = hint.lowercased()
            return hint.contains("five_hour") || hint.contains("5h") || hint.contains("session")
        }
    }

    static func slugify(_ text: String) -> String {
        let lowered = text.lowercased()
        var slug = ""
        var lastWasSeparator = false
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar), scalar.isASCII {
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

    func meter(percent: Double, resetsAt: Date?) -> UsageMeter {
        UsageMeter(
            id: id,
            title: title,
            detail: detail,
            glyph: glyph,
            percent: percent,
            resetsAt: resetsAt,
            sortOrder: sortOrder
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
