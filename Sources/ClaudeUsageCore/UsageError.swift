import Foundation

public enum UsageError: Error, Equatable, Sendable {
    /// Claude Code isn't installed, or isn't at the path chosen in Settings.
    case cliNotFound(customPath: String?)
    /// Claude Code is installed but not signed in to a Claude account.
    case notSignedIn
    /// Claude Code ran but couldn't fetch the plan's usage this time.
    case usageUnavailable(String?)
    /// Claude Code failed to run or didn't finish.
    case cliFailed(String)
    case invalidResponse(String)

    /// Problems the user fixes on this Mac (installing or signing in to Claude Code). These are
    /// re-checked every minute so the meters recover soon after.
    public var isLocal: Bool {
        switch self {
        case .cliNotFound, .notSignedIn:
            return true
        default:
            return false
        }
    }
}

extension UsageError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .cliNotFound(customPath):
            if let customPath, !customPath.isEmpty {
                return "Claude Code isn't at \(customPath)."
            }
            return "Couldn't find Claude Code."
        case .notSignedIn:
            return "Claude Code isn't signed in."
        case let .usageUnavailable(detail):
            return "Claude Code couldn't fetch your usage" + (detail.map { ": \($0)" } ?? ".")
        case let .cliFailed(reason):
            return reason
        case let .invalidResponse(reason):
            return "Couldn't read Claude Code's usage report. \(reason)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .cliNotFound:
            return "Install Claude Code and run `claude` once to sign in. If it's installed somewhere unusual, choose its location in Settings."
        case .notSignedIn:
            return "Run `claude` in Terminal once and sign in with your Claude account. After that, Claude Code doesn't need to be open."
        case .usageUnavailable:
            return "Claude may be limiting how often usage is checked. Showing the last known values; retrying automatically."
        case .cliFailed, .invalidResponse:
            return "Retrying automatically. Updating Claude Code (`claude update`) may help."
        }
    }
}
