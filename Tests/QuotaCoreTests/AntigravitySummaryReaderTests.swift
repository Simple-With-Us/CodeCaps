import Foundation
import XCTest
@testable import QuotaCore

final class AntigravitySummaryReaderTests: XCTestCase {
    func testMapsOnlyExplicitGroupedWindows() async {
        let reader = AntigravitySummaryReader(fetchSummary: {
            Data(#"{"response":{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly Limit","window":"weekly","remainingFraction":0.8,"resetTime":"2026-09-20T00:00:00Z"},{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.4,"resetTime":"2026-09-13T12:00:00Z"}]},{"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.7},{"bucketId":"3p-5h","window":"5h","remainingFraction":0.2}]}]}}"#.utf8)
        })
    10|        let result = await reader.read()
        XCTAssertEqual(result.windows.count, 4)
        XCTAssertEqual(result.windows.first(where: { $0.window == "weekly" && $0.label.hasPrefix("Gemini") })?.remainingPercent, 80)
        XCTAssertEqual(result.windows.first(where: { $0.window == "5h" && $0.label.hasPrefix("Third") })?.remainingPercent, 20)
        XCTAssertTrue(result.windows.allSatisfy { $0.providerKey == "google-antigravity" && $0.sourceApp == "local-mac" })
    }

    func testUnknownOrOversizedSummaryIsUnavailable() async {
        let reader = AntigravitySummaryReader(fetchSummary: { Data(#"{"response":{"groups":[{"displayName":"Other","buckets":[]}]}}"#.utf8) })
        let result = await reader.read()
    20|        XCTAssertEqual(result.issues["google-antigravity"], "Antigravity grouped quota is unavailable.")
    }

    /// Audit fix #5: a 4xx on the first attempt is the server answering.  The
    /// fan-out stops at once and returns nil so the outer loop can move on to
    /// the next candidate instead of hammering ports past the deadline.
    func testAttemptCandidateShortCircuitsOnFirst4xx() async {
        let attempts = AttemptCounter()
        let fetch: @Sendable (URLRequest) async throws -> Data = { _ in
            attempts.increment()
            throw AntigravitySummaryReader.FetchFailure.clientError(404)
        }
        let data = await AntigravitySummaryReader.attemptCandidate(
            csrf: "",
            ports: [12345, 23456],
            deadline: ProcessInfo.processInfo.systemUptime + 10,
            fetch: fetch)
        XCTAssertNil(data)
        XCTAssertEqual(attempts.count, 1, "4xx must stop the per-candidate fan-out after one attempt")
    }

    /// Audit fix #5: at most two attempts per candidate.  Transport errors
    /// (the next thing the server might say after a 4xx) use up the budget,
    /// then the loop yields and the outer caller tries a fresh candidate.
    func testAttemptCandidateStopsAtTwoAttemptsEvenWithRepeatedTransportErrors() async {
        let attempts = AttemptCounter()
        let fetch: @Sendable (URLRequest) async throws -> Data = { _ in
            attempts.increment()
            throw AntigravitySummaryReader.FetchFailure.transport
        }
        _ = await AntigravitySummaryReader.attemptCandidate(
            csrf: "",
            ports: [12345, 23456],
            deadline: ProcessInfo.processInfo.systemUptime + 10,
            fetch: fetch)
        XCTAssertEqual(attempts.count, 2, "transport failures must still respect the two-attempt cap")
    }

    /// Audit fix #5: a 2xx with no groups is the server saying "I have nothing
    /// for you" — same effect as a 4xx for fan-out purposes.
    func testAttemptCandidateStopsOnTwoHundredWithNoGroups() async {
        let attempts = AttemptCounter()
        let fetch: @Sendable (URLRequest) async throws -> Data = { _ in
            attempts.increment()
            return Data(#"{"response":{"groups":[]}}"#.utf8)
        }
        let data = await AntigravitySummaryReader.attemptCandidate(
            csrf: "",
            ports: [12345],
            deadline: ProcessInfo.processInfo.systemUptime + 10,
            fetch: fetch)
        XCTAssertNil(data)
        XCTAssertEqual(attempts.count, 1, "an empty 200 is the same answer as a 4xx: stop")
    }

    /// Count fetch calls without a mutable actor closure; the production
    /// fan-out is `@Sendable` and runs across actors.
    private final class AttemptCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
}