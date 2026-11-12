import XCTest
@testable import QuotaCore

/// The two Antigravity pools are summarised independently.  Before this, one
/// exhausted weekly cap on the Claude/GPT pool pulled the whole platform to 0%
/// while the Gemini pool was still nearly full.
final class AntigravityPoolsTests: XCTestCase {
    private let observedAt = "2026-09-13T10:00:00Z"
    private let now = ISO8601DateFormatter().date(from: "2026-09-13T10:05:00Z")!

    func testEachPoolTakesTheMinimumOfItsOwnWindowsOnly() throws {
        let windows = AntigravityQuotaGroups.normalize(
            [report("gemini-pro", 89), report("gemini-pro", 94, period: "weekly"),
             report("claude-sonnet", 100), report("claude-sonnet", 12, period: "weekly")],
            includeMissing: true)
        let pools = AntigravityQuotaGroups.pools(from: windows, now: now)
        XCTAssertEqual(pools.map(\.key), ["gemini", "third-party"])
        XCTAssertEqual(pools.map(\.remainingPercent), [89, 12])
        XCTAssertEqual(try XCTUnwrap(pools.first).drivingWindowId, "antigravity:gemini:5h")
        XCTAssertEqual(pools.last?.drivingWindowId, "antigravity:third-party:weekly")
        XCTAssertTrue(pools.allSatisfy { $0.windows.count == 2 })
    }

    func testAnExhaustedWeeklyMasksItsOwnFiveHourWindowAndNoOther() throws {
        let windows = AntigravityQuotaGroups.normalize(
            [report("gemini-pro", 89), report("gemini-pro", 94, period: "weekly"),
             report("claude-sonnet", 100), report("claude-sonnet", 0, period: "weekly")],
            includeMissing: true)
        let pools = AntigravityQuotaGroups.pools(from: windows, now: now)
        let gemini = try XCTUnwrap(pools.first { $0.key == "gemini" })
        let thirdParty = try XCTUnwrap(pools.first { $0.key == "third-party" })

        XCTAssertFalse(gemini.weeklyExhausted)
        XCTAssertTrue(gemini.maskedWindowIds.isEmpty)
        XCTAssertEqual(gemini.remainingPercent, 89)

        XCTAssertTrue(thirdParty.weeklyExhausted)
        XCTAssertEqual(thirdParty.maskedWindowIds, ["antigravity:third-party:5h"])
        // The pool is spent, so the headline is the weekly zero and never the
        // five-hour window's meaningless 100%.
        XCTAssertEqual(thirdParty.remainingPercent, 0)
        XCTAssertEqual(thirdParty.drivingWindowId, "antigravity:third-party:weekly")

        XCTAssertEqual(AntigravityQuotaGroups.maskedWindowIds(in: windows, now: now),
                       ["antigravity:third-party:5h"])
    }

    /// The provider reports a fractional remaining, and the interface rounds
    /// that to 0%, so a weekly that reads "at cap" on screen can carry a number
    /// that is not exactly zero.  An exact-zero test let those through, and the
    /// five-hour window under them was then believed when its percentage must
    /// not be believed.  Owner 2026-10-19: "Antigravity is saying vendor
    /// reset 5h quota early while the 7d is still at cap and unchanged".
    func testAWeeklyThatRoundsToZeroStillMasksItsFiveHourWindow() throws {
        let windows = AntigravityQuotaGroups.normalize(
            [report("gemini-pro", 89), report("gemini-pro", 0.4, period: "weekly")],
            includeMissing: true)
        let pools = AntigravityQuotaGroups.pools(from: windows, now: now)
        let gemini = try XCTUnwrap(pools.first { $0.key == "gemini" })

        XCTAssertTrue(gemini.weeklyExhausted, "a weekly that reads 0% on screen is spent")
        XCTAssertEqual(gemini.maskedWindowIds, ["antigravity:gemini:5h"])
    }

    func testAStaleObservationNeverSetsTheHeadlineNumber() {
        let windows = AntigravityQuotaGroups.normalize([report("gemini-pro", 89)], includeMissing: true)
        let stale = ISO8601DateFormatter().date(from: "2026-09-13T18:00:00Z")!
        XCTAssertNil(AntigravityQuotaGroups.pools(from: windows, now: stale).first?.remainingPercent)
        XCTAssertEqual(AntigravityQuotaGroups.pools(from: windows, now: now).first?.remainingPercent, 89)
    }

    func testPoolsIgnoreOtherProvidersAndUnclassifiableWindows() {
        let other = QuotaWindow(id: "anthropic-5h", provider: "anthropic", label: "5h window",
                                remainingPercent: 10, occurredAt: observedAt)
        let unknown = QuotaWindow(id: "antigravity:mystery", provider: "Antigravity", via: "antigravity",
                                  label: "Mystery Models · 5-hour", remainingPercent: 3,
                                  window: "5h", occurredAt: observedAt)
        let windows = AntigravityQuotaGroups.normalize([report("gemini-pro", 89)])
        let pools = AntigravityQuotaGroups.pools(from: windows + [other, unknown], now: now)
        XCTAssertEqual(pools.map(\.key), ["gemini"])
        XCTAssertEqual(pools.first?.remainingPercent, 89)
    }

    func testPoolAndCadenceKeysAreReadableFromAGroupedWindow() throws {
        let windows = AntigravityQuotaGroups.normalize(
            [report("gemini-pro", 89), report("claude-sonnet", 40, period: "weekly")], includeMissing: true)
        let fiveHour = try XCTUnwrap(windows.first { $0.id == "antigravity:gemini:5h" })
        let weekly = try XCTUnwrap(windows.first { $0.id == "antigravity:third-party:weekly" })
        XCTAssertEqual(AntigravityQuotaGroups.poolKey(for: fiveHour), "gemini")
        XCTAssertEqual(AntigravityQuotaGroups.cadenceKey(for: fiveHour), "5h")
        XCTAssertEqual(AntigravityQuotaGroups.poolKey(for: weekly), "third-party")
        XCTAssertEqual(AntigravityQuotaGroups.cadenceKey(for: weekly), "weekly")
    }

    func testGeminiArgonAtZeroDoesNotExhaustOrMaskGeminiPool() throws {
        let gemini5h = report("gemini-pro", 99, period: "5h")
        let geminiWeekly = report("gemini-pro", 76, period: "weekly")
        let argon = QuotaWindow(
            id: "local-mac:antigravity-summary:gemini-argon-wtu-weekly",
            provider: "Antigravity",
            providerKey: "google-antigravity",
            via: "antigravity",
            sourceApp: "local-mac",
            modelId: "argon",
            modelType: "argon",
            label: "Gemini 4 Argon · 7-day",
            remainingPercent: 0,
            resetAt: "2026-09-20T10:00:00Z",
            window: "7d",
            occurredAt: observedAt,
            source: "Antigravity quota summary"
        )
        let normalized = AntigravityQuotaGroups.normalize([gemini5h, geminiWeekly, argon])
        let geminiPoolWeekly = try XCTUnwrap(normalized.first { $0.id == "antigravity:gemini:weekly" })
        XCTAssertEqual(geminiPoolWeekly.remainingPercent, 76, "Argon 0% must not overwrite primary weekly pool")
        let geminiPool5h = try XCTUnwrap(normalized.first { $0.id == "antigravity:gemini:5h" })
        XCTAssertEqual(geminiPool5h.remainingPercent, 99)
        XCTAssertTrue(normalized.contains { $0.id == argon.id }, "Argon sub-model window is preserved")

        let pools = AntigravityQuotaGroups.pools(from: normalized, now: now)
        let gemini = try XCTUnwrap(pools.first { $0.key == "gemini" })
        XCTAssertFalse(gemini.weeklyExhausted, "Argon 0% must not exhaust primary Gemini weekly pool")
        XCTAssertTrue(gemini.maskedWindowIds.isEmpty, "5h window must not be masked by Argon 0%")
        XCTAssertEqual(gemini.remainingPercent, 76)
        XCTAssertEqual(gemini.drivingWindowId, "antigravity:gemini:weekly")
        XCTAssertEqual(gemini.windows.count, 3)
    }

    /// A provider that says an allowance is gone and leaves the figure out
    /// means the pool is at its cap.  Reading that as unknown let the
    /// five-hour window drive the pool's headline, which is how the Mac came
    /// to offer quota that was not there.
    func testAWeeklyWithNoReadingButAnExhaustedWordStillCapsThePool() throws {
        let weekly = QuotaWindow(
            id: "claude-sonnet-weekly",
            provider: "Antigravity", via: "antigravity", sourceApp: "local-mac",
            modelId: "claude-sonnet", label: "claude-sonnet",
            remainingPercent: nil, remainingUnknown: true, isExhausted: true,
            resetAt: "2026-09-20T10:00:00Z", window: "weekly", occurredAt: observedAt)
        let fiveHour = report("claude-sonnet", 100, period: "5h")
        let pools = AntigravityQuotaGroups.pools(from: [fiveHour, weekly], now: now)
        let thirdParty = try XCTUnwrap(pools.first { $0.key == "third-party" })

        XCTAssertTrue(thirdParty.weeklyExhausted)
        XCTAssertEqual(thirdParty.maskedWindowIds, [fiveHour.id])
        XCTAssertEqual(thirdParty.remainingPercent, 0,
                       "a pool at its cap reports zero, never the five-hour window's figure")
        XCTAssertEqual(thirdParty.drivingWindowId, weekly.id)
        XCTAssertEqual(thirdParty.resetAt, ISO8601DateFormatter().date(from: "2026-09-20T10:00:00Z"))
    }

    /// A copy of a period that ended must not spend the pool.
    ///
    /// The shared cap rule is percentage-level, so it cannot tell a live zero
    /// from the zero a window carried before its period ended.  The Mac asked
    /// it with no freshness term while the phone and the widget already asked
    /// the shared freshness rule, so one pool read spent on one surface and
    /// live on another.  Owner 2026-10-23: the Antigravity rows read
    /// "unavailable" beside a live fleet reading.
    func testAnEndedWeeklyDoesNotSpendThePool() throws {
        let endedWeekly = QuotaWindow(
            id: "gemini-pro-weekly", provider: "Antigravity", providerKey: "google-antigravity",
            via: "antigravity", sourceApp: "local-mac", modelId: "gemini-pro", label: "gemini-pro",
            remainingPercent: 0, resetAt: "2026-09-13T09:00:00Z",
            window: "weekly", occurredAt: "2026-09-13T08:00:00Z")
        let liveFiveHour = QuotaWindow(
            id: "gemini-pro", provider: "Antigravity", providerKey: "google-antigravity",
            via: "antigravity", sourceApp: "local-mac", modelId: "gemini-pro", label: "gemini-pro",
            remainingPercent: 89, resetAt: "2026-09-13T15:00:00Z",
            window: "5h", occurredAt: observedAt)

        let pools = AntigravityQuotaGroups.pools(from: [liveFiveHour, endedWeekly], now: now)
        let gemini = try XCTUnwrap(pools.first { $0.key == "gemini" })

        XCTAssertFalse(gemini.weeklyExhausted,
                       "a copy of a period that ended does not spend the pool")
        XCTAssertTrue(gemini.maskedWindowIds.isEmpty,
                      "the five-hour window is not masked by an ended weekly")
        XCTAssertEqual(gemini.remainingPercent, 89,
                       "the pool reads the live five-hour reading")
    }

    private func report(_ model: String, _ percent: Double, period: String? = nil) -> QuotaWindow {
        QuotaWindow(id: model + (period ?? ""), provider: "Antigravity", via: "antigravity", sourceApp: "local-mac",
                    modelId: model, label: model, remainingPercent: percent, resetAt: "2026-09-13T15:00:00Z",
                    window: period, occurredAt: observedAt)
    }

    /// A producer that names no pool in the label or model fields still names
    /// it in the bucket id.  The Third-Party weekly arrived as id `3p-weekly`,
    /// label "7-day window", no model, and belonged to no pool, so the Mac
    /// drew no cap for a pool whose weekly was spent.
    func testABucketIdNamesThePoolWhenLabelAndModelDoNot() throws {
        func window(_ id: String, label: String, period: String, percent: Double, exhausted: Bool) -> QuotaWindow {
            QuotaWindow(id: id, provider: "Antigravity", providerKey: "google-antigravity",
                        label: label, remainingPercent: percent, isExhausted: exhausted,
                        resetAt: "2026-09-20T00:00:00Z", window: period, occurredAt: observedAt)
        }
        let weekly = window("3p-weekly", label: "7-day window", period: "weekly", percent: 0, exhausted: true)
        let fiveHour = window("3p-5h", label: "Third-Party (5h)", period: "5h", percent: 100, exhausted: false)
        let geminiWeekly = window("gemini-weekly", label: "7-day window", period: "weekly", percent: 50, exhausted: false)
        XCTAssertEqual(AntigravityQuotaGroups.poolKey(for: weekly), "third-party")
        XCTAssertEqual(AntigravityQuotaGroups.poolKey(for: fiveHour), "third-party")
        XCTAssertEqual(AntigravityQuotaGroups.poolKey(for: geminiWeekly), "gemini")
        let pools = AntigravityQuotaGroups.pools(from: [weekly, fiveHour, geminiWeekly], now: now)
        let thirdParty = try XCTUnwrap(pools.first { $0.key == "third-party" })
        XCTAssertTrue(thirdParty.weeklyExhausted)
        XCTAssertEqual(thirdParty.maskedWindowIds, ["3p-5h"])
        XCTAssertEqual(thirdParty.drivingWindowId, "3p-weekly")
    }

    func testABucketIdInsideAJSONArrayStringNamesThePool() {
        func weekly(_ id: String) -> QuotaWindow {
            QuotaWindow(id: id, provider: "Antigravity", providerKey: "google-antigravity",
                        label: "7-day window", remainingPercent: 0, isExhausted: true,
                        window: "weekly", occurredAt: observedAt)
        }
        XCTAssertEqual(AntigravityQuotaGroups.poolKey(for: weekly(#"["producer","synthetic-instance","3p-weekly"]"#)), "third-party")
        XCTAssertEqual(AntigravityQuotaGroups.poolKey(for: weekly(#"["producer","synthetic-instance","gemini-weekly"]"#)), "gemini")
        XCTAssertNil(AntigravityQuotaGroups.poolKey(for: weekly(#"["producer","synthetic-instance","other-weekly"]"#)))
        XCTAssertNil(AntigravityQuotaGroups.poolKey(for: weekly("[not json 3p-weekly")))
        // The shape survives a real cache round trip.
        let json = #"{"id":"[\"producer\",\"synthetic-instance\",\"3p-weekly\"]","provider":"Antigravity","providerKey":"google-antigravity","label":"7-day window","window":"weekly"}"#
        let decoded = try? JSONDecoder().decode(QuotaWindow.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.flatMap { AntigravityQuotaGroups.poolKey(for: $0) }, "third-party")
    }

    func testAnUnnamedWindowStaysInNoPool() {
        let other = QuotaWindow(id: "plan-details", provider: "Antigravity", providerKey: "google-antigravity",
                                label: "Plan Details", remainingUnknown: true, window: nil, occurredAt: observedAt)
        XCTAssertNil(AntigravityQuotaGroups.poolKey(for: other))
    }
}
