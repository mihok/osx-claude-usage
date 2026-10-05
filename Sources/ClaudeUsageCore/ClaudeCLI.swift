import Foundation

/// Asks the installed Claude Code CLI for its `/usage` report.
///
/// Claude Code fetches the numbers with its own sign-in and renews that sign-in itself when it
/// has expired, so Claude Code doesn't need to be open and this app never handles a token.
/// `/usage` runs locally inside Claude Code: no message is sent to a model.
public struct ClaudeCLI: Sendable {
    public let executable: URL
    public var environment: [String: String]
    public var workingDirectory: URL?
    public var timeout: TimeInterval

    public init(
        executable: URL,
        environment: [String: String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 90
    ) {
        self.executable = executable
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    /// `--safe-mode` keeps the user's hooks, plugins and MCP servers from starting on every check,
    /// and `--no-session-persistence` keeps these runs out of the session history.
    /// Both are dropped if the installed Claude Code is too old to know them.
    static let usageArguments = [
        "-p", "/usage",
        "--output-format", "stream-json", "--verbose",
        "--no-session-persistence",
        "--safe-mode",
    ]
    static let optionalArguments: Set<String> = ["--no-session-persistence", "--safe-mode"]

    /// Blocking: runs Claude Code. Call off the main thread.
    public func fetchUsage(now: Date = Date()) throws -> UsageSnapshot {
        var arguments = Self.usageArguments
        while true {
            let result = try run(arguments)
            if result.status != 0,
               let option = Self.unknownOption(in: result.stderrText + result.stdoutText),
               Self.optionalArguments.contains(option),
               arguments.contains(option) {
                arguments.removeAll { $0 == option }
                continue
            }
            return try ClaudeUsageReport.snapshot(
                fromStreamJSON: result.stdoutText,
                stderr: result.stderrText,
                fetchedAt: now
            )
        }
    }

    /// Blocking: `claude auth status`, which only reads local state.
    public func authStatus() throws -> ClaudeAuthStatus {
        let result = try run(["auth", "status", "--json"])
        return try ClaudeAuthStatus.parse(result.stdoutText)
    }

    private func run(_ arguments: [String]) throws -> ProcessResult {
        let result: ProcessResult
        do {
            result = try ProcessRunner.run(
                executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: workingDirectory,
                timeout: timeout
            )
        } catch {
            throw UsageError.cliFailed("Couldn't start Claude Code at \(executable.path) (\(error.localizedDescription)).")
        }
        if result.timedOut {
            throw UsageError.cliFailed("Claude Code didn't answer within \(Int(timeout)) seconds.")
        }
        return result
    }

    /// The option named in a "unknown option '--x'" error from an older Claude Code.
    static func unknownOption(in output: String) -> String? {
        guard let range = output.range(of: "unknown option '") else { return nil }
        let rest = output[range.upperBound...]
        guard let end = rest.firstIndex(of: "'") else { return nil }
        return String(rest[..<end])
    }

    // MARK: - Finding Claude Code

    /// Finds Claude Code and prepares to run it the way Terminal would.
    /// Blocking (may ask the login shell for its PATH once); call off the main thread.
    /// - Parameters:
    ///   - customPath: The location chosen in Settings, or empty to search.
    ///   - shell: The user's login shell, used to learn the PATH Terminal sees.
    public static func resolve(
        customPath: String?,
        shell: String?,
        workingDirectory: URL?,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ClaudeCLI {
        let loginPath = shell.flatMap { LoginShellPath.cached(for: $0) }
        let searchPath = [loginPath, baseEnvironment["PATH"]].compactMap { $0 }.joined(separator: ":")
        guard let executable = locate(customPath: customPath, searchPath: searchPath) else {
            let custom = customPath?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw UsageError.cliNotFound(customPath: custom?.isEmpty == false ? custom : nil)
        }
        return ClaudeCLI(
            executable: executable,
            environment: environment(base: baseEnvironment, loginShellPath: loginPath, executable: executable),
            workingDirectory: workingDirectory
        )
    }

    /// Where `claude` is usually installed. Apps started from Finder don't inherit the shell's
    /// PATH, so these are checked explicitly.
    public static func commonLocations(home: URL) -> [URL] {
        [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent(".npm-global/bin/claude"),
            home.appendingPathComponent(".bun/bin/claude"),
            home.appendingPathComponent(".volta/bin/claude"),
            URL(fileURLWithPath: "/usr/bin/claude"),
        ]
    }

    /// Finds the `claude` executable: the user's chosen path, then PATH, then common locations.
    /// Returns nil if a chosen path doesn't point at an executable.
    public static func locate(
        customPath: String?,
        searchPath: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        if let customPath = customPath?.trimmingCharacters(in: .whitespacesAndNewlines), !customPath.isEmpty {
            let url = URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath)
            return fileManager.isExecutableFile(atPath: url.path) ? url : nil
        }
        let pathDirectories = (searchPath ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("claude")
        }
        return (pathDirectories + commonLocations(home: home)).first {
            fileManager.isExecutableFile(atPath: $0.path)
        }
    }

    /// The PATH a login shell sets up, so Claude Code (and Node, for npm installs) resolve the
    /// same way they do in Terminal. Blocking; nil if the shell doesn't answer.
    public static func loginShellPath(shell: String) -> String? {
        let marker = "__CLAUDE_USAGE_PATH__"
        guard let result = try? ProcessRunner.run(
            URL(fileURLWithPath: shell),
            arguments: ["-l", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""],
            timeout: 10
        ), !result.timedOut else { return nil }
        // Profile scripts can print their own output; take only what sits between the markers.
        let parts = result.stdoutText.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        var path = parts[parts.count - 2].trimmingCharacters(in: .whitespacesAndNewlines)
        // fish prints its PATH list space-separated.
        if !path.contains(":"), path.contains(" ") {
            path = path.replacingOccurrences(of: " ", with: ":")
        }
        return path.isEmpty ? nil : path
    }

    /// The environment Claude Code runs with: the app's own, with a PATH covering the login
    /// shell's directories, Claude Code's own directory and the usual install locations.
    public static func environment(
        base: [String: String],
        loginShellPath: String?,
        executable: URL
    ) -> [String: String] {
        var directories: [String] = [executable.deletingLastPathComponent().path]
        for path in [loginShellPath, base["PATH"]] {
            directories += (path ?? "").split(separator: ":").map(String.init)
        }
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        let unique = directories.filter { !$0.isEmpty && seen.insert($0).inserted }

        var environment = base
        environment["PATH"] = unique.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        return environment
    }
}

/// Remembers each login shell's PATH; asking the shell takes a moment.
private enum LoginShellPath {
    private static let lock = NSLock()
    private static var paths: [String: String?] = [:]

    static func cached(for shell: String) -> String? {
        lock.lock()
        if let known = paths[shell] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let path = ClaudeCLI.loginShellPath(shell: shell)
        lock.lock()
        paths[shell] = path
        lock.unlock()
        return path
    }
}

/// The parts of `claude auth status --json` the app uses.
public struct ClaudeAuthStatus: Equatable, Sendable {
    public let loggedIn: Bool
    public let authMethod: String?
    public let subscriptionType: String?

    public var planName: String? { PlanName.from(subscriptionType: subscriptionType) }

    public static func parse(_ output: String) throws -> ClaudeAuthStatus {
        // Take the JSON object even if something else was printed around it.
        guard let start = output.firstIndex(of: "{"), let end = output.lastIndex(of: "}") else {
            throw UsageError.invalidResponse("`claude auth status` printed no JSON.")
        }
        let json = try JSONValue.parseObject(Data(output[start...end].utf8))
        return ClaudeAuthStatus(
            loggedIn: JSONValue.bool(json["loggedIn"]) ?? false,
            authMethod: JSONValue.string(json["authMethod"]),
            subscriptionType: JSONValue.string(json["subscriptionType"])
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
}
