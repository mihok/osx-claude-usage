import XCTest
@testable import ClaudeUsageCore

final class ISO8601Tests: XCTestCase {
    func testParsesVariants() throws {
        let base = 1_771_596_000.0  // 2026-02-20T14:00:00Z
        XCTAssertEqual(try XCTUnwrap(ISO8601.date(from: "2026-02-20T14:00:00Z")).timeIntervalSince1970, base)
        XCTAssertEqual(try XCTUnwrap(ISO8601.date(from: "2026-02-20T14:00:00.5Z")).timeIntervalSince1970, base + 0.5, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(ISO8601.date(from: "2026-02-20T14:00:00.943648+00:00")).timeIntervalSince1970,
            base + 0.943648, accuracy: 0.0001
        )
        XCTAssertEqual(try XCTUnwrap(ISO8601.date(from: "2026-02-20T16:00:00+02:00")).timeIntervalSince1970, base)
        XCTAssertEqual(try XCTUnwrap(ISO8601.date(from: "2026-02-20 14:00:00")).timeIntervalSince1970, base)
        XCTAssertEqual(try XCTUnwrap(ISO8601.date(from: "2026-02-20T14:00:00")).timeIntervalSince1970, base)
        XCTAssertNil(ISO8601.date(from: "not a date"))
        XCTAssertNil(ISO8601.date(from: ""))
    }

    func testParsesJSONValues() {
        XCTAssertEqual(ISO8601.date(fromJSON: 1_771_596_000)?.timeIntervalSince1970, 1_771_596_000)
        XCTAssertEqual(ISO8601.date(fromJSON: 1_771_596_000_000.0)?.timeIntervalSince1970, 1_771_596_000)
        XCTAssertNil(ISO8601.date(fromJSON: nil))
        XCTAssertNil(ISO8601.date(fromJSON: NSNull()))
    }
}

final class CredentialsTests: XCTestCase {
    func testParsesClaudeCodeCredentials() throws {
        let json = """
        {"claudeAiOauth":{"accessToken":"sk-ant-oat01-abc","refreshToken":"sk-ant-ort01-def",
         "expiresAt":1767225600000,"scopes":["user:inference","user:profile"],"subscriptionType":"max"}}
        """
        let credentials = try ClaudeCodeCredentials.parse(Data(json.utf8))
        XCTAssertEqual(credentials.accessToken, "sk-ant-oat01-abc")
        XCTAssertEqual(credentials.expiresAt?.timeIntervalSince1970, 1_767_225_600)
        XCTAssertEqual(credentials.scopes, ["user:inference", "user:profile"])
        XCTAssertEqual(credentials.planName, "Max")
        XCTAssertTrue(credentials.isExpired(at: Date(timeIntervalSince1970: 1_767_225_600)))
        XCTAssertFalse(credentials.isExpired(at: Date(timeIntervalSince1970: 1_767_220_000)))
    }

    func testMissingTokenMeansNotSignedIn() {
        XCTAssertThrowsError(try ClaudeCodeCredentials.parse(Data(#"{"claudeAiOauth":{}}"#.utf8))) { error in
            XCTAssertEqual(error as? UsageError, .notSignedIn)
        }
        XCTAssertThrowsError(try ClaudeCodeCredentials.parse(Data("garbage".utf8))) { error in
            guard case UsageError.credentialsUnavailable = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    func testLoaderFallsBackToCredentialsFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent(".credentials.json")
        try Data(#"{"claudeAiOauth":{"accessToken":"from-file","subscriptionType":"pro"}}"#.utf8).write(to: file)

        let loader = ClaudeCodeCredentialsLoader(
            keychainService: "ClaudeUsageTests-missing-\(UUID().uuidString)",
            credentialFiles: [directory.appendingPathComponent("missing.json"), file]
        )
        let credentials = try loader.load()
        XCTAssertEqual(credentials.accessToken, "from-file")
        XCTAssertEqual(credentials.planName, "Pro")
        XCTAssertFalse(credentials.isExpired())
    }

    func testLoaderReportsNotSignedIn() {
        let loader = ClaudeCodeCredentialsLoader(
            keychainService: "ClaudeUsageTests-missing-\(UUID().uuidString)",
            credentialFiles: []
        )
        XCTAssertThrowsError(try loader.load()) { error in
            XCTAssertEqual(error as? UsageError, .notSignedIn)
        }
    }

    func testPlanNames() {
        XCTAssertEqual(PlanName.from(subscriptionType: "claude_max"), "Max")
        XCTAssertEqual(PlanName.from(subscriptionType: "team"), "Team")
        XCTAssertNil(PlanName.from(subscriptionType: nil))
        XCTAssertEqual(PlanName.from(capabilities: ["chat", "claude_pro"]), "Pro")
        XCTAssertNil(PlanName.from(capabilities: ["chat"]))
    }
}

final class CookieTests: XCTestCase {
    func testNormalize() {
        XCTAssertEqual(ClaudeWebCookie.normalize("  sk-ant-sid01-xyz \n"), "sessionKey=sk-ant-sid01-xyz")
        XCTAssertEqual(ClaudeWebCookie.normalize("sessionKey=abc"), "sessionKey=abc")
        XCTAssertEqual(
            ClaudeWebCookie.normalize("Cookie: sessionKey=abc; lastActiveOrg=1234-abcd"),
            "sessionKey=abc; lastActiveOrg=1234-abcd"
        )
        XCTAssertEqual(ClaudeWebCookie.normalize("\"sessionKey=abc;\n cf_clearance=x\""), "sessionKey=abc;cf_clearance=x")
        XCTAssertNil(ClaudeWebCookie.normalize("   "))
    }

    func testValueLookup() {
        let header = "anthropic-device-id=1; sessionKey=sk-ant-sid01-q=; lastActiveOrg=0d1c-22ff"
        XCTAssertEqual(ClaudeWebCookie.value(named: "lastActiveOrg", in: header), "0d1c-22ff")
        XCTAssertEqual(ClaudeWebCookie.value(named: "sessionKey", in: header), "sk-ant-sid01-q=")
        XCTAssertNil(ClaudeWebCookie.value(named: "missing", in: header))
    }

    func testOrganizationIDValidation() {
        XCTAssertTrue(ClaudeWebCookie.isValidOrganizationID("8c3a6f5e-1b2d-4e5f-9a8b-7c6d5e4f3a2b"))
        XCTAssertFalse(ClaudeWebCookie.isValidOrganizationID("../../account"))
        XCTAssertFalse(ClaudeWebCookie.isValidOrganizationID(""))
    }
}

final class FormattingTests: XCTestCase {
    func testPercent() {
        XCTAssertEqual(UsageFormatting.percent(0), "0%")
        XCTAssertEqual(UsageFormatting.percent(0.4), "<1%")
        XCTAssertEqual(UsageFormatting.percent(41.6), "42%")
        XCTAssertEqual(UsageFormatting.percent(100), "100%")
    }

    func testDuration() {
        XCTAssertEqual(UsageFormatting.duration(0), "<1m")
        XCTAssertEqual(UsageFormatting.duration(59), "1m")
        XCTAssertEqual(UsageFormatting.duration(45 * 60), "45m")
        XCTAssertEqual(UsageFormatting.duration(2 * 3600 + 14 * 60), "2h 14m")
        XCTAssertEqual(UsageFormatting.duration(3 * 3600), "3h")
        XCTAssertEqual(UsageFormatting.duration(3 * 86400 + 4 * 3600), "3d 4h")
    }

    func testResetDescription() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_GB")
        let now = try XCTUnwrap(ISO8601.date(from: "2026-10-04T13:00:00Z"))

        let sameDay = UsageFormatting.resetDescription(
            now.addingTimeInterval(2 * 3600 + 14 * 60), now: now, calendar: calendar, locale: locale
        )
        XCTAssertEqual(sameDay, "Resets in 2h 14m · 15:14")

        let laterInWeek = UsageFormatting.resetDescription(
            now.addingTimeInterval(2 * 86400), now: now, calendar: calendar, locale: locale
        )
        XCTAssertTrue(laterInWeek.hasPrefix("Resets in 2d · Tue"), laterInWeek)

        XCTAssertEqual(UsageFormatting.resetDescription(nil, now: now), "No active window")
        XCTAssertEqual(UsageFormatting.resetDescription(now.addingTimeInterval(-5), now: now), "Resetting now…")
    }

    func testAge() {
        let now = Date()
        XCTAssertEqual(UsageFormatting.age(of: now, now: now), "just now")
        XCTAssertEqual(UsageFormatting.age(of: now.addingTimeInterval(-300), now: now), "5m ago")
        XCTAssertEqual(UsageFormatting.age(of: now.addingTimeInterval(-7200), now: now), "2h ago")
    }
}

final class RefreshScheduleTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func testSuccessUsesIntervalOrNextReset() {
        XCTAssertEqual(RefreshSchedule.nextDelay(interval: 300, error: nil, consecutiveFailures: 0, nextReset: nil, now: now), 300)
        XCTAssertEqual(
            RefreshSchedule.nextDelay(interval: 300, error: nil, consecutiveFailures: 0, nextReset: now.addingTimeInterval(100), now: now),
            120
        )
        XCTAssertEqual(
            RefreshSchedule.nextDelay(interval: 300, error: nil, consecutiveFailures: 0, nextReset: now.addingTimeInterval(3600), now: now),
            300
        )
    }

    func testLocalErrorsRetryQuickly() {
        XCTAssertEqual(
            RefreshSchedule.nextDelay(interval: 600, error: .tokenExpired, consecutiveFailures: 5, nextReset: nil, now: now),
            60
        )
    }

    func testServerErrorsBackOff() {
        let error = UsageError.network("offline")
        XCTAssertEqual(RefreshSchedule.nextDelay(interval: 300, error: error, consecutiveFailures: 1, nextReset: nil, now: now), 300)
        XCTAssertEqual(RefreshSchedule.nextDelay(interval: 300, error: error, consecutiveFailures: 2, nextReset: nil, now: now), 600)
        XCTAssertEqual(RefreshSchedule.nextDelay(interval: 300, error: error, consecutiveFailures: 3, nextReset: nil, now: now), 1200)
        XCTAssertEqual(RefreshSchedule.nextDelay(interval: 300, error: error, consecutiveFailures: 30, nextReset: nil, now: now), 3600)
    }

    func testRetryAfterIsHonoured() {
        XCTAssertEqual(
            RefreshSchedule.nextDelay(
                interval: 60, error: .rateLimited(retryAfter: 900), consecutiveFailures: 1, nextReset: nil, now: now
            ),
            900
        )
    }

    func testStaleness() throws {
        let snapshot = UsageSnapshot(meters: [], fetchedAt: now)
        XCTAssertFalse(RefreshSchedule.isStale(snapshot, interval: 300, now: now.addingTimeInterval(600)))
        XCTAssertTrue(RefreshSchedule.isStale(snapshot, interval: 300, now: now.addingTimeInterval(1000)))
    }
}

final class UsageClientTests: XCTestCase {
    func testRetryAfterParsing() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(UsageClient.retryAfter("120", now: now), 120)
        XCTAssertNil(UsageClient.retryAfter("0", now: now))
        XCTAssertNil(UsageClient.retryAfter(nil, now: now))
        XCTAssertNil(UsageClient.retryAfter("soon", now: now))
        let date = "Mon, 12 Jan 1970 13:48:20 GMT"  // now + 100 s
        XCTAssertEqual(try XCTUnwrap(UsageClient.retryAfter(date, now: now)), 100, accuracy: 1)
    }

    func testErrorMessageExtraction() {
        let apiError = #"{"type":"error","error":{"type":"permission_error","message":"OAuth token does not meet scope requirement user:profile"}}"#
        XCTAssertEqual(
            UsageClient.errorMessage(in: Data(apiError.utf8)),
            "OAuth token does not meet scope requirement user:profile"
        )
        XCTAssertNotNil(UsageClient.errorMessage(in: Data("<html><title>Just a moment...</title></html>".utf8)))
        XCTAssertNil(UsageClient.errorMessage(in: Data("plain".utf8)))
    }
}
