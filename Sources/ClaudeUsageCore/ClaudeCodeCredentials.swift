import Foundation

/// The OAuth sign-in Claude Code stores after `claude` login.
///
/// On macOS it lives in the login Keychain as the generic password
/// `Claude Code-credentials`; on other systems in `~/.claude/.credentials.json`.
/// Both hold the same JSON:
///
/// ```json
/// { "claudeAiOauth": { "accessToken": "sk-ant-oat01-…", "refreshToken": "…",
///                      "expiresAt": 1767225600000, "scopes": ["user:inference", "user:profile"],
///                      "subscriptionType": "max" } }
/// ```
public struct ClaudeCodeCredentials: Equatable, Sendable {
    public let accessToken: String
    public let expiresAt: Date?
    public let subscriptionType: String?
    public let scopes: [String]

    public init(accessToken: String, expiresAt: Date?, subscriptionType: String?, scopes: [String]) {
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.subscriptionType = subscriptionType
        self.scopes = scopes
    }

    public func isExpired(at now: Date = Date(), leeway: TimeInterval = 30) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= leeway
    }

    /// The plan name to show next to the meters, e.g. "Max".
    public var planName: String? { PlanName.from(subscriptionType: subscriptionType) }

    public static func parse(_ data: Data) throws -> ClaudeCodeCredentials {
        let json: [String: Any]
        do {
            json = try JSONValue.parseObject(data)
        } catch {
            throw UsageError.credentialsUnavailable("The stored credentials are not valid JSON.")
        }
        // Current Claude Code nests the sign-in under `claudeAiOauth`; accept a bare object too.
        let oauth = JSONValue.object(json["claudeAiOauth"]) ?? json
        guard let token = JSONValue.string(oauth["accessToken"]) ?? JSONValue.string(oauth["access_token"]) else {
            throw UsageError.notSignedIn
        }
        let expiry = JSONValue.number(oauth["expiresAt"]) ?? JSONValue.number(oauth["expires_at"])
        return ClaudeCodeCredentials(
            accessToken: token,
            expiresAt: expiry.map(Date.init(unixTimestamp:)),
            subscriptionType: JSONValue.string(oauth["subscriptionType"]),
            scopes: (oauth["scopes"] as? [String]) ?? []
        )
    }
}

public enum PlanName {
    public static func from(subscriptionType: String?) -> String? {
        guard var raw = subscriptionType?.lowercased(), !raw.isEmpty else { return nil }
        if raw.hasPrefix("claude_") { raw.removeFirst("claude_".count) }
        switch raw {
        case "pro": return "Pro"
        case "max": return "Max"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "free": return "Free"
        default: return raw.prefix(1).uppercased() + raw.dropFirst()
        }
    }

    /// Plan name from a claude.ai organization's `capabilities` list.
    public static func from(capabilities: [String]) -> String? {
        if capabilities.contains("claude_max") { return "Max" }
        if capabilities.contains("claude_pro") { return "Pro" }
        return nil
    }
}

/// Reads Claude Code's credentials without modifying them.
///
/// This app never refreshes or rewrites the token: Claude Code owns it, and refreshing it
/// here would rotate the refresh token underneath Claude Code.
public struct ClaudeCodeCredentialsLoader: Sendable {
    /// Keychain item to read on macOS; nil skips the Keychain and only reads `credentialFiles`.
    public var keychainService: String?
    public var credentialFiles: [URL]
    public var keychainTimeout: TimeInterval

    public init(
        keychainService: String? = "Claude Code-credentials",
        credentialFiles: [URL]? = nil,
        keychainTimeout: TimeInterval = 90
    ) {
        self.keychainService = keychainService
        self.keychainTimeout = keychainTimeout
        if let credentialFiles {
            self.credentialFiles = credentialFiles
        } else {
            var directories: [URL] = []
            if let configDir = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !configDir.isEmpty {
                directories.append(URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath))
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            directories.append(home.appendingPathComponent(".claude"))
            directories.append(home.appendingPathComponent(".config/claude"))
            self.credentialFiles = directories.map { $0.appendingPathComponent(".credentials.json") }
        }
    }

    /// Blocking: may wait for the user to answer a Keychain prompt. Call off the main thread.
    public func load() throws -> ClaudeCodeCredentials {
        var keychainError: UsageError?
        #if os(macOS)
        if let keychainService {
            do {
                if let data = try readKeychain(service: keychainService) {
                    return try ClaudeCodeCredentials.parse(data)
                }
            } catch let error as UsageError {
                keychainError = error
            }
        }
        #endif

        for file in credentialFiles {
            guard let data = try? Data(contentsOf: file) else { continue }
            return try ClaudeCodeCredentials.parse(data)
        }
        throw keychainError ?? UsageError.notSignedIn
    }

    #if os(macOS)
    /// Uses `/usr/bin/security`, the same tool Claude Code uses to write the item, so the
    /// Keychain's access list usually lets it read without prompting.
    private func readKeychain(service: String) throws -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", service, "-w"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            throw UsageError.credentialsUnavailable("Couldn't run the security tool (\(error.localizedDescription)).")
        }
        if finished.wait(timeout: .now() + keychainTimeout) == .timedOut {
            process.terminate()
            throw UsageError.credentialsUnavailable("Timed out waiting for Keychain access.")
        }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        switch process.terminationStatus {
        case 0:
            let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : Data(text.utf8)
        case 44:
            // errSecItemNotFound
            return nil
        default:
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UsageError.credentialsUnavailable(
                message.isEmpty ? "Keychain access was denied." : message
            )
        }
    }
    #endif
}
