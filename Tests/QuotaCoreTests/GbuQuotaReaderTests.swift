import Foundation
import XCTest
@testable import QuotaCore

final class GbuQuotaReaderTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_789_000_000)

    func testParsesWeeklyRemainingFromGbuJson() async {
        let json = """
        {"active":"mail@example.com","accounts":[{"account":"mail@example.com","email":"mail@example.com","active":true,"weeklyUsagePercent":85.37,"available":true,"resetsAt":"2026-09-28T18:35:19.304Z","planLabel":"Grok Bot Plan","includedSpend":33262,"includedLimit":40000,"includedRemaining":6738,"onDemandUsed":0}]}
        """
        let reader = GbuQuotaReader(
            now: { self.observedAt },
            runGbu: { Data(json.utf8) }
        )
        let result = await reader.read()
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.windows.count, 1)
        let window = result.windows[0]
        XCTAssertEqual(window.providerKey, "grok-bot")
        XCTAssertEqual(window.source, "gbu")
        XCTAssertEqual(window.via, "gbu")
        XCTAssertEqual(window.sourceApp, "local-mac")
        XCTAssertEqual(window.id, "local-mac:grok-bot:gbu-weekly")
        XCTAssertEqual(window.label, "Grok Bot weekly")
        XCTAssertEqual(window.remainingPercent!, 14.63, accuracy: 0.001)
        XCTAssertEqual(window.planName, "Grok Bot Plan")
        XCTAssertEqual(window.window, "weekly")
        XCTAssertEqual(window.absoluteRemaining, 6738)
        XCTAssertEqual(window.absoluteLimit, 40000)
        XCTAssertEqual(window.resetAt, "2026-09-28T18:35:19.304Z")
        XCTAssertFalse(window.isExhausted)
        XCTAssertEqual(window.status, .nearCap)
    }

    func testUnavailableAccountIsExhausted() async {
        let json = """
        {"active":"a@example.com","accounts":[{"account":"a@example.com","email":"a@example.com","active":true,"weeklyUsagePercent":100,"available":false,"resetsAt":"2026-09-28T18:35:19.304Z"}]}
        """
        let reader = GbuQuotaReader(now: { self.observedAt }, runGbu: { Data(json.utf8) })
        let result = await reader.read()
        XCTAssertEqual(result.windows[0].remainingPercent, 0)
        XCTAssertTrue(result.windows[0].isExhausted)
        XCTAssertEqual(result.windows[0].status, .exhausted)
    }

    func testFailureDoesNotPolluteGrokBotIssueKey() async {
        // Issues stay under "gbu" so a failed EXTRA source cannot blank the
        // Cursor DashboardService row keyed by "grok-bot".
        let failing = GbuQuotaReader(runGbu: { throw URLError(.cannotFindHost) })
        let result = await failing.read()
        XCTAssertEqual(result.issues["gbu"], "gbu quota source is unavailable.")
        XCTAssertNil(result.issues["grok-bot"])
        XCTAssertTrue(result.windows.isEmpty)
    }

    func testMissingBinaryHomeIsSilentOptionalExtra() async {
        let emptyHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("gbu-reader-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: emptyHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: emptyHome) }
        let reader = GbuQuotaReader(homeDirectory: emptyHome)
        let result = await reader.read()
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testMalformedJsonYieldsUnknownWindowUnderGbuSource() async {
        let reader = GbuQuotaReader(now: { self.observedAt }, runGbu: { Data("not-json".utf8) })
        let result = await reader.read()
        XCTAssertEqual(result.issues["gbu"], "gbu returned no readable quota JSON.")
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertNil(result.issues["grok-bot"])
    }

    func testSecondaryAccountGetsDistinctId() async {
        let json = """
        {"active":"a@example.com","accounts":[{"account":"a@example.com","email":"a@example.com","active":true,"weeklyUsagePercent":10,"available":true,"resetsAt":"2026-09-28T18:35:19.304Z"},{"account":"b@example.com","email":"b@example.com","active":false,"weeklyUsagePercent":50,"available":true,"resetsAt":"2026-09-28T18:35:19.304Z"}]}
        """
        let reader = GbuQuotaReader(now: { self.observedAt }, runGbu: { Data(json.utf8) })
        let result = await reader.read()
        XCTAssertEqual(result.windows.map(\.id), [
            "local-mac:grok-bot:gbu-weekly",
            "local-mac:grok-bot:gbu-weekly:b@example.com",
        ])
        XCTAssertEqual(result.windows.map(\.source), ["gbu", "gbu"])
    }
}

