import XCTest
@testable import CodeCaps
import QuotaCore

/// Cursor, xAI, Grok and Grok Bot draw on one subscription pool, and a
/// participant whose local read failed outright still has to show the pool's
/// reading (CC-210, owner 2026-11-07).  Two things broke that before this
/// fix:  the merge never asked the pool to serve participants it did not
/// have a window for, and the failed read's issue kept the row at
/// "unavailable" even after the pool filled it in.
///
/// This drives the real refresh, so the row and the issue map are read
/// rather than argued about.
@MainActor
final class SharedQuotaPoolServingTests: XCTestCase {
    private let iso = ISO8601DateFormatter()
    private let now = Date()

    /// A live pool reading the way the fleet files it:  the Grok credits
    /// payload under the xAI key, with the id that names the pool.
    private func liveXaiWindow(percent: Double) -> QuotaWindow {
        QuotaWindow(
            id: "grok:subscription",
            provider: "xAI",
            providerKey: "xai",
            label: "7-day window",
            remainingPercent: percent,
            resetAt: iso.string(from: now.addingTimeInterval(6 * 86_400)),
            window: "weekly",
            occurredAt: iso.string(from: now.addingTimeInterval(-60)),
            source: "codecaps"
        )
    }

    private func makeModel(serverEnabled: Bool) -> MonitorModel {
        let suite = "com.jays.codecaps.sharedpool." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(serverEnabled, forKey: "serverEnabled")
        defaults.set("https://usage.jays.services/api/quota-windows", forKey: "endpoint")
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        model.setSessionFileChecksEnabled(false)
        return model
    }

    func testAFailedLocalReadStillShowsTheSharedReadingAndDropsTheIssue() async throws {
        // Both readers failed:  issues set, no windows at all, which is the
        // shape an unreadable Cursor session and an unreachable Grok Bot
        // endpoint leave behind.
        let local = LocalQuotaResult(issues: [
            "cursor": "Cursor is not signed in locally.",
            "grok-bot": "Grok Bot quota service is unavailable.",
        ])
        let payload = QuotaResponse(generatedAt: iso.string(from: now), windows: [liveXaiWindow(percent: 61)])

        let model = makeModel(serverEnabled: true)
        model.localReadForTesting = { local }
        model.serverFetchForTesting = { payload }

        model.refresh()
        await model.refreshTaskForTesting?.value

        // The raw map keeps the real failures: Settings diagnostics and the
        // BotFleet handoff both read it (PR review, sentry 19572687).
        XCTAssertEqual(model.issues["cursor"], "Cursor is not signed in locally.")
        XCTAssertEqual(model.issues["grok-bot"], "Grok Bot quota service is unavailable.")
        XCTAssertTrue(model.poolServedKeys.contains("cursor"))
        XCTAssertTrue(model.poolServedKeys.contains("grok-bot"))
        XCTAssertNil(model.rowIssue(for: "cursor"), "the pool served cursor, so the row shows the shared reading")
        XCTAssertNil(model.rowIssue(for: "grok-bot"), "the pool served grok-bot, so the row shows the shared reading")
        XCTAssertEqual(model.rowIssue(for: "xai"), nil)

        for key in ["cursor", "grok-bot"] {
            let section = model.response.platformSections(now: model.now)
                .first(where: { $0.providerKey == key })
            XCTAssertNotNil(section, "the \(key) row is present")
            let reading = section?.windows.first { $0.remainingPercent != nil }
            XCTAssertEqual(reading?.remainingPercent, 61,
                           "the \(key) row shows the pool's shared reading")
        }

        let xai = model.response.platformSections(now: model.now)
            .first(where: { $0.providerKey == "xai" })
        XCTAssertEqual(xai?.windows.first { $0.remainingPercent != nil }?.remainingPercent, 61,
                       "the donor row keeps its own reading")
    }

    func testWithoutADonorTheFailedReadsKeepTheirIssues() async throws {
        let local = LocalQuotaResult(issues: [
            "cursor": "Cursor is not signed in locally.",
            "grok-bot": "Grok Bot quota service is unavailable.",
        ])
        let payload = QuotaResponse(generatedAt: iso.string(from: now), windows: [])

        let model = makeModel(serverEnabled: true)
        model.localReadForTesting = { local }
        model.serverFetchForTesting = { payload }

        model.refresh()
        await model.refreshTaskForTesting?.value

        XCTAssertEqual(model.issues["cursor"], "Cursor is not signed in locally.",
                       "with nothing in the pool the row stays unavailable")
        XCTAssertEqual(model.issues["grok-bot"], "Grok Bot quota service is unavailable.",
                       "with nothing in the pool the row stays unavailable")
        XCTAssertNotNil(model.rowIssue(for: "cursor"), "rowIssue mirrors the raw issue")
        XCTAssertTrue(model.poolServedKeys.isEmpty)
    }

    /// An absolute-only balance is not a pool reading: the pool's donor test
    /// wants a bounded percentage, so a participant holding nothing but a
    /// spend meter keeps its failure on the row too (PR review, kody).
    func testAnAbsoluteOnlyBalanceIsNotCountedAsServed() async throws {
        let iso = ISO8601DateFormatter()
        let spend = QuotaWindow(
            id: "local-mac:cursor:api-credits",
            provider: "Cursor",
            providerKey: "cursor",
            label: "API credits",
            absoluteRemaining: 12.5,
            quotaUnit: "$",
            resetAt: iso.string(from: now.addingTimeInterval(6 * 86_400)),
            window: "monthly",
            occurredAt: iso.string(from: now.addingTimeInterval(-60)),
            source: "Cursor"
        )
        let local = LocalQuotaResult(windows: [spend], issues: [
            "cursor": "Cursor quota service is unavailable.",
        ])
        let payload = QuotaResponse(generatedAt: iso.string(from: now), windows: [])

        let model = makeModel(serverEnabled: true)
        model.localReadForTesting = { local }
        model.serverFetchForTesting = { payload }

        model.refresh()
        await model.refreshTaskForTesting?.value

        XCTAssertEqual(model.rowIssue(for: "cursor"), "Cursor quota service is unavailable.",
                       "a spend meter is not a shared pool reading, so the row stays unavailable")
    }
}
