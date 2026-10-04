import Foundation

/// Helpers for the claude.ai session cookie the user pastes into Settings.
public enum ClaudeWebCookie {
    /// Accepts a bare `sessionKey` value, a `sessionKey=…` pair, a full `Cookie` header value,
    /// or a header line starting with `Cookie:`; returns a value for the `Cookie` request header.
    public static func normalize(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("cookie:") {
            text = String(text.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces)
        }
        // Header values copied from some browsers wrap across lines.
        text = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined()
        if text.hasPrefix("\""), text.hasSuffix("\""), text.count > 1 {
            text = String(text.dropFirst().dropLast())
        }
        guard !text.isEmpty else { return nil }
        return text.contains("=") ? text : "sessionKey=\(text)"
    }

    /// Reads one cookie's value out of a `Cookie` header value.
    public static func value(named name: String, in header: String) -> String? {
        for part in header.split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if pair.count == 2, pair[0] == name, !pair[1].isEmpty {
                return pair[1]
            }
        }
        return nil
    }

    /// Organization IDs are UUIDs; reject anything that could alter the request path.
    public static func isValidOrganizationID(_ id: String) -> Bool {
        !id.isEmpty && id.count <= 64 && id.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-"
        }
    }
}
