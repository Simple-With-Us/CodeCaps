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
}
