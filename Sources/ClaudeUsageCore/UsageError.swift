import Foundation

public enum UsageError: Error, Equatable, Sendable {
    /// Claude Code isn't installed, or isn't at the path chosen in Settings.
    case cliNotFound(customPath: String?)
    /// Claude Code is installed but not signed in to a Claude account.
    case notSignedIn
    /// Claude Code isn't signed in to a Claude account when the app runs it, though it may work
    /// in Terminal, which signs it in another way.
    case signedInOnlyInTerminal(TerminalSignIn)
    /// The installed Claude Code predates the options usage checks rely on.
    case cliTooOld(String?)
    /// Claude Code ran but couldn't fetch the plan's usage this time.
    case usageUnavailable(String?)
    /// Claude Code failed to run or didn't finish.
    case cliFailed(String)
    case invalidResponse(String)

    /// Problems the user fixes on this Mac (installing or signing in to Claude Code). These are
    /// re-checked every minute so the meters recover soon after.
    public var isLocal: Bool {
        switch self {
        case .cliNotFound, .notSignedIn, .signedInOnlyInTerminal, .cliTooOld:
            return true
        default:
            return false
        }
    }

    /// The likeliest reason Claude Code isn't signed in when the app runs it, from what the app
    /// knows about how Terminal runs it.
    public static func signInProblem(
        removedCredentialVariables: [String],
        shellCommand: ShellCommandKind?,
        keychain: KeychainSignIn?
    ) -> UsageError {
        // A saved sign-in Claude Code couldn't see matters more than how Terminal signs in.
        if keychain == .found { return .signedInOnlyInTerminal(.keychainUnreadable) }
        if !removedCredentialVariables.isEmpty {
            return .signedInOnlyInTerminal(.variables(removedCredentialVariables))
        }
        if let shellCommand, shellCommand == .alias || shellCommand == .function {
            return .signedInOnlyInTerminal(.wrapper(shellCommand))
        }
        return .notSignedIn
    }
}

/// How Claude Code signs in when run from Terminal, when that can't be used to show plan usage.
public enum TerminalSignIn: Equatable, Sendable {
    /// With these variables, which the app leaves out because they can't report plan usage.
    case variables([String])
    /// Through an alias or shell function, which may point Claude Code at other settings.
    case wrapper(ShellCommandKind)
    /// The Keychain holds a sign-in, but Claude Code couldn't read it when the app ran it.
    case keychainUnreadable
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
        case let .signedInOnlyInTerminal(.variables(names)):
            return "In Terminal, Claude Code signs in with \(Self.list(names)), which can't report plan usage."
        case let .signedInOnlyInTerminal(.wrapper(kind)):
            return "Claude Code isn't signed in. In Terminal, `claude` is \(kind), which may sign it in another way."
        case .signedInOnlyInTerminal(.keychainUnreadable):
            return "Claude Code couldn't read its sign-in from the Keychain."
        case let .cliTooOld(version):
            if let version { return "Claude Code \(version) is too old to report usage." }
            return "Claude Code is too old to report usage."
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
            return "Run `claude auth login` in Terminal and sign in with your Claude account. After that, Claude Code doesn't need to be open."
        case let .signedInOnlyInTerminal(.variables(names)):
            let unset = names.map { "-u \($0) " }.joined()
            return "Sign in once with your Claude account: run `env \(unset)claude auth login` in Terminal. "
                + "\(Self.list(names)) \(names.count == 1 ? "stays" : "stay") set, so Terminal keeps working as before."
        case let .signedInOnlyInTerminal(.wrapper(kind)):
            let name = kind == .alias ? "alias" : "function"
            return "Run `command claude auth login` in Terminal (`command` skips the \(name)) and sign in with your Claude account. "
                + "If the \(name) sets CLAUDE_CONFIG_DIR, export that in your shell profile instead, then restart Claude Usage."
        case .signedInOnlyInTerminal(.keychainUnreadable):
            return "Make sure your login keychain is unlocked, or run `claude auth login` in Terminal to save the sign-in again."
        case .cliTooOld:
            return "Run `claude update` in Terminal, or choose a newer Claude Code in Settings."
        case .usageUnavailable:
            return "Claude may be limiting how often usage is checked. Showing the last known values; retrying automatically."
        case .cliFailed, .invalidResponse:
            return "Retrying automatically. Updating Claude Code (`claude update`) may help."
        }
    }
}

extension UsageError {
    /// "A", "A and B", "A, B and C".
    static func list(_ names: [String]) -> String {
        guard let last = names.last else { return "" }
        guard names.count > 1 else { return last }
        return names.dropLast().joined(separator: ", ") + " and " + last
    }
}
