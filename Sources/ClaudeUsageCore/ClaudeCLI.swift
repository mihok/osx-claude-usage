import Foundation

/// Asks the installed Claude Code CLI for its `/usage` report.
///
/// Claude Code fetches the numbers with its own sign-in and renews that sign-in itself when it
/// has expired, so Claude Code doesn't need to be open and this app never handles a token.
/// `/usage` runs locally inside Claude Code: no message is sent to a model.
public struct ClaudeCLI: Sendable {
    public let executable: URL
    /// The version `claude --version` reported, e.g. "2.1.303".
    public let version: String?
    /// Whether `environment` came from the user's login shell, as in Terminal.
    public let usesLoginShellEnvironment: Bool
    /// Sign-in variables the shell sets that were left out of `environment`. Names only.
    public let removedCredentialVariables: [String]
    /// What `claude` is in the login shell, e.g. an alias.
    public let shellCommand: ShellCommandKind?
    public var environment: [String: String]
    public var workingDirectory: URL?
    public var timeout: TimeInterval

    public init(
        executable: URL,
        version: String? = nil,
        usesLoginShellEnvironment: Bool = false,
        removedCredentialVariables: [String] = [],
        shellCommand: ShellCommandKind? = nil,
        environment: [String: String],
        workingDirectory: URL? = nil,
        timeout: TimeInterval = 90
    ) {
        self.executable = executable
        self.version = version
        self.usesLoginShellEnvironment = usesLoginShellEnvironment
        self.removedCredentialVariables = removedCredentialVariables
        self.shellCommand = shellCommand
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.timeout = timeout
    }

    /// `--safe-mode` keeps the user's hooks, plugins and MCP servers from starting on every check,
    /// and `--no-session-persistence` keeps these runs out of the session history. A Claude Code
    /// too old to know them is reported as such rather than run without them.
    static let usageArguments = [
        "-p", "/usage",
        "--output-format", "stream-json", "--verbose",
        "--no-session-persistence",
        "--safe-mode",
    ]

    /// Blocking: runs Claude Code. Call off the main thread.
    /// - Parameter record: Receives Claude Code's raw output, for diagnostics.
    public func fetchUsage(now: Date = Date(), record: ((ProcessResult) -> Void)? = nil) throws -> UsageSnapshot {
        let result = try run(Self.usageArguments)
        record?(result)
        if result.status != 0, Self.unknownOption(in: result.stderrText + result.stdoutText) != nil {
            throw UsageError.cliTooOld(version)
        }
        return try ClaudeUsageReport.snapshot(
            fromStreamJSON: result.stdoutText,
            stderr: result.stderrText,
            fetchedAt: now
        )
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
    /// Blocking (asks the login shell for its environment once); call off the main thread.
    /// - Parameters:
    ///   - customPath: The location chosen in Settings, or empty to search.
    ///   - shell: The user's login shell, whose environment Terminal sessions see.
    public static func resolve(
        customPath: String?,
        shell: String?,
        workingDirectory: URL?,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> ClaudeCLI {
        let loginShell = shell.flatMap { ShellEnvironment.cached(for: $0) }
        let shellEnvironment = loginShell?.environment
        let base = shellEnvironment ?? baseEnvironment
        let searchPath = [shellEnvironment?["PATH"], baseEnvironment["PATH"]]
            .compactMap { $0 }
            .joined(separator: ":")

        let custom = customPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidates = locateAll(customPath: custom, searchPath: searchPath, home: home)
        guard !candidates.isEmpty else {
            throw UsageError.cliNotFound(customPath: custom.isEmpty ? nil : custom)
        }

        // Probe versions with the same environment the real run uses.
        let probeEnvironment = environment(base: base, executable: candidates[0])
        let versioned = candidates.map { ($0, ClaudeVersion.cached(for: $0, environment: probeEnvironment)) }
        // An old install left elsewhere on the PATH shouldn't shadow the one that updates itself.
        let chosen = versioned.max { lhs, rhs in
            ClaudeVersion.isOlder(lhs.1, than: rhs.1)
        } ?? versioned[0]

        return ClaudeCLI(
            executable: chosen.0,
            version: chosen.1,
            usesLoginShellEnvironment: shellEnvironment != nil,
            removedCredentialVariables: credentialVariables.filter { !(base[$0] ?? "").isEmpty },
            shellCommand: loginShell?.claudeCommand,
            environment: environment(base: base, executable: chosen.0),
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

    /// Every `claude` executable worth considering, in PATH order: just the chosen path if there is
    /// one (empty if it isn't executable), otherwise PATH and then the common locations, with
    /// links to the same file listed once.
    public static func locateAll(
        customPath: String?,
        searchPath: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> [URL] {
        if let customPath = customPath?.trimmingCharacters(in: .whitespacesAndNewlines), !customPath.isEmpty {
            let url = URL(fileURLWithPath: (customPath as NSString).expandingTildeInPath)
            return fileManager.isExecutableFile(atPath: url.path) ? [url] : []
        }
        let pathCandidates = (searchPath ?? "").split(separator: ":").map {
            URL(fileURLWithPath: String($0)).appendingPathComponent("claude")
        }
        var seen = Set<String>()
        return (pathCandidates + commonLocations(home: home)).filter { url in
            guard fileManager.isExecutableFile(atPath: url.path) else { return false }
            return seen.insert(url.resolvingSymlinksInPath().path).inserted
        }
    }

    /// The first `claude` found, without comparing versions.
    public static func locate(
        customPath: String?,
        searchPath: String?,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> URL? {
        locateAll(customPath: customPath, searchPath: searchPath, home: home, fileManager: fileManager).first
    }

    /// What an interactive login shell sets up: the environment `claude` sees when run in
    /// Terminal, including anything set in `.zshrc` such as `CLAUDE_CONFIG_DIR` or PATH additions,
    /// and what `claude` itself is there. Blocking; nil if the shell doesn't answer.
    public static func loginShell(_ shell: String) -> LoginShell? {
        let marker = "__CLAUDE_USAGE_ENV__"
        guard let result = try? ProcessRunner.run(
            URL(fileURLWithPath: shell),
            arguments: ["-i", "-l", "-c", "printf '\(marker)'; /usr/bin/env -0; printf '\(marker)'; type claude; printf '\(marker)'"],
            timeout: 15
        ), !result.timedOut else { return nil }
        // Profile scripts can print their own output; take only what sits between the markers.
        let parts = result.stdoutText.components(separatedBy: marker)
        guard parts.count >= 3, let environment = parseEnvironment(parts[1]) else { return nil }
        return LoginShell(
            environment: environment,
            claudeCommand: parts.count >= 4 ? ShellCommandKind.parse(typeOutput: parts[2]) : nil
        )
    }

    /// Parses `env -0` output (NUL-separated `NAME=value` entries), or plain `env` output if the
    /// entries turn out to be newline-separated. Nil unless it looks like a real environment.
    static func parseEnvironment(_ output: String) -> [String: String]? {
        let separator: Character = output.contains("\0") ? "\0" : "\n"
        var environment: [String: String] = [:]
        for entry in output.split(separator: separator) {
            guard let equals = entry.firstIndex(of: "="), equals != entry.startIndex else { continue }
            let name = String(entry[..<equals]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.allSatisfy({ $0 == "_" || ($0.isASCII && ($0.isLetter || $0.isNumber)) }) else {
                continue
            }
            environment[name] = String(entry[entry.index(after: equals)...])
        }
        guard environment["HOME"] != nil, environment["PATH"] != nil else { return nil }
        return environment
    }

    /// Variables that sign Claude Code in with an API key or token instead of the user's Claude
    /// account. Neither can report a plan's usage, and a key would be billed.
    public static let credentialVariables = ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN"]

    /// The sign-in variables, and those that only describe the shell the environment was captured from.
    static let removedVariables = Set(credentialVariables).union(["PWD", "OLDPWD", "SHLVL", "_"])

    /// The environment Claude Code runs with: `base` (normally the login shell's) without API keys,
    /// with a PATH covering Claude Code's own directory and the usual install locations.
    public static func environment(base: [String: String], executable: URL) -> [String: String] {
        var directories: [String] = [executable.deletingLastPathComponent().path]
        directories += (base["PATH"] ?? "").split(separator: ":").map(String.init)
        directories += ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        var seen = Set<String>()
        let unique = directories.filter { !$0.isEmpty && seen.insert($0).inserted }

        var environment = base.filter { !removedVariables.contains($0.key) }
        environment["PATH"] = unique.joined(separator: ":")
        environment["NO_COLOR"] = "1"
        return environment
    }
}

/// How the user's login shell runs `claude`.
public struct LoginShell: Equatable, Sendable {
    public var environment: [String: String]
    /// What `claude` is there, from `type claude`.
    public var claudeCommand: ShellCommandKind?

    public init(environment: [String: String], claudeCommand: ShellCommandKind? = nil) {
        self.environment = environment
        self.claudeCommand = claudeCommand
    }
}

/// What `claude` is in a shell. An alias or function can run Claude Code with other settings than
/// the app uses. Only the kind is kept, never the alias or function itself: it may hold a key.
public enum ShellCommandKind: Equatable, Sendable, CustomStringConvertible {
    case alias
    case function
    case file(String)
    case notFound

    /// Reads `type claude` as zsh, bash or fish print it.
    static func parse(typeOutput: String) -> ShellCommandKind? {
        let line = typeOutput
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let prefix = "claude is "
        guard line.hasPrefix(prefix) else {
            let lowered = line.lowercased()
            return lowered.contains("not found") || lowered.contains("could not find") ? .notFound : nil
        }
        let rest = line.dropFirst(prefix.count)
        if rest.hasPrefix("an alias") || rest.hasPrefix("aliased") { return .alias }
        if rest.contains("function") { return .function }
        if rest.hasPrefix("hashed ("), let end = rest.lastIndex(of: ")") {
            return .file(String(rest[rest.index(rest.startIndex, offsetBy: "hashed (".count)..<end]))
        }
        if rest.hasPrefix("/") { return .file(String(rest)) }
        return nil
    }

    /// "an alias", "~/.local/bin/claude".
    public var description: String {
        switch self {
        case .alias: return "an alias"
        case .function: return "a shell function"
        case let .file(path): return ClaudeDiagnostics.abbreviatingHome(in: path)
        case .notFound: return "not found"
        }
    }
}

/// Remembers each login shell's setup; starting an interactive shell takes a moment.
private enum ShellEnvironment {
    private static let lock = NSLock()
    private static var shells: [String: LoginShell?] = [:]

    static func cached(for shell: String) -> LoginShell? {
        lock.lock()
        if let known = shells[shell] {
            lock.unlock()
            return known
        }
        lock.unlock()
        let loginShell = ClaudeCLI.loginShell(shell)
        lock.lock()
        shells[shell] = loginShell
        lock.unlock()
        return loginShell
    }
}

/// `claude --version`, remembered per executable until the file changes (Claude Code updates
/// itself in place).
enum ClaudeVersion {
    private static let lock = NSLock()
    private static var versions: [String: (modified: Date?, version: String?)] = [:]

    static func cached(for executable: URL, environment: [String: String]) -> String? {
        let resolved = executable.resolvingSymlinksInPath().path
        let modified = (try? FileManager.default.attributesOfItem(atPath: resolved))?[.modificationDate] as? Date
        lock.lock()
        if let known = versions[resolved], known.modified == modified {
            lock.unlock()
            return known.version
        }
        lock.unlock()
        let version = probe(executable, environment: environment)
        lock.lock()
        versions[resolved] = (modified, version)
        lock.unlock()
        return version
    }

    static func probe(_ executable: URL, environment: [String: String]) -> String? {
        guard let result = try? ProcessRunner.run(
            executable, arguments: ["--version"], environment: environment, timeout: 20
        ), !result.timedOut, result.status == 0 else { return nil }
        return parse(result.stdoutText)
    }

    /// "2.1.303 (Claude Code)" → "2.1.303".
    static func parse(_ output: String) -> String? {
        for word in output.split(whereSeparator: { $0 == " " || $0.isNewline }) {
            let parts = word.split(separator: ".")
            if parts.count >= 2, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) {
                return String(word)
            }
        }
        return nil
    }

    /// Compares dotted versions numerically; an unknown version counts as oldest.
    static func isOlder(_ lhs: String?, than rhs: String?) -> Bool {
        guard let rhs else { return false }
        guard let lhs else { return true }
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r { return l < r }
        }
        return false
    }
}

/// The parts of `claude auth status --json` the app uses. The email address and organization it
/// also prints are left out.
public struct ClaudeAuthStatus: Equatable, Sendable {
    public let loggedIn: Bool
    public let authMethod: String?
    public let subscriptionType: String?
    /// The folder Claude Code keeps its settings in, e.g. ~/.claude.
    public let configDirectory: String?
    /// "firstParty", "bedrock", …
    public let apiProvider: String?
    /// Where an API key came from, by name, e.g. "apiKeyHelper".
    public let apiKeySource: String?

    public init(
        loggedIn: Bool,
        authMethod: String?,
        subscriptionType: String?,
        configDirectory: String? = nil,
        apiProvider: String? = nil,
        apiKeySource: String? = nil
    ) {
        self.loggedIn = loggedIn
        self.authMethod = authMethod
        self.subscriptionType = subscriptionType
        self.configDirectory = configDirectory
        self.apiProvider = apiProvider
        self.apiKeySource = apiKeySource
    }

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
            subscriptionType: JSONValue.string(json["subscriptionType"]),
            configDirectory: JSONValue.string(json["configDirectory"]),
            apiProvider: JSONValue.string(json["apiProvider"]),
            apiKeySource: JSONValue.string(json["apiKeySource"])
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
