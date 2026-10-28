import XCTest
@testable import QuotaCore

final class UnifiedSubscriptionPoolTests: XCTestCase {
    private let iso = ISO8601DateFormatter()
    private let now = Date()

    private func makeWindow(providerKey: String, id: String, rem: Double?, resetIn: TimeInterval = 86400 * 6, observedAgo: TimeInterval = 60) -> QuotaWindow {
        QuotaWindow(
            id: id,
            provider: QuotaProviders.label(for: providerKey),
            providerKey: providerKey,
            providerLabel: QuotaProviders.label(for: providerKey),
            sourceApp: id.hasPrefix("local-mac:") ? "local-mac" : nil,
            label: "Subscription window",
            remainingPercent: rem,
            resetAt: iso.string(from: now.addingTimeInterval(resetIn)),
            window: "weekly",
            occurredAt: iso.string(from: now.addingTimeInterval(-observedAgo)),
            source: QuotaProviders.label(for: providerKey)
        )
    }

    func testCursorReadingPopulatesXaiGrokAndGrokBot() {
        let cursor = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 31.5)
        let windows = [cursor]

        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now, targetKeys: UnifiedSubscriptionPool.participantKeys)
        let byProvider = Dictionary(grouping: shared, by: \.canonicalProviderKey)

        XCTAssertNotNil(byProvider["xai"]?.first, "xAI must receive an adapted pool window")
        XCTAssertEqual(byProvider["xai"]?.first?.remainingPercent, 31.5)
        XCTAssertEqual(byProvider["xai"]?.first?.id, "local-mac:xai:plan")

        XCTAssertNotNil(byProvider["grok"]?.first, "Grok must receive an adapted pool window")
        XCTAssertEqual(byProvider["grok"]?.first?.remainingPercent, 31.5)

        XCTAssertNotNil(byProvider["grok-bot"]?.first, "Grok Bot must receive an adapted pool window")
        XCTAssertEqual(byProvider["grok-bot"]?.first?.remainingPercent, 31.5)

        XCTAssertEqual(byProvider["cursor"]?.first?.remainingPercent, 31.5)
    }

    func testGrokReadingPopulatesCursorXaiAndGrokBot() {
        let grok = makeWindow(providerKey: "grok", id: "local-mac:grok:subscription", rem: 50.0)
        let windows = [grok]

        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now, targetKeys: UnifiedSubscriptionPool.participantKeys)
        let byProvider = Dictionary(grouping: shared, by: \.canonicalProviderKey)

        XCTAssertEqual(byProvider["cursor"]?.first?.remainingPercent, 50.0)
        XCTAssertEqual(byProvider["xai"]?.first?.remainingPercent, 50.0)
        XCTAssertEqual(byProvider["grok-bot"]?.first?.remainingPercent, 50.0)
        XCTAssertEqual(byProvider["grok"]?.first?.remainingPercent, 50.0)
    }

    func testGrokBotReadingPopulatesCursorXaiAndGrok() {
        let grokBot = makeWindow(providerKey: "grok-bot", id: "local-mac:grok-bot:weekly", rem: 42.0)
        let windows = [grokBot]

        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now, targetKeys: UnifiedSubscriptionPool.participantKeys)
        let byProvider = Dictionary(grouping: shared, by: \.canonicalProviderKey)

        XCTAssertEqual(byProvider["cursor"]?.first?.remainingPercent, 42.0)
        XCTAssertEqual(byProvider["xai"]?.first?.remainingPercent, 42.0)
        XCTAssertEqual(byProvider["grok"]?.first?.remainingPercent, 42.0)
    }

    func testXaiReadingPopulatesCursorGrokAndGrokBot() {
        let xai = makeWindow(providerKey: "xai", id: "xai:subscription", rem: 88.0)
        let windows = [xai]

        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now, targetKeys: UnifiedSubscriptionPool.participantKeys)
        let byProvider = Dictionary(grouping: shared, by: \.canonicalProviderKey)

        XCTAssertEqual(byProvider["cursor"]?.first?.remainingPercent, 88.0)
        XCTAssertEqual(byProvider["grok"]?.first?.remainingPercent, 88.0)
        XCTAssertEqual(byProvider["grok-bot"]?.first?.remainingPercent, 88.0)
    }

    func testFreshestReadingWinsAmongMultipleParticipants() {
        let olderCursor = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 60.0, observedAgo: 3600)
        let newerGrok = makeWindow(providerKey: "grok", id: "local-mac:grok:subscription", rem: 55.0, observedAgo: 60)
        let windows = [olderCursor, newerGrok]

        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now, targetKeys: UnifiedSubscriptionPool.participantKeys)
        let byProvider = Dictionary(grouping: shared, by: \.canonicalProviderKey)

        // The 55.0% reading is fresher (60s ago vs 3600s ago)
        XCTAssertEqual(byProvider["cursor"]?.first?.remainingPercent, 55.0)
        XCTAssertEqual(byProvider["xai"]?.first?.remainingPercent, 55.0)
        XCTAssertEqual(byProvider["grok"]?.first?.remainingPercent, 55.0)
        XCTAssertEqual(byProvider["grok-bot"]?.first?.remainingPercent, 55.0)
    }

    func testStaleReadingIsOverwrittenByFreshReading() {
        let staleXai = makeWindow(providerKey: "xai", id: "xai:subscription", rem: 10.0, observedAgo: 86400 * 2)
        let freshCursor = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 75.0, observedAgo: 120)
        let windows = [staleXai, freshCursor]

        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now)
        let byProvider = Dictionary(grouping: shared, by: \.canonicalProviderKey)

        XCTAssertEqual(byProvider["xai"]?.first?.remainingPercent, 75.0, "xAI stale reading must be updated by fresh Cursor reading")
        XCTAssertEqual(byProvider["cursor"]?.first?.remainingPercent, 75.0)
    }

    func testApiCreditsAreNotPartOfTheSubscriptionPool() {
        let apiWindow = QuotaWindow(
            id: "xai:api-monthly",
            provider: "xAI",
            providerKey: "xai",
            providerLabel: "xAI",
            label: "API credits",
            remainingPercent: 12.0,
            occurredAt: iso.string(from: now)
        )
        let cursor = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 80.0)
        let windows = [apiWindow, cursor]

        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now)
        let apiResult = shared.first { $0.id == "xai:api-monthly" }

        XCTAssertEqual(apiResult?.remainingPercent, 12.0, "API credits window must remain untouched")
        XCTAssertEqual(apiResult?.label, "API credits")
    }

    func testBillingCycleAndCurrencyWindowsAreExcludedFromPool() {
        var billingWindow = makeWindow(providerKey: "cursor", id: "cursor:billing-cycle", rem: 5.0)
        billingWindow.label = "Billing cycle spend"
        billingWindow.quotaUnit = "USD"
        let cursorPlan = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 90.0)
        let windows = [billingWindow, cursorPlan]

        XCTAssertFalse(UnifiedSubscriptionPool.isPoolWindow(billingWindow), "Billing cycle window must not be considered a pool window")
        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now)
        let preservedBilling = shared.first { $0.id == "cursor:billing-cycle" }
        XCTAssertEqual(preservedBilling?.remainingPercent, 5.0, "Billing cycle window must remain untouched")
    }

    func testMultiAccountWindowsAreExcludedFromPool() {
        var accountWindow = makeWindow(providerKey: "grok-bot", id: "gbu-weekly:account-123", rem: 15.0)
        accountWindow.label = "Account allowance"
        let cursorPlan = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 88.0)
        let windows = [accountWindow, cursorPlan]

        XCTAssertFalse(UnifiedSubscriptionPool.isPoolWindow(accountWindow), "Multi-account window must not be considered a pool window")
        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now)
        let preservedAccount = shared.first { $0.id == "gbu-weekly:account-123" }
        XCTAssertEqual(preservedAccount?.remainingPercent, 15.0, "Multi-account window must remain untouched")
    }
    func testAbsoluteOnlyDonorDoesNotErasePercentage() {
        var absoluteOnly = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: nil, observedAgo: 1)
        absoluteOnly.absoluteRemaining = 100
        let xai = makeWindow(providerKey: "xai", id: "xai:subscription", rem: 60, observedAgo: 60)
        let shared = UnifiedSubscriptionPool.share(windows: [absoluteOnly, xai], now: now)
        XCTAssertEqual(shared.first { $0.canonicalProviderKey == "xai" }?.remainingPercent, 60)
        XCTAssertEqual(UnifiedSubscriptionPool.freshestReading(in: [absoluteOnly, xai], now: now)?.id, xai.id)
    }

    func testRemoteAdaptationPreservesOrigin() {
        var remote = makeWindow(providerKey: "cursor", id: "studio:cursor:plan", rem: 55)
        remote.sourceApp = "codecaps"
        remote.source = "studio"
        let adapted = UnifiedSubscriptionPool.adapt(remote, for: "xai")
        XCTAssertNotEqual(adapted.id, remote.id)
        XCTAssertFalse(adapted.id.hasPrefix("local-mac:"))
        XCTAssertTrue(adapted.id.hasSuffix(":xai:plan"))
        XCTAssertEqual(adapted.sourceApp, remote.sourceApp)
        XCTAssertEqual(adapted.source, remote.source)
        XCTAssertEqual(adapted.canonicalProviderKey, "xai")
    }

    func testRemoteLocalStyleIDIsNotRelabeledAsThisMac() {
        var remote = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 55)
        remote.sourceApp = "codecaps"
        remote.machine = "Studio"
        let adapted = UnifiedSubscriptionPool.adapt(remote, for: "xai")
        XCTAssertNotEqual(adapted.id, remote.id)
        XCTAssertFalse(adapted.id.hasPrefix("local-mac:"))
        XCTAssertTrue(adapted.id.hasSuffix(":xai:plan"))
        XCTAssertEqual(adapted.machine, remote.machine)
        XCTAssertEqual(adapted.sourceApp, remote.sourceApp)
    }

    func testRemoteSharedParticipantsHaveUniqueTargetIDsAndPreserveProvenance() {
        var remote = makeWindow(providerKey: "cursor", id: "studio:cursor:plan", rem: 55)
        remote.producerInstanceId = "studio-instance"
        remote.machine = "Studio"
        remote.source = "studio"
        remote.sourceApp = "codecaps"
        let shared = UnifiedSubscriptionPool.share(windows: [remote], now: now,
                                                   targetKeys: UnifiedSubscriptionPool.participantKeys)
        XCTAssertEqual(Set(shared.map(\.id)).count, 4)
        for window in shared where window.canonicalProviderKey != "cursor" {
            XCTAssertFalse(window.id.hasPrefix("local-mac:"))
            XCTAssertFalse(window.id.contains(":cursor:"))
            XCTAssertTrue(window.id.contains(":\(window.canonicalProviderKey):"))
            XCTAssertEqual(window.producerInstanceId, remote.producerInstanceId)
            XCTAssertEqual(window.machine, remote.machine)
            XCTAssertEqual(window.source, remote.source)
            XCTAssertEqual(window.sourceApp, remote.sourceApp)
            XCTAssertEqual(window.remainingPercent, 55)
        }
    }

    func testMissingSourceAppIsNotInventedDuringAdaptation() {
        let remote = makeWindow(providerKey: "grok", id: "server:grok:subscription", rem: 55)
        XCTAssertNil(UnifiedSubscriptionPool.adapt(remote, for: "cursor").sourceApp)
    }

}
