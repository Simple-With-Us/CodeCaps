import Foundation
import XCTest
@testable import QuotaCore

/// Grok Bot's stray extra, empty "7d" bar (owner delta, 2026-09-30).
///
/// Two readers speak for the one Grok Bot weekly allowance: Cursor's
/// DashboardService and the `gbu` CLI.  Each emits a no-reading placeholder
/// window when it cannot read, and the Glance row used to draw any second
/// window as a second bar, so a placeholder beside the other reader's real
/// reading was an empty "7d" meter.  These tests build the windows with the
/// real readers rather than by hand.
final class PlaceholderWindowsTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_789_000_000)

    private func dashboardReading() async -> LocalQuotaResult {
        await GrokBotQuotaReader(
            now: { self.observedAt },
            accessToken: { "test-session" },
            fetch: { request in
                let body = """
                {"usagePercent":19.4,"nextResetTimestampUtc":"2026-10-05T18:35:19.304Z","hasNonZeroIncludedLimit":true,"usesPooledEnterpriseAllowance":false,"grokPlanLabel":"Grok Bot Plan"}
                """
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }).read()
    }

    private func dashboardUnreadable() async -> LocalQuotaResult {
        await GrokBotQuotaReader(
            now: { self.observedAt },
            accessToken: { "test-session" },
            fetch: { request in
                let body = #"{"usagePercent":0,"hasNonZeroIncludedLimit":false}"#
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(body.utf8), response)
            }).read()
    }

    private func gbuReading() async -> LocalQuotaResult {
        let json = """
        {"active":"a@example.com","accounts":[{"account":"a@example.com","active":true,"weeklyUsagePercent":19.41,"available":true,"resetsAt":"2026-10-05T18:35:19.304Z","planLabel":"Grok Bot Plan"}]}
        """
        return await GbuQuotaReader(now: { self.observedAt }, runGbu: { Data(json.utf8) }).read()
    }

    private func gbuUnreadable() async -> LocalQuotaResult {
        // A signed-out account: gbu runs, reports an error, and no window is
        // readable, so the reader falls back to its placeholder.
        let json = #"{"active":"a@example.com","accounts":[{"account":"a@example.com","error":"signed out"}]}"#
        return await GbuQuotaReader(now: { self.observedAt }, runGbu: { Data(json.utf8) }).read()
    }

    private func merged(_ results: [LocalQuotaResult]) -> LocalQuotaResult {
        LocalQuotaResult(windows: results.flatMap(\.windows),
                         issues: results.reduce(into: [:]) { $0.merge($1.issues) { _, next in next } },
                         consentNeeded: [])
    }

    // MARK: - What the readers emit

    func testBothGrokBotReadersEmitAWeeklyWindowForTheSameAllowance() async {
        let dashboard = await dashboardReading()
        let gbu = await gbuReading()
        XCTAssertEqual(dashboard.windows.map(\.id), ["local-mac:grok-bot:weekly"])
        XCTAssertEqual(gbu.windows.map(\.id), ["local-mac:grok-bot:gbu-weekly"])
        XCTAssertEqual(dashboard.windows.first?.label, gbu.windows.first?.label, "the same \"Grok Bot weekly\"")
        XCTAssertEqual(dashboard.windows.first?.window, gbu.windows.first?.window)
        XCTAssertEqual(dashboard.windows.first?.resetAt, gbu.windows.first?.resetAt)
    }

    func testAnUnreadableGbuLeavesAPlaceholderWithNoReadingAndNoCadence() async throws {
        let gbu = await gbuUnreadable()
        let placeholder = try XCTUnwrap(gbu.windows.first)
        XCTAssertEqual(gbu.windows.count, 1)
        XCTAssertEqual(placeholder.id, "local-mac:grok-bot:gbu-unknown")
        XCTAssertNil(placeholder.boundedRemainingPercent)
        XCTAssertNil(placeholder.window)
        XCTAssertTrue(placeholder.isPlaceholder)
        XCTAssertEqual(gbu.issues["gbu"], "gbu returned no readable Grok Bot weekly quota.",
                       "gbu's issue is under its own key, so the Grok Bot row does not show it")
        XCTAssertNil(gbu.issues["grok-bot"])
    }

    func testAnUnreadableDashboardLeavesAPlaceholderAndAnIssueUnderGrokBot() async throws {
        let dashboard = await dashboardUnreadable()
        XCTAssertEqual(dashboard.windows.map(\.id), ["local-mac:grok-bot:unknown"])
        XCTAssertTrue(try XCTUnwrap(dashboard.windows.first).isPlaceholder)
        XCTAssertNotNil(dashboard.issues["grok-bot"])
    }

    func testAReadingAndAWindowThatNamesACadenceAreNeverPlaceholders() async throws {
        let dashboard = await dashboardReading()
        let reading = try XCTUnwrap(dashboard.windows.first)
        XCTAssertFalse(reading.isPlaceholder)
        let claudeWeekly = QuotaWindow(id: "7d", provider: "anthropic", label: "7d window",
                                       remainingUnknown: true, window: "168h", occurredAt: "")
        XCTAssertFalse(claudeWeekly.isPlaceholder, "a weekly window with no reading is a statement, not a placeholder")
    }

    func testAWindowWithAnAbsoluteFigureAndNoPercentageIsAReadingNotAPlaceholder() async {
        // A credits window can carry what is left and the limit without a
        // percentage.  That is a reading of its own, so it must survive beside
        // another reader's percentage rather than be taken for a placeholder.
        let credits = QuotaWindow(id: "local-mac:grok-bot:credits", provider: "Grok Bot", providerKey: "grok-bot",
                                  label: "Grok Bot credits", absoluteRemaining: 6_099, absoluteLimit: 40_000,
                                  quotaUnit: "credits", remainingUnknown: true, occurredAt: "")
        XCTAssertNil(credits.boundedRemainingPercent)
        XCTAssertFalse(credits.isPlaceholder)
        let limitOnly = QuotaWindow(id: "limit", provider: "Grok Bot", providerKey: "grok-bot",
                                    label: "Grok Bot limit", absoluteLimit: 40_000, remainingUnknown: true, occurredAt: "")
        XCTAssertFalse(limitOnly.isPlaceholder)
        let all = merged([await dashboardReading(), LocalQuotaResult(windows: [credits, limitOnly])])
        XCTAssertEqual(all.droppingSupersededPlaceholders().windows.count, 3)
    }

    // MARK: - Dropping the superseded placeholder

    func testGbuPlaceholderBesideDashboardReadingIsDropped() async {
        let all = merged([await dashboardReading(), await gbuUnreadable()])
        XCTAssertEqual(all.windows.count, 2, "what the readers hand the model")
        let kept = all.droppingSupersededPlaceholders()
        XCTAssertEqual(kept.windows.map(\.id), ["local-mac:grok-bot:weekly"])
        XCTAssertEqual(kept.issues["gbu"], all.issues["gbu"], "an issue of gbu's own is not hidden")
    }

    func testDashboardPlaceholderBesideGbuReadingIsDroppedWithItsIssue() async {
        let all = merged([await dashboardUnreadable(), await gbuReading()])
        XCTAssertNotNil(all.issues["grok-bot"])
        let kept = all.droppingSupersededPlaceholders()
        XCTAssertEqual(kept.windows.map(\.id), ["local-mac:grok-bot:gbu-weekly"])
        XCTAssertNil(kept.issues["grok-bot"],
                     "the sentence goes with its placeholder, or the whole row reads \"unavailable\" over gbu's reading")
    }

    func testBothReadingKeepsBothWindowsForSettingsToRankAndDisable() async {
        let all = merged([await dashboardReading(), await gbuReading()])
        XCTAssertEqual(all.droppingSupersededPlaceholders().windows.map(\.id),
                       ["local-mac:grok-bot:weekly", "local-mac:grok-bot:gbu-weekly"])
    }

    func testAProviderWithNoReadingKeepsItsPlaceholderAndItsIssue() async {
        let all = merged([await dashboardUnreadable(), await gbuUnreadable()])
        let kept = all.droppingSupersededPlaceholders()
        XCTAssertEqual(Set(kept.windows.map(\.id)), ["local-mac:grok-bot:unknown", "local-mac:grok-bot:gbu-unknown"])
        XCTAssertNotNil(kept.issues["grok-bot"], "nothing reads, so the row still says why")
    }

    func testAModelThatReturnedNothingKeepsItsPlaceholderBesideAnotherModelsReading() {
        // MiniMax emits a tokenless "<model>:unknown" window for a model with
        // no fields.  Another model's reading does not supersede it: they are
        // different meters, and the unavailable one stays visible as unknown.
        let general = QuotaWindow(id: "general:weekly", provider: "MiniMax", providerKey: "minimax", modelId: "general",
                                  label: "general (1w window)", remainingPercent: 81, window: "1w", occurredAt: "")
        let speech = QuotaWindow(id: "speech:unknown", provider: "MiniMax", providerKey: "minimax", modelId: "speech",
                                 label: "speech", remainingUnknown: true, occurredAt: "")
        XCTAssertTrue(speech.isPlaceholder)
        let result = LocalQuotaResult(windows: [general, speech], issues: ["minimax": "speech returned no quota."])
        let kept = result.droppingSupersededPlaceholders()
        XCTAssertEqual(kept.windows.map(\.id), ["general:weekly", "speech:unknown"])
        XCTAssertNotNil(kept.issues["minimax"], "the model is still unreadable, so the row still says why")
        XCTAssertNotEqual(general.meterIdentity, speech.meterIdentity)
    }

    func testAnAbsoluteOnlyReadingSupersedesTheSameMetersPlaceholderAndItsIssue() async {
        // Another reader's credits-only window is a reading, so it speaks for
        // the meter exactly as a percentage does.
        let credits = QuotaWindow(id: "local-mac:grok-bot:credits", provider: "Grok Bot", providerKey: "grok-bot",
                                  label: "Grok Bot weekly", absoluteRemaining: 6_099, absoluteLimit: 40_000,
                                  quotaUnit: "credits", remainingUnknown: true, occurredAt: "")
        XCTAssertTrue(credits.hasReading)
        let all = merged([await dashboardUnreadable(), LocalQuotaResult(windows: [credits])])
        XCTAssertNotNil(all.issues["grok-bot"])
        let kept = all.droppingSupersededPlaceholders()
        XCTAssertEqual(kept.windows.map(\.id), ["local-mac:grok-bot:credits"])
        XCTAssertNil(kept.issues["grok-bot"])
    }

    func testMeterIdentityIgnoresCaseAndPaddingButNotModelOrLabel() {
        func window(model: String?, label: String) -> QuotaWindow {
            QuotaWindow(id: "x", provider: "Grok Bot", providerKey: "grok-bot", modelId: model, label: label,
                        occurredAt: "")
        }
        XCTAssertEqual(window(model: nil, label: "Grok Bot weekly").meterIdentity,
                       window(model: nil, label: " grok bot WEEKLY ").meterIdentity)
        XCTAssertNotEqual(window(model: "a", label: "Grok Bot weekly").meterIdentity,
                          window(model: "b", label: "Grok Bot weekly").meterIdentity)
        XCTAssertNotEqual(window(model: nil, label: "Grok Bot weekly").meterIdentity,
                          window(model: nil, label: "Grok Bot weekly (b@example.com)").meterIdentity)
    }

    func testAnotherProvidersReadingDoesNotHideThisProvidersPlaceholder() async {
        let cursor = QuotaWindow(id: "local-mac:cursor:plan", provider: "Cursor", providerKey: "cursor", label: "Included plan",
                                 remainingPercent: 62, window: "billing-cycle", occurredAt: "")
        let all = merged([await dashboardUnreadable(), LocalQuotaResult(windows: [cursor])])
        XCTAssertEqual(all.droppingSupersededPlaceholders().windows.count, 2)
    }

    func testArrayFormKeepsOrderAndIsIdempotent() async {
        let windows = merged([await gbuUnreadable(), await dashboardReading(), await gbuReading()]).windows
        let once = windows.droppingSupersededPlaceholders()
        XCTAssertEqual(once.map(\.id), ["local-mac:grok-bot:weekly", "local-mac:grok-bot:gbu-weekly"])
        XCTAssertEqual(once.droppingSupersededPlaceholders(), once)
    }
}
