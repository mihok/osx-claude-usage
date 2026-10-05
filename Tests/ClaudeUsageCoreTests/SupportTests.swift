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
            RefreshSchedule.nextDelay(interval: 600, error: .notSignedIn, consecutiveFailures: 5, nextReset: nil, now: now),
            60
        )
        XCTAssertEqual(
            RefreshSchedule.nextDelay(interval: 600, error: .cliNotFound(customPath: nil), consecutiveFailures: 1, nextReset: nil, now: now),
            60
        )
    }

    func testServerErrorsBackOff() {
        let error = UsageError.usageUnavailable(nil)
        XCTAssertEqual(RefreshSchedule.nextDelay(interval: 300, error: error, consecutiveFailures: 1, nextReset: nil, now: now), 300)
        XCTAssertEqual(RefreshSchedule.nextDelay(interval: 300, error: error, consecutiveFailures: 2, nextReset: nil, now: now), 600)
        XCTAssertEqual(RefreshSchedule.nextDelay(interval: 300, error: error, consecutiveFailures: 3, nextReset: nil, now: now), 1200)
        XCTAssertEqual(RefreshSchedule.nextDelay(interval: 300, error: error, consecutiveFailures: 30, nextReset: nil, now: now), 3600)
    }

    func testStaleness() throws {
        let snapshot = UsageSnapshot(meters: [], fetchedAt: now)
        XCTAssertFalse(RefreshSchedule.isStale(snapshot, interval: 300, now: now.addingTimeInterval(600)))
        XCTAssertTrue(RefreshSchedule.isStale(snapshot, interval: 300, now: now.addingTimeInterval(1000)))
    }
}

