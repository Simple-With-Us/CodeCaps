import Foundation
import XCTest
@testable import QuotaCore

/// Placeholder reconciliation remains wire-compatible with readings from older
/// fleet clients, even though the redundant Grok Bot readers are retired.
final class PlaceholderWindowsTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_789_000_000)

    private func legacyReading(id: String, source: String) -> LocalQuotaResult {
        LocalQuotaResult(windows: [QuotaWindow(
            id: id, provider: "Grok Bot", providerKey: "grok-bot",
            label: "Grok Bot weekly", remainingPercent: 80.6,
            resetAt: "2026-10-05T18:35:19.304Z", window: "weekly",
            occurredAt: ISO8601DateFormatter().string(from: observedAt), source: source
        )])
    }

    private func dashboardReading() async -> LocalQuotaResult {
        legacyReading(id: "local-mac:grok-bot:weekly", source: "Cursor DashboardService")
    }

    private func gbuReading() async -> LocalQuotaResult {
        legacyReading(id: "local-mac:grok-bot:gbu-weekly", source: "gbu")
    }

    private func legacyPlaceholder(id: String, source: String, issueKey: String) -> LocalQuotaResult {
        LocalQuotaResult(windows: [QuotaWindow(
            id: id, provider: "Grok Bot", providerKey: "grok-bot", label: "Grok Bot weekly",
            remainingUnknown: true, occurredAt: ISO8601DateFormatter().string(from: observedAt), source: source
        )], issues: [issueKey: "Legacy source unavailable."])
    }

    private func dashboardUnreadable() async -> LocalQuotaResult {
        legacyPlaceholder(id: "local-mac:grok-bot:unknown", source: "Cursor DashboardService", issueKey: "grok-bot")
    }

    private func gbuUnreadable() async -> LocalQuotaResult {
        legacyPlaceholder(id: "local-mac:grok-bot:gbu-unknown", source: "gbu", issueKey: "gbu")
    }

    private func merged(_ results: [LocalQuotaResult]) -> LocalQuotaResult {
        LocalQuotaResult(windows: results.flatMap(\.windows),
                         issues: results.reduce(into: [:]) { $0.merge($1.issues) { _, next in next } },
                         consentNeeded: [])
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
                                  quotaUnit: "credits", remainingUnknown: true, occurredAt: ""
        ).normalizedForExport()
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

