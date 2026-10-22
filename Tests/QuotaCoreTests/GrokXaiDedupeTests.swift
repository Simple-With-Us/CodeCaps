import XCTest
@testable import QuotaCore

/// The same Grok credits pool arrives as `grok` (local CLI reader) and as
/// `xai:subscription` (fleet collector).  Only the fresher may survive.
final class GrokXaiDedupeTests: XCTestCase {
    private func window(providerKey: String, id: String, occurredAt: String, label: String = "Weekly window") -> QuotaWindow {
        QuotaWindow(id: id, provider: providerKey, providerKey: providerKey, label: label,
                    remainingPercent: 50, occurredAt: occurredAt, source: "test")
    }

    func testFresherLocalGrokDropsStaleFleetXai() {
        let windows = [
            window(providerKey: "grok", id: "local-mac:grok:subscription", occurredAt: "2026-10-22T03:00:00Z"),
            window(providerKey: "xai", id: "xai:subscription", occurredAt: "2026-10-21T22:02:00Z"),
        ]
        let result = QuotaResponse.dedupedGrokSubscription(windows)
        XCTAssertEqual(result.map(\.id), ["local-mac:grok:subscription"])
    }

    func testFresherFleetXaiDropsStaleLocalGrok() {
        let windows = [
            window(providerKey: "grok", id: "local-mac:grok:subscription", occurredAt: "2026-10-21T20:00:00Z"),
            window(providerKey: "xai", id: "xai:subscription", occurredAt: "2026-10-22T01:00:00Z"),
        ]
        let result = QuotaResponse.dedupedGrokSubscription(windows)
        XCTAssertEqual(result.map(\.id), ["xai:subscription"])
    }

    func testOtherXaiWindowsAreUntouched() {
        let windows = [
            window(providerKey: "grok", id: "local-mac:grok:subscription", occurredAt: "2026-10-22T03:00:00Z"),
            window(providerKey: "xai", id: "xai:api-monthly", occurredAt: "2026-10-21T22:02:00Z", label: "API credits"),
        ]
        XCTAssertEqual(QuotaResponse.dedupedGrokSubscription(windows).count, 2)
    }

    func testSingleSidedPoolIsUntouched() {
        let windows = [window(providerKey: "xai", id: "xai:subscription", occurredAt: "2026-10-21T22:02:00Z")]
        XCTAssertEqual(QuotaResponse.dedupedGrokSubscription(windows).count, 1)
    }

    /// The pool is identified by canonical identity, not by a suffix, so an
    /// unrelated window whose id merely ends in `:subscription` cannot stand
    /// in for it and delete the real reading.
    func testAnUnrelatedSubscriptionSuffixIsNotThePool() {
        let windows = [
            window(providerKey: "grok", id: "grok:legacy:subscription", occurredAt: "2026-10-22T03:00:00Z"),
            window(providerKey: "xai", id: "xai:subscription", occurredAt: "2026-10-21T22:02:00Z"),
        ]
        let result = QuotaResponse.dedupedGrokSubscription(windows)
        XCTAssertEqual(result.map(\.id).sorted(), ["grok:legacy:subscription", "xai:subscription"])
    }

    /// The fleet reading arriving in `providerGroups` — the additive manifest
    /// path — must not re-add the duplicate the dedupe just dropped.
    func testDedupeSurvivesTheProviderGroupsMerge() {
        let local = window(providerKey: "grok", id: "local-mac:grok:subscription", occurredAt: "2026-10-22T03:00:00Z")
        let fleet = window(providerKey: "xai", id: "xai:subscription", occurredAt: "2026-10-21T22:02:00Z")
        let response = QuotaResponse(
            generatedAt: "2026-10-22T03:00:00Z",
            windows: [local],
            providerGroups: [
                QuotaProviderGroup(provider: "xai", providerLabel: "xAI", expected: true, windows: [fleet]),
            ])
        let subscriptionWindows = response.platformSections(now: Date())
            .flatMap(\.windows)
            .map(\.window.id)
            .filter { $0.contains("subscription") }
            .sorted()
        XCTAssertEqual(subscriptionWindows, ["local-mac:grok:subscription"],
                       "one credits pool must stay one row after the group merge")
    }
}
