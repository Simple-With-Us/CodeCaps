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
}
