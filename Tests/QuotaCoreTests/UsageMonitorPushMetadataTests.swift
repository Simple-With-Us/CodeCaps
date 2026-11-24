import XCTest
@testable import QuotaCore

final class UsageMonitorPushMetadataTests: XCTestCase {
    func testAnthropicLocalMacIdMapsToCollectorBucket() {
        let window = QuotaWindow(
            id: "local-mac:anthropic:five_hour",
            provider: "Claude",
            providerKey: "anthropic",
            label: "5h window",
            remainingPercent: 50,
            window: "5h",
            occurredAt: "2026-09-14T19:00:00Z"
        )
        XCTAssertEqual(UsageMonitorPushMetadata.bucketId(for: window), "anthropic:five_hour")
        XCTAssertEqual(UsageMonitorPushMetadata.quotaWindow(for: window), "5h")
    }

    func testAnthropicOpusWeeklyBucket() {
        let window = QuotaWindow(
            id: "local-mac:anthropic:seven_day_opus",
            provider: "Claude",
            providerKey: "anthropic",
            label: "7d window (Opus)",
            remainingPercent: 0,
            window: "7d",
            occurredAt: "2026-09-14T19:00:00Z"
        )
        XCTAssertEqual(UsageMonitorPushMetadata.bucketId(for: window), "anthropic:seven_day_opus")
    }

    func testCodexSlotBucket() {
        let window = QuotaWindow(
            id: "local-mac:openai:primary",
            provider: "Codex",
            providerKey: "openai",
            label: "5h window",
            remainingPercent: 80,
            window: "5h",
            occurredAt: "2026-09-14T19:00:00Z"
        )
        XCTAssertEqual(UsageMonitorPushMetadata.bucketId(for: window), "openai:primary")
    }

    func testGrokSubscriptionBucket() {
        let window = QuotaWindow(
            id: "local-mac:xai:subscription",
            provider: "Grok",
            providerKey: "xai",
            label: "Subscription window",
            remainingPercent: 40,
            window: "7d",
            occurredAt: "2026-09-14T19:00:00Z"
        )
        XCTAssertEqual(UsageMonitorPushMetadata.bucketId(for: window), "xai:subscription")
    }

    func testGrokBotGbuWeeklyBucket() {
        let window = QuotaWindow(
            id: "local-mac:grok-bot:gbu-weekly",
            provider: "Grok Bot",
            providerKey: "grok-bot",
            label: "Grok Bot weekly",
            remainingPercent: 10,
            window: "weekly",
            occurredAt: "2026-09-14T19:00:00Z"
        )
        XCTAssertEqual(UsageMonitorPushMetadata.bucketId(for: window), "gbu-weekly")
    }

    func testMinimaxIntervalAndWeeklyBuckets() {
        let interval = QuotaWindow(
            id: "local-mac:minimax:general:interval",
            provider: "MiniMax",
            providerKey: "minimax",
            modelId: "general",
            label: "5-hour window",
            remainingPercent: 90,
            window: "5h",
            occurredAt: "2026-09-14T19:00:00Z"
        )
        let weekly = QuotaWindow(
            id: "local-mac:minimax:general:weekly",
            provider: "MiniMax",
            providerKey: "minimax",
            modelId: "general",
            label: "weekly window",
            remainingPercent: 50,
            window: "weekly",
            occurredAt: "2026-09-14T19:00:00Z"
        )
        XCTAssertEqual(UsageMonitorPushMetadata.bucketId(for: interval), "minimax:general")
        XCTAssertEqual(UsageMonitorPushMetadata.bucketId(for: weekly), "minimax:general:weekly")
        XCTAssertEqual(UsageMonitorPushMetadata.quotaWindow(for: interval), "5h")
        XCTAssertEqual(UsageMonitorPushMetadata.quotaWindow(for: weekly), "weekly")
    }

    func testGrokBotFallbackBucketUsesGbuWeekly() {
        let window = QuotaWindow(
            id: "remote:grok-bot:orphan",
            provider: "Grok Bot",
            providerKey: "grok-bot",
            label: "Grok Bot weekly",
            remainingPercent: 0,
            window: nil,
            occurredAt: "2026-09-14T19:00:00Z"
        )
        XCTAssertEqual(UsageMonitorPushMetadata.bucketId(for: window), "gbu-weekly")
    }

    func testPublisherPayloadCarriesStableMetadata() throws {
        let publisher = QuotaPublisher()
        let window = QuotaWindow(
            id: "local-mac:anthropic:seven_day",
            provider: "Claude",
            providerKey: "anthropic",
            label: "7d window",
            remainingPercent: 12,
            window: "7d",
            occurredAt: "2026-09-14T19:00:00Z",
            source: "local"
        )
        let data = try publisher.buildUsageMonitorV2Payload(
            windows: [window],
            occurredAtIso: "2026-09-14T19:00:00Z",
            machineName: "Test-Mac",
            producerInstanceId: "test-instance"
        )
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let meta = try XCTUnwrap(events[0]["metadata"] as? [String: Any])
        XCTAssertEqual(meta["bucketId"] as? String, "anthropic:seven_day")
        XCTAssertEqual(meta["quotaWindow"] as? String, "7d")
        XCTAssertEqual(meta["source"] as? String, "codecaps")
        XCTAssertEqual(meta["machine"] as? String, "Test-Mac")
    }

    func testAntigravityPoolWindowsKeepDistinctBuckets() {
        func pooled(_ family: String, _ period: String) -> QuotaWindow {
            QuotaWindow(
                id: "antigravity:\(family):\(period)",
                provider: "Antigravity",
                providerKey: "google-antigravity",
                modelType: family,
                label: "\(family) \(period)",
                remainingPercent: 50,
                window: period,
                occurredAt: "2026-11-24T19:00:00Z"
            )
        }
        let buckets = [pooled("gemini", "5h"), pooled("gemini", "weekly"),
                       pooled("third-party", "5h"), pooled("third-party", "weekly")]
            .map { UsageMonitorPushMetadata.bucketId(for: $0) }
        XCTAssertEqual(buckets, ["gemini-5h", "gemini-weekly", "3p-5h", "3p-weekly"])
        XCTAssertEqual(Set(buckets).count, 4)
    }

    func testAntigravityBucketsNormalizeCadenceAndServerStyleFamilies() {
        func pooled(_ id: String, _ family: String?, _ token: String) -> QuotaWindow {
            QuotaWindow(id: id, provider: "Antigravity", providerKey: "google-antigravity",
                        modelType: family, label: "x", remainingPercent: 50, window: token,
                        occurredAt: "2026-11-24T19:00:00Z")
        }
        XCTAssertEqual(UsageMonitorPushMetadata.bucketId(for: pooled("antigravity:gemini:weekly", "gemini", "7d")), "gemini-weekly")
        XCTAssertEqual(UsageMonitorPushMetadata.bucketId(for: pooled("antigravity:gemini:weekly", "gemini", "weekly")), "gemini-weekly")
        XCTAssertEqual(UsageMonitorPushMetadata.bucketId(for: pooled("x", "3p-5h", "5h")), "3p-5h")
        XCTAssertEqual(UsageMonitorPushMetadata.bucketId(for: pooled("x", "3p-weekly", "weekly")), "3p-weekly")
    }
}
