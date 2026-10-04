import Foundation

/// Small helpers for reading loosely-typed `JSONSerialization` output.
///
/// The usage endpoints are undocumented and their numbers arrive as either
/// integers or floats, so values are read leniently rather than via `Codable`.
enum JSONValue {
    static func object(_ value: Any?) -> [String: Any]? {
        value as? [String: Any]
    }

    static func array(_ value: Any?) -> [[String: Any]]? {
        value as? [[String: Any]]
    }

    static func string(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func number(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            return number.doubleValue
        case let double as Double:
            return double
        case let int as Int:
            return Double(int)
        case let string as String:
            return Double(string.trimmingCharacters(in: .whitespaces))
        default:
            return nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool:
            return bool
        case let number as NSNumber:
            return number.boolValue
        default:
            return nil
        }
    }

    static func parseObject(_ data: Data) throws -> [String: Any] {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw UsageError.invalidResponse("The response was not valid JSON.")
        }
        guard let object = json as? [String: Any] else {
            throw UsageError.invalidResponse("Expected a JSON object.")
        }
        return object
    }
}
