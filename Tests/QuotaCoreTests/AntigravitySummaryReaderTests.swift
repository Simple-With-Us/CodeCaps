import Foundation
import XCTest
@testable import QuotaCore

final class AntigravitySummaryReaderTests: XCTestCase {
    func testMapsOnlyExplicitGroupedWindows() async {
        let reader = AntigravitySummaryReader(fetchSummary: {
            Data(#"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly Limit","window":"weekly","remainingFraction":0.8,"resetTime":"2026-09-20T00:00:00Z"},{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.4,"resetTime":"2026-09-13T12:00:00Z"}]},{"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.7},{"bucketId":"3p-5h","window":"5h","remainingFraction":0.2}]}]}}"#.utf8)
        })
        let result = await reader.read()
        XCTAssertEqual(result.windows.count, 4)
        XCTAssertEqual(result.windows.first(where: { $0.window == "weekly" && $0.label.hasPrefix("Gemini") })?.remainingPercent, 80)
        XCTAssertEqual(result.windows.first(where: { $0.window == "5h" && $0.label.hasPrefix("Third") })?.remainingPercent, 20)
        XCTAssertTrue(result.windows.allSatisfy { $0.providerKey == "google-antigravity" && $0.sourceApp == "local-mac" })
    }

    func testUnknownOrOversizedSummaryIsUnavailable() async {
        let reader = AntigravitySummaryReader(fetchSummary: { Data(#"{"response":{"groups":[{"displayName":"Other","buckets":[]}]}}"#.utf8) })
        let result = await reader.read()
        XCTAssertEqual(result.issues["google-antigravity"], "Antigravity grouped quota is unavailable.")
    }

    /// A bucket that reports no fraction means none remains, not that the
    /// reading is unknown.  Owner 2026-09-04: an omitted remaining value (N/A
    /// in the provider's table) means the allowance is spent, so "treat as
    /// exhausted 0%, not 'unknown' and not 100%".  The Usage Monitor collector
    /// and BotFleet's `isAntigravityModelCapped` both say the same thing.
    ///
    /// Reading it as unknown is what let the Mac show quota that was not
    /// there: the weekly dropped out of its pool's count and the five-hour
    /// window drove the pool's headline instead.
    func testABucketWithNoFractionIsExhaustedRatherThanUnknown() async {
        let reader = AntigravitySummaryReader(fetchSummary: {
            Data(#"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly Limit","window":"weekly","resetTime":"2026-09-20T00:00:00Z"},{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.4,"resetTime":"2026-09-13T12:00:00Z"}]}]}}"#.utf8)
        })
        let result = await reader.read()
        let weekly = result.windows.first { $0.window == "weekly" }
        XCTAssertEqual(weekly?.remainingPercent, 0)
        XCTAssertEqual(weekly?.remainingUnknown, false)
        XCTAssertEqual(weekly?.isExhausted, true)
        XCTAssertEqual(weekly?.boundedRemainingPercent, 0)
        // The five-hour window still reports what it knows.
        XCTAssertEqual(result.windows.first { $0.window == "5h" }?.remainingPercent, 40)
    }

    func testCLICommandPayloadKeepsBothPoolsAndCadences() async {
        let reader = AntigravitySummaryReader(fetchSummary: { Data(Self.cliSummary.utf8) })
        let result = await reader.read()
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.windows.count, 4)
        let pools = AntigravityQuotaGroups.normalize(result.windows)
        XCTAssertEqual(pools.count, 4)
        XCTAssertEqual(pools.first { $0.id == "antigravity:gemini:weekly" }?.remainingPercent ?? -1, 34.19, accuracy: 0.001)
        XCTAssertEqual(pools.first { $0.id == "antigravity:gemini:5h" }?.remainingPercent ?? -1, 68.45, accuracy: 0.001)
        XCTAssertEqual(result.windows.first { $0.id.hasSuffix("gemini-weekly") }?.resetAt, "2026-11-15T05:46:00Z")
        XCTAssertEqual(pools.first { $0.id == "antigravity:third-party:weekly" }?.remainingPercent, 0)
        XCTAssertEqual(pools.first { $0.id == "antigravity:third-party:weekly" }?.isExhausted, true)
    }

    func testDefaultTransportRunsInstalledCLIQuotaCommand() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let bin = home.appendingPathComponent(".local/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("agy")
        // Fail if the reader invokes an agent prompt or changes the quota-only command.
        let script = """
        #!/bin/sh
        [ "$#" = 4 ] && [ "$1" = '-p' ] && [ "$2" = '/usage' ] && [ "$3" = '--output-format' ] && [ "$4" = 'json' ] || exit 1
        printf '%s' '\(Self.cliSummary)'
        """
        try Data(script.utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let result = await AntigravitySummaryReader(homeDirectory: home).read()
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertEqual(result.windows.count, 4)
        XCTAssertEqual(result.windows.first { $0.id.hasSuffix("gemini-5h") }?.remainingPercent ?? -1, 68.45, accuracy: 0.001)
    }

    func testFailedCLIEnvelopeCannotSupplyQuota() async {
        let reader = AntigravitySummaryReader(fetchSummary: {
            Data(Self.cliSummary.replacingOccurrences(of: "SUCCESS", with: "ERROR").utf8)
        })
        let result = await reader.read()
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertNotNil(result.issues["google-antigravity"])
    }

    private static let cliSummary = #"{"status":"SUCCESS","command":{"name":"usage","data":{"groups":[{"id":"gemini","name":"Gemini Models","buckets":[{"id":"gemini-weekly","window":"weekly","remaining_fraction":0.3419,"reset_time":"2026-11-15T05:46:00Z"},{"id":"gemini-5h","window":"5h","remaining_fraction":0.6845}]},{"id":"third-party","name":"Claude and GPT models","buckets":[{"id":"third-party-weekly","window":"weekly"},{"id":"third-party-5h","window":"5h","remaining_fraction":0.6}]}]}}}"#

}
