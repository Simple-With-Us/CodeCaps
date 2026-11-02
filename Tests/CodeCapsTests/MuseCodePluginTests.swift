import XCTest
@testable import CodeCaps
import QuotaCore

@MainActor
private final class SpyAlertChannel: CodeCapsAlertChannel {
    var events: [CodeCapsAlertEvent] = []
    func deliver(_ event: CodeCapsAlertEvent) { events.append(event) }
}

@MainActor
final class MuseCodePluginTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "MuseCodePluginTests." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Navigation and registry

    func testPluginPageRoundTripsThroughStorageKey() {
        let page = ConsolePage.plugin("muse-code")
        XCTAssertEqual(page.storageKey, "plugin:muse-code")
        XCTAssertEqual(ConsolePage.fromStorageKey(page.storageKey), page)
        XCTAssertFalse(page.isSettings)
        XCTAssertEqual(page.settingsTitle, "Muse")
        XCTAssertTrue(ConsolePage.pluginPages.contains(page))
    }

    func testPluginPageSurvivesReconcileWithoutQuotaRows() {
        defaults.set("plugin:muse-code", forKey: "consoleLastPage")
        let state = ConsoleState(defaults: defaults)
        XCTAssertEqual(state.page, .plugin("muse-code"))
        state.reconcile(available: [], readCompleted: true)
        XCTAssertEqual(state.page, .plugin("muse-code"),
                       "a plugin page is local and never falls back to a platform")
    }

    func testAlertKindsHaveStableIdentifiersAndShipEnabled() {
        XCTAssertEqual(UsageAlertKind.museCodeBurn.rawValue, "museCodeBurn")
        XCTAssertEqual(UsageAlertKind.museCodeContributorBelow100.rawValue,
                       "museCodeContributorBelow100")
        let manager = ResetAlarmManager(defaults: defaults)
        XCTAssertTrue(manager.preferences[.museCodeBurn].enabled)
        XCTAssertTrue(manager.preferences[.museCodeContributorBelow100].enabled)
    }

    // MARK: - Monitor glue

    private func makeModel() -> (MonitorModel, SpyAlertChannel) {
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        let spy = SpyAlertChannel()
        model.alertDispatcher.register(spy)
        // Swallow the local channel so no test reaches the notification centre.
        model.alarmManager.onUsageDelivery = { _, _, _, _ in }
        return (model, spy)
    }

    private func result(total: Int, contributor: Int,
                        observations: [MuseCodeSessionObservation] = []) -> MuseCodeSessionResult {
        var models = [MuseCodeModelUsage(modelId: "muse-spark-1.3-contributor",
                                          tokens: contributor, segmentCount: 1, sessionCount: 1)]
        if total > contributor {
            models.append(MuseCodeModelUsage(modelId: "muse-wonder-1.0", tokens: total - contributor,
                                              segmentCount: 1, sessionCount: 1))
        }
        let window = MuseCodeWindowUsage(
            windowMinutes: 90, totalTokens: total, contributorTokens: contributor,
            contributorShare: total > 0 ? Double(contributor) / Double(total) : nil,
            activeSessions: 1, models: models)
        return MuseCodeSessionResult(
            report: MuseCodeSessionReport(generatedAt: Date(), windows: [window],
                                           latestObservations: observations),
            issue: nil)
    }

    func testOverThresholdMixedReadingEmitsBothAlertKinds() {
        let (model, spy) = makeModel()
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        XCTAssertEqual(spy.events.map(\.kind), [.museCodeBurn, .museCodeContributorBelow100])
        XCTAssertNotNil(model.museCodeBurnAlert)
        XCTAssertNotNil(model.museCodeContributorAlert)
        XCTAssertTrue(spy.events.first?.body.contains("muse-wonder-1.0") == true)
    }

    func testAllContributorReadingEmitsNothing() {
        let (model, spy) = makeModel()
        model.applyMuseCodeResult(result(total: 9_000_000, contributor: 9_000_000))
        XCTAssertTrue(spy.events.isEmpty)
        XCTAssertNil(model.museCodeBurnAlert)
        XCTAssertNil(model.museCodeContributorAlert)
    }

    func testBelowThresholdReadingEmitsOnlyTheContributorKind() {
        let (model, spy) = makeModel()
        model.applyMuseCodeResult(result(total: 3_000_000, contributor: 2_000_000))
        XCTAssertEqual(spy.events.map(\.kind), [.museCodeContributorBelow100],
                       "the contributor finding is its own event, not a burn side effect")
        XCTAssertNil(model.museCodeBurnAlert)
        XCTAssertNotNil(model.museCodeContributorAlert)
    }

    func testContributorEventIsEdgeTriggeredAndRearmsOnRecovery() {
        let (model, spy) = makeModel()
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        XCTAssertEqual(spy.events.filter { $0.kind == .museCodeContributorBelow100 }.count, 1,
                       "a continuing finding does not re-fire")
        XCTAssertEqual(spy.events.filter { $0.kind == .museCodeBurn }.count, 1,
                       "the burn alert is inside its cooldown")
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 5_000_000))
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        XCTAssertEqual(spy.events.filter { $0.kind == .museCodeContributorBelow100 }.count, 2,
                       "recovery to 100% contributor re-arms the finding")
    }

    func testDisabledAlertsEmitNothing() {
        let (model, spy) = makeModel()
        model.museCodeBurnAlertsEnabled = false
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        XCTAssertTrue(spy.events.isEmpty)
        XCTAssertNil(model.museCodeBurnAlert)
    }

    // MARK: - Bridge

    func testBridgePostsDeltasOnceAndAdvancesBaseline() async {
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        model.alarmManager.onUsageDelivery = { _, _, _, _ in }
        var posted: [[String: Any]] = []
        model.museCodeTokenReadForTesting = { "scoped-token" }
        model.museCodePublishForTesting = { events, _, token in
            XCTAssertEqual(token, "scoped-token")
            posted = events
            return MuseCodeIngestSummary(sent: events.count, persisted: events.count)
        }
        model.museCodeUsageBridgeEnabled = true
        let observation = MuseCodeSessionObservation(
            sessionId: "s1", snapshotId: "snap1", modelId: "muse-spark-1.3-contributor",
            totalTokens: 700, segmentKey: "seg-a", observedAt: Date())
        model.applyMuseCodeResult(result(total: 700, contributor: 700, observations: [observation]))
        await waitForBridgeStatus(model) { $0?.contains("Posted 1 token events") == true }
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted.first?["quantity"] as? Int, 700)
        XCTAssertEqual(posted.first?["eventId"] as? String,
                       "codecaps-muse-code:s1:snap1:muse-spark-1.3-contributor")

        model.applyMuseCodeResult(result(total: 700, contributor: 700, observations: [observation]))
        await waitForBridgeStatus(model) { $0 == "No new Muse tokens to post." }
        XCTAssertEqual(posted.count, 1, "the same cumulative total is never posted twice")
    }

    private func waitForBridgeStatus(_ model: MonitorModel,
                                     _ predicate: @escaping (String?) -> Bool) async {
        for _ in 0..<2_000 {
            if predicate(model.museCodeBridgeStatus) { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("bridge status never matched; last status: \(model.museCodeBridgeStatus ?? "nil")")
    }
}
