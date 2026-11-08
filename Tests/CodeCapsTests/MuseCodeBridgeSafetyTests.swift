import XCTest
import QuotaCore
@testable import CodeCaps

@MainActor
final class MuseCodeBridgeSafetyTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var scratch: URL!
    private let instant = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        suite = "CodeCaps.MuseBridgeSafetyTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: scratch)
        defaults = nil
        super.tearDown()
    }

    private func model() -> MonitorModel {
        let model = MonitorModel(defaults: defaults, burnRateHistoryURL: scratch.appendingPathComponent("burn.json"),
                                 presentsPipWindows: false)
        model.skipsSnapshotIOForTesting = true
        model.museCodeBurnAlertsEnabled = false
        model.alarmManager.onUsageDelivery = { _, _, _, _ in }
        model.museCodeTokenReadForTesting = { "fixture-ingest-token" }
        return model
    }

    private func reading(total: Int, snapshot: String) -> MuseCodeSessionResult {
        let observation = MuseCodeSessionObservation(sessionId: "s1", snapshotId: snapshot,
            modelId: "muse-spark-contributor", totalTokens: total, segmentKey: "same-segment", observedAt: instant)
        return .init(report: .init(generatedAt: instant.addingTimeInterval(Double(total)), windows: [],
                                   latestObservations: [observation]), issue: nil)
    }

    private func checkpoint() throws -> MuseCodeBridgeCheckpoint {
        try JSONDecoder().decode(MuseCodeBridgeCheckpoint.self,
            from: XCTUnwrap(defaults.data(forKey: "museCodeIngestCheckpoint")))
    }

    func testConcurrentReadingsPlanFromTheAcknowledgedBaselineAndKeepOnlyNewestPendingReport() async throws {
        let model = model()
        let firstStarted = expectation(description: "First post began")
        let secondStarted = expectation(description: "Newest pending post began")
        let gate = MuseBridgePostGate(onStart: { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { secondStarted.fulfill() }
        })
        model.museCodePublishForTesting = { events, _, _ in await gate.publish(events) }
        model.museCodeUsageBridgeEnabled = true
        model.applyMuseCodeResult(reading(total: 100, snapshot: "A"))
        await fulfillment(of: [firstStarted], timeout: 2)
        model.applyMuseCodeResult(reading(total: 200, snapshot: "B"))
        model.applyMuseCodeResult(reading(total: 300, snapshot: "C"))
        XCTAssertEqual(gate.posts.count, 1)
        gate.completeCurrent()
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertEqual(gate.posts.map { $0.first?["quantity"] as? Int }, [100, 200])
        gate.completeCurrent()
        await model.museCodeBridgeTaskForTesting?.value
        XCTAssertEqual(gate.posts.count, 2)
        XCTAssertEqual(try checkpoint().observations["s1"]?.totalTokens, 300)
        XCTAssertNil(try checkpoint().pending)
    }

    func testDisabledBridgeDoesNotAdoptOldStatusOrStartANewerPostButKeepsAcknowledgedAccounting() async throws {
        let model = model()
        let started = expectation(description: "Post began")
        let gate = MuseBridgePostGate(onStart: { _ in started.fulfill() })
        model.museCodePublishForTesting = { events, _, _ in await gate.publish(events) }
        model.museCodeUsageBridgeEnabled = true
        model.applyMuseCodeResult(reading(total: 100, snapshot: "A"))
        await fulfillment(of: [started], timeout: 2)
        model.applyMuseCodeResult(reading(total: 200, snapshot: "B"))
        model.museCodeUsageBridgeEnabled = false
        gate.completeCurrent()
        await model.museCodeBridgeTaskForTesting?.value
        XCTAssertEqual(model.museCodeBridgeStatus, "Bridge off.")
        XCTAssertEqual(gate.posts.count, 1)
        XCTAssertEqual(try checkpoint().observations["s1"]?.totalTokens, 100)
        XCTAssertNil(try checkpoint().pending)
    }

    func testTokenRotationWaitsForOldAcknowledgmentBeforePlanningWithTheNewToken() async throws {
        let model = model()
        let firstStarted = expectation(description: "Old token post began")
        let secondStarted = expectation(description: "New token post began")
        let gate = MuseBridgePostGate(onStart: { count in
            if count == 1 { firstStarted.fulfill() }
            if count == 2 { secondStarted.fulfill() }
        })
        var currentToken = "old-fixture-token"
        var tokens: [String?] = []
        model.museCodeTokenReadForTesting = { currentToken }
        model.museCodeTokenSaveForTesting = { currentToken = $0 }
        model.museCodePublishForTesting = { events, _, token in
            tokens.append(token)
            return await gate.publish(events)
        }
        model.museCodeUsageBridgeEnabled = true
        model.applyMuseCodeResult(reading(total: 100, snapshot: "A"))
        await fulfillment(of: [firstStarted], timeout: 2)
        let saved = await model.saveMuseCodeIngestToken("new-fixture-token")
        XCTAssertTrue(saved)
        model.applyMuseCodeResult(reading(total: 200, snapshot: "B"))
        XCTAssertEqual(gate.posts.count, 1)
        gate.completeCurrent()
        await fulfillment(of: [secondStarted], timeout: 2)
        XCTAssertEqual(tokens, ["old-fixture-token", "new-fixture-token"])
        XCTAssertEqual(gate.posts.map { $0.first?["quantity"] as? Int }, [100, 100])
        gate.completeCurrent()
        await model.museCodeBridgeTaskForTesting?.value
        XCTAssertEqual(try checkpoint().observations["s1"]?.totalTokens, 200)
        XCTAssertEqual(model.museCodeIngestTokenStatus, "Muse ingest token saved.")
    }

    func testDisablingWhileTokenReadWaitsPreventsTheRequestAndRetainsTheExactPlan() async throws {
        let model = model()
        let started = expectation(description: "Credential read began")
        var continuation: CheckedContinuation<String?, Never>?
        model.museCodeTokenReadForTesting = {
            await withCheckedContinuation {
                continuation = $0
                started.fulfill()
            }
        }
        model.museCodePublishForTesting = { _, _, _ in
            XCTFail("A disabled bridge must not begin a request after the credential await")
            return .init()
        }
        model.museCodeUsageBridgeEnabled = true
        model.applyMuseCodeResult(reading(total: 100, snapshot: "A"))
        await fulfillment(of: [started], timeout: 2)
        model.museCodeUsageBridgeEnabled = false
        continuation?.resume(returning: "fixture-token")
        await model.museCodeBridgeTaskForTesting?.value
        XCTAssertEqual(try checkpoint().pending?.events.first?.delta, 100)
        XCTAssertEqual(model.museCodeBridgeStatus, "Bridge off.")
    }

    func testUncertainPostSurvivesRelaunchAndReplaysOriginalQuantityBeforeTheNewerDelta() async throws {
        let first = model()
        var originalEventID: String?
        first.museCodePublishForTesting = { events, _, _ in
            originalEventID = events.first?["eventId"] as? String
            throw URLError(.timedOut)
        }
        first.museCodeUsageBridgeEnabled = true
        first.applyMuseCodeResult(reading(total: 100, snapshot: "A"))
        await first.museCodeBridgeTaskForTesting?.value
        XCTAssertEqual(try checkpoint().pending?.events.first?.delta, 100)
        let relaunched = model()
        var posts: [[[String: Any]]] = []
        relaunched.museCodePublishForTesting = { events, _, _ in
            posts.append(events)
            return .init(sent: events.count, persisted: events.count)
        }
        relaunched.applyMuseCodeResult(reading(total: 200, snapshot: "B"))
        await relaunched.museCodeBridgeTaskForTesting?.value
        XCTAssertEqual(posts.map { $0.first?["quantity"] as? Int }, [100, 100])
        XCTAssertEqual(posts.first?.first?["eventId"] as? String, originalEventID)
        XCTAssertNotEqual(posts.last?.first?["eventId"] as? String, originalEventID)
        XCTAssertEqual(try checkpoint().observations["s1"]?.totalTokens, 200)
        XCTAssertNil(try checkpoint().pending)
    }

    func testRejectedAcknowledgmentRetainsPendingEventsInsteadOfAdvancingBaseline() async throws {
        let model = model()
        model.museCodePublishForTesting = { events, _, _ in
            .init(sent: events.count, persisted: 0, rejected: events.count)
        }
        model.museCodeUsageBridgeEnabled = true
        model.applyMuseCodeResult(reading(total: 100, snapshot: "A"))
        await model.museCodeBridgeTaskForTesting?.value
        XCTAssertEqual(try checkpoint().pending?.events.first?.delta, 100)
        XCTAssertNil(try checkpoint().observations["s1"])
        XCTAssertTrue(model.museCodeBridgeStatus?.contains("Pending events were retained") == true)
    }

    func testTokenSetupActionsAreExplicitAndUseOnlyInjectedCredentialCalls() async {
        let model = model()
        var saved: String?
        var authorized = 0
        var deleted = 0
        model.museCodeTokenSaveForTesting = { saved = $0 }
        model.museCodeTokenReauthorizeForTesting = { authorized += 1; return "fixture-token" }
        model.museCodeTokenDeleteForTesting = { deleted += 1 }
        XCTAssertNil(saved)
        XCTAssertEqual(authorized, 0)
        let success = await model.saveMuseCodeIngestToken("  fixture-token  ")
        XCTAssertTrue(success)
        XCTAssertEqual(saved, "fixture-token")
        XCTAssertTrue(model.museCodeHasSavedIngestToken)
        XCTAssertFalse(model.museCodeUsageBridgeEnabled)
        await model.reauthorizeMuseCodeIngestToken()
        XCTAssertEqual(authorized, 1)
        await model.forgetMuseCodeIngestToken()
        XCTAssertEqual(deleted, 1)
        XCTAssertFalse(model.museCodeHasSavedIngestToken)
        XCTAssertFalse(model.museCodeUsageBridgeEnabled)
        XCTAssertFalse(model.museCodeIngestTokenStatus?.contains("fixture-token") ?? true)
    }
}

@MainActor
private final class MuseBridgePostGate {
    var posts: [[[String: Any]]] = []
    let onStart: (Int) -> Void
    private var completion: CheckedContinuation<MuseCodeIngestSummary, Never>?

    init(onStart: @escaping (Int) -> Void) { self.onStart = onStart }

    func publish(_ events: [[String: Any]]) async -> MuseCodeIngestSummary {
        posts.append(events)
        return await withCheckedContinuation { continuation in
            completion = continuation
            onStart(posts.count)
        }
    }

    func completeCurrent() {
        let continuation = completion
        completion = nil
        let count = posts.last?.count ?? 0
        continuation?.resume(returning: .init(sent: count, persisted: count))
    }
}
