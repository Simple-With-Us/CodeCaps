import Foundation
import XCTest
@testable import QuotaCore

final class PlanMetadataExportTests: XCTestCase {
    private func window() -> QuotaWindow {
        var window = QuotaWindow(id: "local-mac:openai:primary", provider: "openai", label: "Quota",
                                 remainingPercent: 42, planName: "Plus", occurredAt: "2026-10-20T12:00:00Z")
        window.planMetadata = PlanMetadata(detectedPlanName: window.planName,
            customInfo: PlatformCustomInfo(customSubtitle: "Work", planName: "Pro", costUsd: "$200",
                                          renewalDateText: "November 1", showCostAndRenewal: true),
            providerKey: "openai")
        window.accountKey = "private-account"
        return window
    }

    func testLegacyWindowDecodesWithoutMetadata() throws {
        let data = Data(#"{"id":"old","provider":"openai"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(QuotaWindow.self, from: data).planMetadata)
    }

    func testOptionalMetadataCannotDiscardUsableLegacyQuota() throws {
        let partial = Data(#"{"id":"partial","provider":"openai","remainingPercent":42,"planMetadata":{"detectedPlanName":"Plus"}}"#.utf8)
        let decoded = try JSONDecoder().decode(QuotaWindow.self, from: partial)
        XCTAssertEqual(decoded.remainingPercent, 42)
        XCTAssertEqual(decoded.planMetadata?.detectedPlanName, "Plus")
        XCTAssertFalse(decoded.planMetadata?.hasMismatch ?? true)
        let invalid = Data(#"{"id":"invalid","provider":"openai","remainingPercent":42,"planMetadata":[]}"#.utf8)
        let fallback = try JSONDecoder().decode(QuotaWindow.self, from: invalid)
        XCTAssertEqual(fallback.remainingPercent, 42)
        XCTAssertNil(fallback.planMetadata)
    }

    func testSnapshotRoundTripsSeparateDetectedAndEnteredPlansWithoutLocalIdentity() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try LocalQuotaSnapshot.write(windows: [window()], to: url)
        let data = try Data(contentsOf: url)
        let payload = try JSONDecoder().decode(LocalQuotaSnapshot.Payload.self, from: data)
        XCTAssertEqual(payload.windows.first?.planName, "Plus")
        XCTAssertEqual(payload.windows.first?.planMetadata?.detectedPlanName, "Plus")
        XCTAssertEqual(payload.windows.first?.planMetadata?.userPlanName, "Pro")
        XCTAssertTrue(payload.windows.first?.planMetadata?.hasMismatch == true)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("private-account"))
        XCTAssertNil(payload.windows.first?.accountKey)
    }

    func testBothPublisherFormatsCarryPlanMetadata() throws {
        let publisher = QuotaPublisher()
        let v2 = try publisher.buildUsageMonitorV2Payload(windows: [window()], occurredAtIso: "2026-10-20T12:00:00Z")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: v2) as? [String: Any])
        let events = try XCTUnwrap(root["events"] as? [[String: Any]])
        let metadata = try XCTUnwrap(events.first?["metadata"] as? [String: Any])
        XCTAssertNil(metadata["planMetadata"])
        XCTAssertEqual(metadata["planDetectedName"] as? String, "Plus")
        XCTAssertEqual(metadata["planUserName"] as? String, "Pro")
        let generic = try publisher.buildGenericWebhookPayload(windows: [window()], occurredAtIso: "2026-10-20T12:00:00Z", machineName: "Test")
        let webhook = try XCTUnwrap(JSONSerialization.jsonObject(with: generic) as? [String: Any])
        let windows = try XCTUnwrap(webhook["windows"] as? [[String: Any]])
        XCTAssertEqual((windows.first?["planMetadata"] as? [String: Any])?["userCostUsd"] as? String, "$200")
    }
    func testMetadataOnlyEventHasNoFictitiousQuotaAndChangesIdentityWhenSettingsChange() throws {
        let publisher = QuotaPublisher()
        var input = window()
        input.remainingPercent = nil
        input.remainingUnknown = true
        func event(_ window: QuotaWindow) throws -> [String: Any] {
            let data = try publisher.buildUsageMonitorV2Payload(windows: [window], occurredAtIso: "2026-10-20T12:00:00Z", producerInstanceId: "test")
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return try XCTUnwrap((root["events"] as? [[String: Any]])?.first)
        }
        let first = try event(input)
        XCTAssertLessThanOrEqual(try XCTUnwrap(first["eventId"] as? String).count, 200)
        XCTAssertNil(first["credits"])
        XCTAssertNil(first["limit"])
        let metadata = try XCTUnwrap(first["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["remainingUnknown"] as? Bool, true)
        XCTAssertEqual(metadata["isExhausted"] as? Bool, false)
        XCTAssertNil(metadata["usedPercent"])
        input.planMetadata?.userUpdatedAt = 1_792_497_600.001
        let revised = try event(input)
        XCTAssertNotEqual(first["eventId"] as? String, revised["eventId"] as? String)
        XCTAssertEqual(first["occurredAt"] as? String, revised["occurredAt"] as? String)
        input.planMetadata?.userCostUsd = "$100"
        XCTAssertNotEqual(first["eventId"] as? String, try event(input)["eventId"] as? String)
        XCTAssertEqual(try event(input)["eventId"] as? String, try event(input)["eventId"] as? String)
    }

    func testMetadataExportPreservesExplicitExhaustionWithoutNumericQuota() throws {
        var input = window()
        input.remainingPercent = nil
        input.remainingUnknown = true
        input.isExhausted = true
        let data = try QuotaPublisher().buildUsageMonitorV2Payload(windows: [input], occurredAtIso: input.occurredAt)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let events = try XCTUnwrap(root["events"] as? [[String: Any]])
        XCTAssertEqual((events.first?["metadata"] as? [String: Any])?["isExhausted"] as? Bool, true)
    }

}
