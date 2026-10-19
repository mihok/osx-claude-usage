import XCTest
@testable import ClaudeUsageCore

/// A `claude -p /usage --output-format stream-json --verbose` run, trimmed to the lines that matter.
private let streamJSON = """
{"type":"system","subtype":"init","session_id":"abc","tools":[],"model":"claude-opus-5-5"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"You are currently using your subscription to power your Claude Code usage\\n\\nCurrent session: 23% used · resets 3:14pm"}]},"usage_report":{"session":{"total_cost_usd":0,"total_api_duration_ms":0,"total_duration_ms":12,"total_lines_added":0,"total_lines_removed":0,"model_usage":{}},"rate_limits":{"limits":[{"kind":"session","group":"session","percent":23,"resets_at":"2026-10-04T15:14:00.364238+00:00","severity":"normal","is_active":true},{"kind":"weekly_all","group":"weekly","percent":71.4,"resets_at":"2026-10-07T09:00:00Z","severity":"warning","is_active":false},{"kind":"weekly_scoped","group":"weekly","percent":94,"resets_at":"2026-10-07T09:00:00Z","scope":{"model":{"display_name":"Sonnet"}},"severity":"critical","is_active":false},{"kind":"weekly_scoped","group":"weekly","percent":8,"resets_at":"2026-10-07T09:00:00Z","scope":{"model":{"display_name":"Claude Fable"}},"severity":"normal","is_active":false},{"kind":"weekly_scoped","group":"weekly","percent":0,"resets_at":null,"scope":{"model":{"display_name":"Opus"}},"severity":"normal","is_active":false}],"extra_usage":{"is_enabled":true,"monthly_limit":5000,"used_credits":1250,"utilization":null,"currency":"USD"}}}}
{"type":"result","subtype":"success","is_error":false,"result":"You are currently using your subscription to power your Claude Code usage\\n\\nCurrent session: 23% used · resets 3:14pm","session_id":"abc"}
"""

final class ClaudeUsageReportTests: XCTestCase {
    func testParsesStructuredReport() throws {
        let snapshot = try ClaudeUsageReport.snapshot(fromStreamJSON: streamJSON, fetchedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(
            snapshot.meters.map(\.id),
            ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet", "seven_day_fable", "extra_usage"]
        )

        let session = try XCTUnwrap(snapshot.meter(id: MeterID.session))
        XCTAssertEqual(session.title, "Session")
        XCTAssertEqual(session.glyph, "5")
        XCTAssertEqual(session.percent, 23)
        XCTAssertEqual(try XCTUnwrap(session.resetsAt).timeIntervalSince1970, 1_791_126_840.364238, accuracy: 0.001)

        let weekly = try XCTUnwrap(snapshot.meter(id: MeterID.weekly))
        XCTAssertEqual(weekly.glyph, "W")
        XCTAssertEqual(weekly.percent, 71.4)
        // Claude's own severity wins over the local thresholds.
        XCTAssertEqual(weekly.level, .elevated)

        let sonnet = try XCTUnwrap(snapshot.meter(id: MeterID.weeklySonnet))
        XCTAssertEqual(sonnet.title, "Weekly · Sonnet")
        XCTAssertEqual(sonnet.level, .critical)

        let fable = try XCTUnwrap(snapshot.meter(id: "seven_day_fable"))
        XCTAssertEqual(fable.title, "Weekly · Fable")
        XCTAssertEqual(fable.glyph, "F")

        // Idle per-model limits are reported but not shown.
        XCTAssertFalse(try XCTUnwrap(snapshot.meter(id: MeterID.weeklyOpus)).isRelevant)

        let extra = try XCTUnwrap(snapshot.meter(id: MeterID.extraUsage))
        XCTAssertEqual(extra.percent, 25)
    }

    func testSeverityOverridesThresholds() throws {
        let line = #"{"usage_report":{"rate_limits":{"limits":[{"kind":"session","group":"session","percent":40,"resets_at":null,"severity":"critical"}]}}}"#
        let snapshot = try ClaudeUsageReport.snapshot(fromStreamJSON: line)
        XCTAssertEqual(snapshot.meter(id: MeterID.session)?.level, .critical)

        let unknown = #"{"usage_report":{"rate_limits":{"limits":[{"kind":"session","group":"session","percent":95,"resets_at":null,"severity":"mystery"}]}}}"#
        XCTAssertEqual(try ClaudeUsageReport.snapshot(fromStreamJSON: unknown).meter(id: MeterID.session)?.level, .critical)
    }

    func testUnknownKindsAndSurfaces() throws {
        let line = #"{"usage_report":{"rate_limits":{"limits":["#
            + #"{"kind":"weekly_scoped","group":"weekly","percent":12,"resets_at":null,"scope":{"surface":{"display_name":"Cowork"}},"severity":"normal"},"#
            + #"{"kind":"session_burst","group":"session","percent":3,"resets_at":null,"severity":"normal"},"#
            + #"{"kind":"weekly_all","group":"weekly","percent":50,"resets_at":null,"severity":"normal"},"#
            + #"{"kind":"weekly_all","group":"weekly","percent":99,"resets_at":null,"severity":"critical"}"#
            + #"]}}}"#
        let snapshot = try ClaudeUsageReport.snapshot(fromStreamJSON: line)
        XCTAssertEqual(snapshot.meter(id: "seven_day_cowork")?.title, "Weekly · Cowork")
        XCTAssertEqual(snapshot.meter(id: "five_hour_burst")?.title, "Session · Burst")
        // The first row of a kind wins.
        XCTAssertEqual(snapshot.meter(id: MeterID.weekly)?.percent, 50)
    }

    func testFallsBackToText() throws {
        let line = #"{"type":"result","is_error":false,"result":"You are currently using your subscription to power your Claude Code usage\n\nCurrent session: 23% used · resets 3:14pm (Europe/London)\nCurrent week (all models): 49% used · resets Oct 7, 9am\nCurrent week (Sonnet only): 3% used\nCurrent week (Claude Fable): 12% used"}"#
        let snapshot = try ClaudeUsageReport.snapshot(fromStreamJSON: line)
        XCTAssertEqual(snapshot.meters.map(\.id), ["five_hour", "seven_day", "seven_day_sonnet", "seven_day_fable"])
        XCTAssertEqual(snapshot.meter(id: MeterID.weekly)?.percent, 49)
        XCTAssertEqual(snapshot.meter(id: "seven_day_fable")?.title, "Weekly · Fable")
        XCTAssertNil(snapshot.meter(id: MeterID.session)?.resetsAt)
    }

    func testMissingRowsExplainWhy() {
        let unavailable = #"{"usage_report":{"rate_limits":null}}"# + "\n"
            + #"{"type":"result","result":"You are currently using your subscription to power your Claude Code usage\n\nUsage data is temporarily unavailable"}"#
        XCTAssertThrowsError(try ClaudeUsageReport.snapshot(fromStreamJSON: unavailable)) { error in
            XCTAssertEqual(error as? UsageError, .usageUnavailable("Usage data is temporarily unavailable"))
        }

        let signedOut = #"{"type":"result","is_error":true,"result":"Not logged in · Please run /login"}"#
        XCTAssertThrowsError(try ClaudeUsageReport.snapshot(fromStreamJSON: signedOut)) { error in
            XCTAssertEqual(error as? UsageError, .notSignedIn)
        }

        XCTAssertThrowsError(try ClaudeUsageReport.snapshot(fromStreamJSON: "", stderr: "boom")) { error in
            XCTAssertEqual(error as? UsageError, .usageUnavailable("boom"))
        }
    }

    func testSlugify() {
        XCTAssertEqual(UsageText.slugify("Fable"), "fable")
        XCTAssertEqual(UsageText.slugify("Claude Opus 5.5"), "claude_opus_5_5")
        XCTAssertEqual(UsageText.slugify("  --  "), "")
    }
}

final class ClaudeCLITests: XCTestCase {
    private static let environment = ["PATH": "/usr/bin:/bin"]
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeCLITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Writes an executable shell script standing in for `claude`.
    private func fakeClaude(_ body: String, in folder: String? = nil) throws -> URL {
        var parent: URL = directory
        if let folder {
            parent = directory.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let url = parent.appendingPathComponent("claude")
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    func testFetchUsageRunsClaudeAndParsesReport() throws {
        let output = directory.appendingPathComponent("output.jsonl")
        try Data(streamJSON.utf8).write(to: output)
        let arguments = directory.appendingPathComponent("arguments.txt")
        let claude = try fakeClaude("""
        echo "$@" >> '\(arguments.path)'
        cat '\(output.path)'
        """)

        let cli = ClaudeCLI(executable: claude, environment: Self.environment, timeout: 20)
        let snapshot = try cli.fetchUsage()

        XCTAssertEqual(snapshot.meter(id: MeterID.session)?.percent, 23)
        let invocation = try String(contentsOf: arguments, encoding: .utf8)
        XCTAssertEqual(
            invocation.trimmingCharacters(in: .whitespacesAndNewlines),
            "-p /usage --output-format stream-json --verbose --no-session-persistence --safe-mode"
        )
    }

    func testReportsAnOlderClaudeInsteadOfRetrying() throws {
        // Rerunning without the safety options could reach a Claude Code that sends /usage to a
        // model, so an unknown option ends the check.
        let calls = directory.appendingPathComponent("calls.txt")
        let claude = try fakeClaude("""
        echo run >> '\(calls.path)'
        echo "error: unknown option '--safe-mode'" >&2
        exit 1
        """)

        let cli = ClaudeCLI(executable: claude, version: "1.0.80", environment: Self.environment, timeout: 20)
        XCTAssertThrowsError(try cli.fetchUsage()) { error in
            XCTAssertEqual(error as? UsageError, .cliTooOld("1.0.80"))
        }
        XCTAssertEqual(try String(contentsOf: calls, encoding: .utf8), "run\n")
    }

    func testRecordsOutputForDiagnostics() throws {
        let claude = try fakeClaude(#"echo '{"type":"result","result":"Not logged in · Please run /login"}'; echo 'warning: something' >&2"#)
        var recorded: ProcessResult?
        XCTAssertThrowsError(try ClaudeCLI(executable: claude, environment: Self.environment, timeout: 20).fetchUsage {
            recorded = $0
        })
        let output = try XCTUnwrap(recorded)
        let summary = ClaudeUsageReport.summary(ofStreamJSON: output.stdoutText)
        XCTAssertEqual(summary, ClaudeUsageReport.Summary(text: "Not logged in · Please run /login", hasUsageReport: false, hasUsageRows: false))
        XCTAssertEqual(output.stderrText, "warning: something\n")
    }

    func testTimesOut() throws {
        let claude = try fakeClaude("sleep 30")
        let started = Date()
        XCTAssertThrowsError(try ClaudeCLI(executable: claude, environment: Self.environment, timeout: 1).fetchUsage()) { error in
            guard case UsageError.cliFailed = error else { return XCTFail("Unexpected error \(error)") }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testCapturesLargeOutput() throws {
        // More than a pipe buffer's worth of output must not deadlock the runner.
        let claude = try fakeClaude("""
        i=0
        while [ $i -lt 3000 ]; do
          echo '{"type":"system","subtype":"padding","text":"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"}'
          i=$((i + 1))
        done
        echo '{"usage_report":{"rate_limits":{"limits":[{"kind":"session","group":"session","percent":5,"resets_at":null,"severity":"normal"}]}}}'
        """)
        let snapshot = try ClaudeCLI(executable: claude, environment: Self.environment, timeout: 30).fetchUsage()
        XCTAssertEqual(snapshot.meter(id: MeterID.session)?.percent, 5)
    }

    func testAuthStatus() throws {
        let claude = try fakeClaude("""
        echo '{"loggedIn": true, "authMethod": "claude.ai", "apiProvider": "firstParty", "subscriptionType": "max"}'
        """)
        let status = try ClaudeCLI(executable: claude, environment: Self.environment, timeout: 20).authStatus()
        XCTAssertEqual(status, ClaudeAuthStatus(loggedIn: true, authMethod: "claude.ai", subscriptionType: "max", apiProvider: "firstParty"))
        XCTAssertEqual(status.planName, "Max")

        let signedOut = try ClaudeAuthStatus.parse(#"{"loggedIn":false,"authMethod":"none","apiProvider":"firstParty","configDirectory":"/Users/me/.claude","email":"me@example.com"}"#)
        XCTAssertEqual(signedOut.configDirectory, "/Users/me/.claude")
        XCTAssertNil(signedOut.apiKeySource)

        XCTAssertFalse(try ClaudeAuthStatus.parse(#"{"loggedIn":false,"authMethod":"none"}"#).loggedIn)
        XCTAssertThrowsError(try ClaudeAuthStatus.parse("command not found"))
    }

    func testLocatesClaude() throws {
        let claude = try fakeClaude("exit 0")
        let home = directory.appendingPathComponent("home")

        // A chosen path wins, and a wrong one is reported rather than replaced.
        XCTAssertEqual(ClaudeCLI.locate(customPath: claude.path, searchPath: nil, home: home)?.path, claude.path)
        XCTAssertNil(ClaudeCLI.locate(customPath: directory.appendingPathComponent("nope").path, searchPath: nil, home: home))

        // Otherwise PATH is searched.
        XCTAssertEqual(ClaudeCLI.locate(customPath: "", searchPath: "/nonexistent:\(directory.path)", home: home)?.path, claude.path)

        // Then the usual install locations, such as ~/.local/bin.
        let localBin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: claude, to: localBin.appendingPathComponent("claude"))
        XCTAssertEqual(
            ClaudeCLI.locate(customPath: nil, searchPath: "/nonexistent", home: home)?.path,
            localBin.appendingPathComponent("claude").path
        )
    }

    func testResolveReportsMissingClaude() {
        XCTAssertThrowsError(try ClaudeCLI.resolve(
            customPath: "/no/such/claude", shell: nil, workingDirectory: nil, baseEnvironment: [:]
        )) { error in
            XCTAssertEqual(error as? UsageError, .cliNotFound(customPath: "/no/such/claude"))
        }
    }

    func testResolvePrefersTheNewestClaude() throws {
        let old = try fakeClaude(#"[ "$1" = "--version" ] && echo "1.0.80 (Claude Code)""#, in: "old")
        let new = try fakeClaude(#"[ "$1" = "--version" ] && echo "999.0.0 (Claude Code)""#, in: "new")
        let home = directory.appendingPathComponent("home")
        let environment = [
            "PATH": "\(old.deletingLastPathComponent().path):\(new.deletingLastPathComponent().path):/usr/bin:/bin",
            "HOME": home.path,
            "ANTHROPIC_API_KEY": "sk-should-not-pass",
        ]

        let cli = try ClaudeCLI.resolve(
            customPath: nil, shell: nil, workingDirectory: nil, baseEnvironment: environment, home: home
        )
        XCTAssertEqual(cli.executable.path, new.path)
        XCTAssertEqual(cli.version, "999.0.0")
        XCTAssertFalse(cli.usesLoginShellEnvironment)
        XCTAssertNil(cli.environment["ANTHROPIC_API_KEY"])
        XCTAssertEqual(cli.removedCredentialVariables, ["ANTHROPIC_API_KEY"])

        // A chosen path is used as is, even when it's older.
        let chosen = try ClaudeCLI.resolve(
            customPath: old.path, shell: nil, workingDirectory: nil, baseEnvironment: environment, home: home
        )
        XCTAssertEqual(chosen.executable.path, old.path)
        XCTAssertEqual(chosen.version, "1.0.80")
    }

    func testVersions() {
        XCTAssertEqual(ClaudeVersion.parse("2.1.303 (Claude Code)\n"), "2.1.303")
        XCTAssertEqual(ClaudeVersion.parse("claude 1.0"), "1.0")
        XCTAssertNil(ClaudeVersion.parse("Claude Code"))
        XCTAssertTrue(ClaudeVersion.isOlder("2.1.99", than: "2.1.303"))
        XCTAssertFalse(ClaudeVersion.isOlder("2.10.0", than: "2.9.9"))
        XCTAssertFalse(ClaudeVersion.isOlder("2.1", than: "2.1.0"))
        XCTAssertTrue(ClaudeVersion.isOlder(nil, than: "1.0.0"))
        XCTAssertFalse(ClaudeVersion.isOlder("1.0.0", than: nil))
    }

    func testEnvironmentKeepsShellSetupButNotAPIKeys() {
        let environment = ClaudeCLI.environment(
            base: [
                "PATH": "/Users/me/.nvm/versions/node/v22/bin:/usr/bin:/bin",
                "HOME": "/Users/me",
                "CLAUDE_CONFIG_DIR": "/Users/me/.claude-work",
                "ANTHROPIC_API_KEY": "sk-ant-api",
                "ANTHROPIC_AUTH_TOKEN": "token",
                "CLAUDE_CODE_OAUTH_TOKEN": "oauth",
                "SHLVL": "2",
            ],
            executable: URL(fileURLWithPath: "/Users/me/.local/bin/claude")
        )
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        XCTAssertEqual(path.first, "/Users/me/.local/bin")
        XCTAssertTrue(path.contains("/Users/me/.nvm/versions/node/v22/bin"))
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertEqual(path.filter { $0 == "/usr/bin" }.count, 1)
        XCTAssertEqual(environment["HOME"], "/Users/me")
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/Users/me/.claude-work")
        XCTAssertEqual(environment["NO_COLOR"], "1")
        for removed in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "CLAUDE_CODE_OAUTH_TOKEN", "SHLVL"] {
            XCTAssertNil(environment[removed], removed)
        }
    }

    func testLoginShell() throws {
        // Stands in for `zsh -i -l -c …`: profile noise, `env -0` and `type claude` between markers.
        let shell = try fakeClaude(
            #"printf 'noise from a profile\n__CLAUDE_USAGE_ENV__HOME=/Users/me\0PATH=/opt/a:/opt/b\0CLAUDE_CONFIG_DIR=/Users/me/.claude-work\0MULTI=line1\nline2\0__CLAUDE_USAGE_ENV__claude is an alias for ANTHROPIC_API_KEY=sk-secret claude\n__CLAUDE_USAGE_ENV__bye from .zlogout\n'"#
        )
        let loginShell = try XCTUnwrap(ClaudeCLI.loginShell(shell.path))
        XCTAssertEqual(loginShell.environment["PATH"], "/opt/a:/opt/b")
        XCTAssertEqual(loginShell.environment["CLAUDE_CONFIG_DIR"], "/Users/me/.claude-work")
        XCTAssertEqual(loginShell.environment["MULTI"], "line1\nline2")
        XCTAssertEqual(loginShell.claudeCommand, .alias)

        // A shell that stops after the environment still gives it.
        let partial = try fakeClaude(#"printf '__CLAUDE_USAGE_ENV__HOME=/h\0PATH=/p\0__CLAUDE_USAGE_ENV__'"#)
        XCTAssertEqual(ClaudeCLI.loginShell(partial.path), LoginShell(environment: ["HOME": "/h", "PATH": "/p"]))

        XCTAssertNil(ClaudeCLI.loginShell(try fakeClaude("echo nothing useful").path))
    }

    func testShellCommandKind() {
        // zsh
        XCTAssertEqual(ShellCommandKind.parse(typeOutput: "claude is an alias for CLAUDE_CONFIG_DIR=~/.claude-work claude\n"), .alias)
        XCTAssertEqual(ShellCommandKind.parse(typeOutput: "claude is a shell function from /Users/me/.zshrc\n"), .function)
        XCTAssertEqual(ShellCommandKind.parse(typeOutput: "claude is /Users/me/.local/bin/claude\n"), .file("/Users/me/.local/bin/claude"))
        XCTAssertEqual(ShellCommandKind.parse(typeOutput: "claude not found\n"), .notFound)
        // bash
        XCTAssertEqual(ShellCommandKind.parse(typeOutput: "claude is aliased to `claude --model opus'\n"), .alias)
        XCTAssertEqual(ShellCommandKind.parse(typeOutput: "claude is a function\nclaude () \n{ \n    command claude \"$@\"\n}\n"), .function)
        XCTAssertEqual(ShellCommandKind.parse(typeOutput: "claude is hashed (/opt/homebrew/bin/claude)\n"), .file("/opt/homebrew/bin/claude"))
        // fish
        XCTAssertEqual(ShellCommandKind.parse(typeOutput: "claude is a function with definition\n# Defined in ~/.config/fish/config.fish\n"), .function)
        XCTAssertNil(ShellCommandKind.parse(typeOutput: ""))
        XCTAssertNil(ShellCommandKind.parse(typeOutput: "claude is a reserved word\n"))

        XCTAssertEqual(ShellCommandKind.alias.description, "an alias")
        XCTAssertEqual(ShellCommandKind.file("/opt/homebrew/bin/claude").description, "/opt/homebrew/bin/claude")
    }

    /// Writes a stand-in for `/usr/bin/security` that records its arguments and exits with `status`.
    private func fakeSecurity(exitingWith status: Int32) throws -> (tool: URL, arguments: URL) {
        let folder = directory.appendingPathComponent("security-\(status)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let arguments = folder.appendingPathComponent("arguments.txt")
        let tool = folder.appendingPathComponent("security")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$@\" > '\(arguments.path)'\necho 'keychain: \"/Users/me/Library/Keychains/login.keychain-db\"'\nexit \(status)\n".utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return (tool, arguments)
    }

    func testKeychainSignIn() throws {
        let claude = URL(fileURLWithPath: "/usr/local/bin/claude")
        let environment = ["PATH": "/usr/bin:/bin", "USER": "me"]

        let found = try fakeSecurity(exitingWith: 0)
        XCTAssertEqual(ClaudeCLI(executable: claude, environment: environment).keychainSignIn(security: found.tool), .found)
        // Asks only whether the entry exists: no -w or -g, which would print the token.
        XCTAssertEqual(
            try String(contentsOf: found.arguments, encoding: .utf8),
            "find-generic-password\n-a\nme\n-s\nClaude Code-credentials\n"
        )

        let missing = try fakeSecurity(exitingWith: 44)
        XCTAssertEqual(ClaudeCLI(executable: claude, environment: environment).keychainSignIn(security: missing.tool), .missing)
        let locked = try fakeSecurity(exitingWith: 36)
        XCTAssertEqual(ClaudeCLI(executable: claude, environment: environment).keychainSignIn(security: locked.tool), .unknown(36))

        // A custom settings folder changes the entry's name, so it isn't guessed.
        var custom = environment
        custom["CLAUDE_CONFIG_DIR"] = "/Users/me/.claude-work"
        XCTAssertNil(ClaudeCLI(executable: claude, environment: custom).keychainSignIn(security: found.tool))
        custom["CLAUDE_SECURESTORAGE_CONFIG_DIR"] = ""
        XCTAssertEqual(ClaudeCLI(executable: claude, environment: custom).keychainSignIn(security: found.tool), .found)

        XCTAssertNil(ClaudeCLI(executable: claude, environment: environment)
            .keychainSignIn(security: directory.appendingPathComponent("no-security")))
    }

    func testKeychainAccountName() {
        XCTAssertEqual(KeychainSignIn.account(environment: ["USER": "me"], userName: "other"), "me")
        XCTAssertEqual(KeychainSignIn.account(environment: [:], userName: "first.last"), "first.last")
        XCTAssertEqual(KeychainSignIn.account(environment: ["USER": "me & you"], userName: "x"), "claude-code-user")
        XCTAssertEqual(KeychainSignIn.unknown(36).description, "couldn't check (security exited 36)")
    }

    func testParseEnvironment() {
        XCTAssertEqual(ClaudeCLI.parseEnvironment("HOME=/h\nPATH=/p\nBAD LINE\n=x\n")?["PATH"], "/p")
        // Without HOME and PATH it isn't a usable environment.
        XCTAssertNil(ClaudeCLI.parseEnvironment("FOO=bar\0"))
    }

    func testUnknownOptionParsing() {
        XCTAssertEqual(ClaudeCLI.unknownOption(in: "error: unknown option '--safe-mode'\n"), "--safe-mode")
        XCTAssertNil(ClaudeCLI.unknownOption(in: "error: something else"))
    }
}

final class ClaudeDiagnosticsTests: XCTestCase {
    func testReport() {
        var diagnostics = ClaudeDiagnostics(checkedAt: Date(timeIntervalSince1970: 1_791_126_840))
        diagnostics.executable = NSHomeDirectory() + "/.local/bin/claude"
        diagnostics.version = "2.1.303"
        diagnostics.usedLoginShellEnvironment = true
        diagnostics.exitStatus = 0
        diagnostics.authStatus = ClaudeAuthStatus(loggedIn: false, authMethod: "none", subscriptionType: nil)
        diagnostics.summary = ClaudeUsageReport.Summary(text: "Total cost: $0.00", hasUsageReport: false, hasUsageRows: false)
        diagnostics.stderr = "\n"
        diagnostics.error = UsageError.notSignedIn.localizedDescription

        XCTAssertEqual(diagnostics.cliDescription, "claude 2.1.303 at ~/.local/bin/claude")
        XCTAssertFalse(diagnostics.report(appVersion: "1.0.0").contains("Keychain"))
        XCTAssertEqual(diagnostics.report(appVersion: "1.0.0"), """
        Claude Usage 1.0.0
        Checked: 2026-10-04T15:14:00Z
        Claude Code: claude 2.1.303 at ~/.local/bin/claude
        Environment: login shell (as in Terminal)
        Exit status: 0
        Signed in: no (none)
        Usage report: missing
        Error: Claude Code isn't signed in.

        Claude Code printed:
        Total cost: $0.00
        """)
    }

    func testReportsHowTerminalSignsIn() {
        var diagnostics = ClaudeDiagnostics(checkedAt: Date(timeIntervalSince1970: 1_791_126_840))
        diagnostics.executable = "/opt/homebrew/bin/claude"
        diagnostics.usedLoginShellEnvironment = true
        diagnostics.removedCredentialVariables = ["CLAUDE_CODE_OAUTH_TOKEN"]
        diagnostics.shellCommand = .alias
        diagnostics.authStatus = ClaudeAuthStatus(
            loggedIn: false, authMethod: "none", subscriptionType: nil,
            configDirectory: NSHomeDirectory() + "/.claude", apiProvider: "firstParty"
        )
        diagnostics.keychainSignIn = .missing

        XCTAssertEqual(diagnostics.report(appVersion: "1.0.1"), """
        Claude Usage 1.0.1
        Checked: 2026-10-04T15:14:00Z
        Claude Code: claude at /opt/homebrew/bin/claude
        Environment: login shell (as in Terminal)
        Sign-in variables left out: CLAUDE_CODE_OAUTH_TOKEN
        In Terminal, claude is: an alias
        Signed in: no (none)
        Settings folder: ~/.claude
        Keychain sign-in: not found
        """)

        diagnostics.removedCredentialVariables = []
        XCTAssertTrue(diagnostics.report(appVersion: "1.0.1").contains("Sign-in variables left out: none\n"))
    }

    func testAbbreviatesHome() {
        XCTAssertEqual(ClaudeDiagnostics.abbreviatingHome(in: "/Users/me/.local/bin/claude", home: "/Users/me"), "~/.local/bin/claude")
        XCTAssertEqual(ClaudeDiagnostics.abbreviatingHome(in: "/Users/meg/claude", home: "/Users/me"), "/Users/meg/claude")
        XCTAssertEqual(ClaudeDiagnostics.abbreviatingHome(in: "/opt/homebrew/bin/claude", home: "/Users/me"), "/opt/homebrew/bin/claude")
    }
}

final class SignInProblemTests: XCTestCase {
    func testPicksTheLikeliestReason() {
        XCTAssertEqual(
            UsageError.signInProblem(removedCredentialVariables: [], shellCommand: .file("/opt/homebrew/bin/claude"), keychain: .missing),
            .notSignedIn
        )
        XCTAssertEqual(
            UsageError.signInProblem(removedCredentialVariables: ["CLAUDE_CODE_OAUTH_TOKEN"], shellCommand: .alias, keychain: .missing),
            .signedInOnlyInTerminal(.variables(["CLAUDE_CODE_OAUTH_TOKEN"]))
        )
        XCTAssertEqual(
            UsageError.signInProblem(removedCredentialVariables: [], shellCommand: .function, keychain: nil),
            .signedInOnlyInTerminal(.wrapper(.function))
        )
        // A saved sign-in Claude Code couldn't read explains more than the shell's setup.
        XCTAssertEqual(
            UsageError.signInProblem(removedCredentialVariables: ["ANTHROPIC_API_KEY"], shellCommand: .alias, keychain: .found),
            .signedInOnlyInTerminal(.keychainUnreadable)
        )
        XCTAssertTrue(UsageError.signedInOnlyInTerminal(.keychainUnreadable).isLocal)
    }

    func testExplainsHowToSignIn() {
        let token = UsageError.signedInOnlyInTerminal(.variables(["CLAUDE_CODE_OAUTH_TOKEN"]))
        XCTAssertEqual(token.errorDescription, "In Terminal, Claude Code signs in with CLAUDE_CODE_OAUTH_TOKEN, which can't report plan usage.")
        XCTAssertEqual(
            token.recoverySuggestion,
            "Sign in once with your Claude account: run `env -u CLAUDE_CODE_OAUTH_TOKEN claude auth login` in Terminal. "
                + "CLAUDE_CODE_OAUTH_TOKEN stays set, so Terminal keeps working as before."
        )

        let both = UsageError.signedInOnlyInTerminal(.variables(["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"]))
        XCTAssertEqual(both.errorDescription, "In Terminal, Claude Code signs in with ANTHROPIC_API_KEY and CLAUDE_CODE_OAUTH_TOKEN, which can't report plan usage.")
        XCTAssertTrue(both.recoverySuggestion?.contains("`env -u ANTHROPIC_API_KEY -u CLAUDE_CODE_OAUTH_TOKEN claude auth login`") == true)

        let alias = UsageError.signedInOnlyInTerminal(.wrapper(.alias))
        XCTAssertEqual(alias.errorDescription, "Claude Code isn't signed in. In Terminal, `claude` is an alias, which may sign it in another way.")
        XCTAssertTrue(alias.recoverySuggestion?.hasPrefix("Run `command claude auth login` in Terminal (`command` skips the alias)") == true)

        XCTAssertEqual(UsageError.list(["A", "B", "C"]), "A, B and C")
    }
}
