import XCTest
@testable import ClaudeUsageCore

final class UsageParserTests: XCTestCase {
    func testParsesOAuthResponse() throws {
        let json = """
        {
          "five_hour": { "utilization": 22.0, "resets_at": "2026-02-20T14:00:00.364238+00:00" },
          "seven_day": { "utilization": 49, "resets_at": "2026-02-24T10:00:01.364256+00:00" },
          "seven_day_oauth_apps": null,
          "seven_day_opus": { "utilization": 0.0, "resets_at": null },
          "seven_day_sonnet": { "utilization": 3.5, "resets_at": "2026-02-24T10:00:01Z" },
          "iguana_necktie": null,
          "extra_usage": { "is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null }
        }
        """
        let snapshot = try UsageParser.snapshot(from: Data(json.utf8), fetchedAt: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(snapshot.meters.map(\.id), ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"])

        let session = try XCTUnwrap(snapshot.meter(id: MeterID.session))
        XCTAssertEqual(session.title, "Session")
        XCTAssertEqual(session.glyph, "5")
        XCTAssertEqual(session.percent, 22)
        XCTAssertEqual(try XCTUnwrap(session.resetsAt).timeIntervalSince1970, 1_771_596_000.364238, accuracy: 0.001)

        let weekly = try XCTUnwrap(snapshot.meter(id: MeterID.weekly))
        XCTAssertEqual(weekly.glyph, "W")
        XCTAssertEqual(weekly.percent, 49)

        let sonnet = try XCTUnwrap(snapshot.meter(id: MeterID.weeklySonnet))
        XCTAssertEqual(sonnet.title, "Weekly · Sonnet")
        XCTAssertEqual(sonnet.glyph, "S")
        XCTAssertTrue(sonnet.isRelevant)

        // Opus is reported but idle, so it is kept out of the display.
        let opus = try XCTUnwrap(snapshot.meter(id: MeterID.weeklyOpus))
        XCTAssertFalse(opus.isRelevant)
        XCTAssertEqual(snapshot.relevantMeters.map(\.id), ["five_hour", "seven_day", "seven_day_sonnet"])
        XCTAssertNil(snapshot.meter(id: MeterID.extraUsage))
    }

    func testParsesModelScopedLimitsAndExtraUsage() throws {
        let json = """
        {
          "five_hour": { "utilization": 91, "resets_at": "2026-10-04T18:00:00Z" },
          "seven_day": { "utilization": 70.4, "resets_at": "2026-10-08T09:00:00Z" },
          "seven_day_sonnet": { "utilization": 12, "resets_at": "2026-10-08T09:00:00Z" },
          "limits": [
            { "scope": { "model": { "display_name": "Fable" } }, "percent": 37, "resets_at": "2026-10-08T09:00:00Z" },
            { "scope": { "model": { "display_name": "Sonnet" } }, "percent": 99, "resets_at": "2026-10-08T09:00:00Z" },
            { "scope": { "model": { "display_name": "Claude Haiku" } }, "window": "five_hour", "percent": 5 },
            { "percent": 50 }
          ],
          "extra_usage": { "is_enabled": true, "utilization": 12.5 }
        }
        """
        let snapshot = try UsageParser.snapshot(from: Data(json.utf8))

        let fable = try XCTUnwrap(snapshot.meter(id: "seven_day_fable"))
        XCTAssertEqual(fable.title, "Weekly · Fable")
        XCTAssertEqual(fable.glyph, "F")
        XCTAssertEqual(fable.percent, 37)

        // The top-level seven_day_sonnet key wins over the duplicate limits entry.
        XCTAssertEqual(snapshot.meter(id: MeterID.weeklySonnet)?.percent, 12)

        let haiku = try XCTUnwrap(snapshot.meter(id: "five_hour_haiku"))
        XCTAssertEqual(haiku.title, "Session · Haiku")

        let extra = try XCTUnwrap(snapshot.meter(id: MeterID.extraUsage))
        XCTAssertEqual(extra.percent, 12.5)
        XCTAssertEqual(snapshot.meters.last?.id, MeterID.extraUsage)

        XCTAssertEqual(snapshot.meter(id: MeterID.session)?.level, .critical)
        XCTAssertEqual(snapshot.meter(id: MeterID.weekly)?.level, .elevated)
        XCTAssertEqual(fable.level, .normal)
        XCTAssertEqual(snapshot.mostConstrained?.id, MeterID.session)
    }

    func testClampsOutOfRangeValues() throws {
        let json = #"{ "five_hour": { "utilization": 140 }, "seven_day": { "utilization": -3 } }"#
        let snapshot = try UsageParser.snapshot(from: Data(json.utf8))
        XCTAssertEqual(snapshot.meter(id: MeterID.session)?.percent, 100)
        XCTAssertEqual(snapshot.meter(id: MeterID.weekly)?.percent, 0)
    }

    func testRejectsResponsesWithoutLimits() {
        XCTAssertThrowsError(try UsageParser.snapshot(from: Data(#"{"type":"error"}"#.utf8))) { error in
            guard case UsageError.invalidResponse = error else {
                return XCTFail("Unexpected error \(error)")
            }
        }
        XCTAssertThrowsError(try UsageParser.snapshot(from: Data("<html>".utf8)))
        XCTAssertThrowsError(try UsageParser.snapshot(from: Data("[]".utf8)))
    }

    func testNextResetIgnoresPastResets() throws {
        let json = """
        {
          "five_hour": { "utilization": 1, "resets_at": "2026-01-01T10:00:00Z" },
          "seven_day": { "utilization": 1, "resets_at": "2026-01-03T10:00:00Z" }
        }
        """
        let snapshot = try UsageParser.snapshot(from: Data(json.utf8))
        let now = try XCTUnwrap(ISO8601.date(from: "2026-01-02T00:00:00Z"))
        XCTAssertEqual(snapshot.nextReset(after: now), ISO8601.date(from: "2026-01-03T10:00:00Z"))
    }

    func testSlugify() {
        XCTAssertEqual(UsageParser.slugify("Fable"), "fable")
        XCTAssertEqual(UsageParser.slugify("Claude Opus 5.5"), "claude_opus_5_5")
        XCTAssertEqual(UsageParser.slugify("  --  "), "")
    }
}
