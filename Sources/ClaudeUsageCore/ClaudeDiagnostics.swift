import Foundation

/// What the last usage check learned about Claude Code, to help when the rings stay empty.
public struct ClaudeDiagnostics: Equatable, Sendable {
    public var checkedAt: Date
    public var executable: String?
    public var version: String?
    /// Whether Claude Code ran with the login shell's environment (as in Terminal) or only the app's.
    public var usedLoginShellEnvironment: Bool?
    /// Sign-in variables the shell sets that the app left out. Names only, never values.
    public var removedCredentialVariables: [String]?
    /// What `claude` is in the login shell.
    public var shellCommand: ShellCommandKind?
    public var exitStatus: Int32?
    public var summary: ClaudeUsageReport.Summary?
    public var stderr: String?
    public var authStatus: ClaudeAuthStatus?
    /// Whether the Keychain holds Claude Code's sign-in; checked only when it isn't signed in.
    public var keychainSignIn: KeychainSignIn?
    public var error: String?

    public init(checkedAt: Date = Date()) {
        self.checkedAt = checkedAt
    }

    /// "claude 2.1.303 at ~/.local/bin/claude".
    public var cliDescription: String? {
        guard let executable else { return nil }
        let path = Self.abbreviatingHome(in: executable)
        if let version { return "claude \(version) at \(path)" }
        return "claude at \(path)"
    }

    /// "/Users/me/.local/bin/claude" → "~/.local/bin/claude", which also keeps the user name out of reports.
    static func abbreviatingHome(in path: String, home: String = NSHomeDirectory()) -> String {
        guard !home.isEmpty, home != "/", path == home || path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// A plain-text report to paste into a bug report. Contains no email address or token.
    public func report(appVersion: String) -> String {
        let timestamp = ISO8601DateFormatter().string(from: checkedAt)
        var lines = [
            "Claude Usage \(appVersion)",
            "Checked: \(timestamp)",
            "Claude Code: \(cliDescription ?? "not found")",
        ]
        if let usedLoginShellEnvironment {
            lines.append("Environment: \(usedLoginShellEnvironment ? "login shell (as in Terminal)" : "app only (login shell didn't answer)")")
        }
        if let removedCredentialVariables {
            let names = removedCredentialVariables.isEmpty ? "none" : removedCredentialVariables.joined(separator: ", ")
            lines.append("Sign-in variables left out: \(names)")
        }
        if let shellCommand { lines.append("In Terminal, claude is: \(shellCommand)") }
        if let exitStatus { lines.append("Exit status: \(exitStatus)") }
        if let authStatus {
            let details = [authStatus.authMethod, authStatus.subscriptionType].compactMap { $0 }.joined(separator: ", ")
            lines.append("Signed in: \(authStatus.loggedIn ? "yes" : "no")\(details.isEmpty ? "" : " (\(details))")")
            if let configDirectory = authStatus.configDirectory {
                lines.append("Settings folder: \(Self.abbreviatingHome(in: configDirectory))")
            }
            if let apiProvider = authStatus.apiProvider, apiProvider != "firstParty" {
                lines.append("API provider: \(apiProvider)")
            }
            if let apiKeySource = authStatus.apiKeySource { lines.append("API key from: \(apiKeySource)") }
        }
        if let keychainSignIn { lines.append("Keychain sign-in: \(keychainSignIn)") }
        if let summary {
            let report = summary.hasUsageRows ? "present, with rows" : summary.hasUsageReport ? "present, no rows" : "missing"
            lines.append("Usage report: \(report)")
        }
        if let error { lines.append("Error: \(error)") }
        if let text = summary?.text.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            lines += ["", "Claude Code printed:", String(text.prefix(2000))]
        }
        if let stderr = stderr?.trimmingCharacters(in: .whitespacesAndNewlines), !stderr.isEmpty {
            lines += ["", "Claude Code errors:", String(stderr.suffix(2000))]
        }
        return lines.joined(separator: "\n")
    }
}
