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
    private func fakeClaude(_ body: String) throws -> URL {
        let url = directory.appendingPathComponent("claude")
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

    func testDropsOptionsAnOlderClaudeDoesNotKnow() throws {
        let output = directory.appendingPathComponent("output.jsonl")
        try Data(streamJSON.utf8).write(to: output)
        let claude = try fakeClaude("""
        for argument in "$@"; do
          if [ "$argument" = "--safe-mode" ]; then
            echo "error: unknown option '--safe-mode'" >&2
            exit 1
          fi
        done
        cat '\(output.path)'
        """)

        let snapshot = try ClaudeCLI(executable: claude, environment: Self.environment, timeout: 20).fetchUsage()
        XCTAssertEqual(snapshot.meter(id: MeterID.weekly)?.percent, 71.4)
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
        XCTAssertEqual(status, ClaudeAuthStatus(loggedIn: true, authMethod: "claude.ai", subscriptionType: "max"))
        XCTAssertEqual(status.planName, "Max")

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

    func testEnvironmentIncludesShellAndInstallDirectories() {
        let environment = ClaudeCLI.environment(
            base: ["PATH": "/usr/bin:/bin", "HOME": "/Users/me"],
            loginShellPath: "/Users/me/.nvm/versions/node/v22/bin:/usr/bin",
            executable: URL(fileURLWithPath: "/Users/me/.local/bin/claude")
        )
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        XCTAssertEqual(path.first, "/Users/me/.local/bin")
        XCTAssertTrue(path.contains("/Users/me/.nvm/versions/node/v22/bin"))
        XCTAssertTrue(path.contains("/opt/homebrew/bin"))
        XCTAssertEqual(path.filter { $0 == "/usr/bin" }.count, 1)
        XCTAssertEqual(environment["HOME"], "/Users/me")
    }

    func testLoginShellPath() throws {
        let shell = try fakeClaude(#"printf 'noise from a profile\n__CLAUDE_USAGE_PATH__/opt/a:/opt/b__CLAUDE_USAGE_PATH__'"#)
        XCTAssertEqual(ClaudeCLI.loginShellPath(shell: shell.path), "/opt/a:/opt/b")
    }

    func testUnknownOptionParsing() {
        XCTAssertEqual(ClaudeCLI.unknownOption(in: "error: unknown option '--safe-mode'\n"), "--safe-mode")
        XCTAssertNil(ClaudeCLI.unknownOption(in: "error: something else"))
    }
}
