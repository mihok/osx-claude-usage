import Foundation

public enum UsageError: Error, Equatable, Sendable {
    /// No Claude Code credentials in the Keychain or on disk.
    case notSignedIn
    /// Claude Code's access token has expired; Claude Code refreshes it on its next run.
    case tokenExpired
    /// The Keychain or credentials file exists but could not be read.
    case credentialsUnavailable(String)
    /// The claude.ai source is selected but no cookie has been saved.
    case missingCookie
    /// Claude answered 401/403.
    case unauthorized(source: UsageSourceKind, status: Int, message: String?)
    /// Claude answered 429.
    case rateLimited(retryAfter: TimeInterval?)
    case httpStatus(Int, message: String?)
    case invalidResponse(String)
    case network(String)
    case noOrganization

    /// Errors that are resolved on this Mac (signing in, pasting a cookie) rather than by Claude's servers.
    /// These are re-checked quickly because no network request is involved.
    public var isLocal: Bool {
        switch self {
        case .notSignedIn, .tokenExpired, .missingCookie:
            return true
        default:
            return false
        }
    }

    public var retryAfter: TimeInterval? {
        if case let .rateLimited(retryAfter) = self { return retryAfter }
        return nil
    }
}

extension UsageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "No Claude Code sign-in found."
        case .tokenExpired:
            return "Your Claude Code sign-in has expired."
        case let .credentialsUnavailable(reason):
            return "Couldn't read Claude Code credentials: \(reason)"
        case .missingCookie:
            return "No claude.ai session saved."
        case let .unauthorized(_, status, message):
            return "Claude rejected the credentials (HTTP \(status))" + (message.map { ": \($0)" } ?? ".")
        case .rateLimited:
            return "Claude is rate-limiting usage requests."
        case let .httpStatus(status, message):
            return "Unexpected response from Claude (HTTP \(status))" + (message.map { ": \($0)" } ?? ".")
        case let .invalidResponse(reason):
            return "Couldn't read the usage response. \(reason)"
        case let .network(reason):
            return "Network error: \(reason)"
        case .noOrganization:
            return "No Claude organization found for this session."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notSignedIn:
            return "Run `claude` in Terminal and sign in with your Claude account, or use a claude.ai browser session in Settings."
        case .tokenExpired:
            return "Run any `claude` command in Terminal to refresh it. The meters pick up the new sign-in automatically."
        case .credentialsUnavailable:
            return "If macOS asked for Keychain access, choose Always Allow."
        case .missingCookie:
            return "Paste your claude.ai cookie in Settings."
        case let .unauthorized(source, _, _):
            switch source {
            case .claudeCode:
                return "Run `claude` in Terminal to sign in again."
            case .claudeWeb:
                return "Your claude.ai session may have expired. Copy a fresh cookie into Settings."
            }
        case .rateLimited:
            return "Showing the last known values; retrying automatically with a longer delay."
        case .httpStatus, .invalidResponse:
            return "Claude's usage endpoint may have changed. Retrying automatically."
        case .network:
            return "Check your connection. Retrying automatically."
        case .noOrganization:
            return "Make sure the cookie belongs to a signed-in claude.ai account."
        }
    }
}
