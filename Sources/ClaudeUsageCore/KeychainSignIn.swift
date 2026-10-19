import Foundation

/// Whether the login Keychain holds the sign-in that `claude auth login` saves.
///
/// Only the entry's presence is checked, with `security find-generic-password` and without `-w`:
/// its contents, the token, are never read. Used to explain why Claude Code isn't signed in.
public enum KeychainSignIn: Equatable, Sendable, CustomStringConvertible {
    case found
    case missing
    /// `security` failed, e.g. with 36 when the keychain is locked; nil if it didn't finish.
    case unknown(Int32?)

    public var description: String {
        switch self {
        case .found: return "found"
        case .missing: return "not found"
        case let .unknown(status): return "couldn't check" + (status.map { " (security exited \($0))" } ?? "")
        }
    }

    /// The Keychain entry Claude Code keeps its sign-in in, given the environment it runs with.
    /// Nil when it's named after a custom settings folder (`CLAUDE_CONFIG_DIR`).
    static func service(environment: [String: String]) -> String? {
        let defaultName = environment["CLAUDE_SECURESTORAGE_CONFIG_DIR"].map(\.isEmpty)
            ?? (environment["CLAUDE_CONFIG_DIR"] ?? "").isEmpty
        return defaultName ? "Claude Code-credentials" : nil
    }

    /// The account name Claude Code files its sign-in under.
    static func account(environment: [String: String], userName: String = NSUserName()) -> String {
        let name = environment["USER"].flatMap { $0.isEmpty ? nil : $0 } ?? userName
        let allowed = name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        return allowed && !name.isEmpty ? name : "claude-code-user"
    }
}

extension ClaudeCLI {
    /// Blocking. Nil where it can't be checked: without `security` (not macOS), or when a custom
    /// settings folder changes the entry's name.
    public func keychainSignIn(security: URL = URL(fileURLWithPath: "/usr/bin/security")) -> KeychainSignIn? {
        guard let service = KeychainSignIn.service(environment: environment),
              FileManager.default.isExecutableFile(atPath: security.path) else { return nil }
        let account = KeychainSignIn.account(environment: environment)
        guard let result = try? ProcessRunner.run(
            security,
            arguments: ["find-generic-password", "-a", account, "-s", service],
            timeout: 10
        ), !result.timedOut else { return .unknown(nil) }
        switch result.status {
        case 0: return .found
        case 44: return .missing // errSecItemNotFound
        default: return .unknown(result.status)
        }
    }
}
