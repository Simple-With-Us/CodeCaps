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
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var suiteName = ""
    private var defaults: UserDefaults!

    func testBothMuseAlertsStayVisibleTogether() throws {
        let source = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Sources/CodeCaps/MuseCodePluginView.swift"),
            encoding: .utf8)
        XCTAssertFalse(source.contains("} else if let alert = model.museCodeStandardSessionAlert"),
                       "the standard-session alert must not hide behind a burn alert; both stay visible")
    }

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
        XCTAssertEqual(UsageAlertKind.museCodeStandardSession.rawValue,
                       "museCodeStandardSession")
        let manager = ResetAlarmManager(defaults: defaults)
        XCTAssertTrue(manager.preferences[.museCodeBurn].enabled)
        XCTAssertTrue(manager.preferences[.museCodeStandardSession].enabled)
    }

    func testStandardSessionPopupShipsOffAndPersistsWhenEnabled() {
        let manager = ResetAlarmManager(defaults: defaults)
        XCTAssertFalse(manager.preferences[.museCodeStandardSession].popup,
                       "the popup warning is opt-in and ships off")
        var option = manager.preferences[.museCodeStandardSession]
        option.popup = true
        manager.preferences[.museCodeStandardSession] = option
        let reloaded = ResetAlarmManager(defaults: defaults)
        XCTAssertTrue(reloaded.preferences[.museCodeStandardSession].popup,
                      "the plugin page and Alerts & Alarms edit one stored preference")
    }

    func testStandardSessionDeliveryCarriesThePopupOption() {
        let (model, spy) = makeModel()
        var delivered: [(kind: UsageAlertKind, option: UsageAlertOption)] = []
        model.alarmManager.onUsageDelivery = { kind, _, _, option in
            delivered.append((kind, option))
        }
        var option = model.alarmManager.preferences[.museCodeStandardSession]
        option.popup = true
        model.alarmManager.preferences[.museCodeStandardSession] = option
        model.applyMuseCodeResult(result(total: 3_000_000, contributor: 2_000_000))
        XCTAssertEqual(spy.events.map(\.kind), [.museCodeStandardSession])
        XCTAssertEqual(delivered.map(\.kind), [.museCodeStandardSession])
        XCTAssertTrue(delivered.first?.option.popup == true,
                      "delivery reads the same popup option the plugin toggle sets")
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

    /// A reading whose window totals `total` tokens, `contributor` of them
    /// on a contributor session; the rest, when any, sit on a standard
    /// session.  Callers may pass explicit observations instead — the bridge
    /// tests do — in which case they are used as given.
    private func result(total: Int, contributor: Int,
                        observations: [MuseCodeSessionObservation]? = nil) -> MuseCodeSessionResult {
        var models: [MuseCodeModelUsage] = []
        var derived: [MuseCodeSessionObservation] = []
        if contributor > 0 {
            models.append(MuseCodeModelUsage(modelId: "muse-spark-1.3-contributor",
                                              tokens: contributor, segmentCount: 1, sessionCount: 1))
            derived.append(MuseCodeSessionObservation(
                sessionId: "s-contributor", snapshotId: "snap-c",
                modelId: "muse-spark-1.3-contributor", totalTokens: contributor,
                segmentKey: "seg-c", observedAt: Date()))
        }
        if total > contributor {
            models.append(MuseCodeModelUsage(modelId: "muse-wonder-1.0", tokens: total - contributor,
                                              segmentCount: 1, sessionCount: 1))
            derived.append(MuseCodeSessionObservation(
                sessionId: "s-standard", snapshotId: "snap-s",
                modelId: "muse-wonder-1.0", totalTokens: total - contributor,
                segmentKey: "seg-s", observedAt: Date()))
        }
        let window = MuseCodeWindowUsage(
            windowMinutes: 90, totalTokens: total, contributorTokens: contributor,
            contributorShare: total > 0 ? Double(contributor) / Double(total) : nil,
            activeSessions: models.count, models: models)
        return MuseCodeSessionResult(
            report: MuseCodeSessionReport(generatedAt: Date(), windows: [window],
                                           latestObservations: observations ?? derived,
                                           currentModelObservations: (observations ?? derived).map(MuseCodeSessionModelObservation.init)),
            issue: nil)
    }

    func testOverThresholdMixedReadingEmitsBothAlertKinds() {
        let (model, spy) = makeModel()
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        XCTAssertEqual(spy.events.map(\.kind), [.museCodeBurn, .museCodeStandardSession],
                       "the repeat reading re-fires neither kind: burn is in cooldown, the session is already reported")
        XCTAssertNotNil(model.museCodeBurnAlert)
        XCTAssertEqual(model.museCodeStandardSessionAlert?.sessionId, "s-standard")
        XCTAssertTrue(spy.events.first?.body.contains("muse-wonder-1.0") == true)
        XCTAssertTrue(spy.events.last?.body.contains("s-standard") == true,
                      "the standard-session event names the session")
    }

    func testAllContributorReadingEmitsNothing() {
        let (model, spy) = makeModel()
        model.applyMuseCodeResult(result(total: 9_000_000, contributor: 9_000_000))
        XCTAssertTrue(spy.events.isEmpty)
        XCTAssertNil(model.museCodeBurnAlert)
        XCTAssertNil(model.museCodeStandardSessionAlert)
    }

    func testBelowThresholdReadingEmitsOnlyTheStandardSessionKind() {
        let (model, spy) = makeModel()
        model.applyMuseCodeResult(result(total: 3_000_000, contributor: 2_000_000))
        XCTAssertEqual(spy.events.map(\.kind), [.museCodeStandardSession],
                       "the standard-session finding is its own event, not a burn side effect")
        XCTAssertNil(model.museCodeBurnAlert)
        XCTAssertNotNil(model.museCodeStandardSessionAlert)
    }

    func testStandardSessionEventFiresOnSwitchAndRefiresAfterRecovery() {
        let (model, spy) = makeModel()
        func reading(modelId: String) -> MuseCodeSessionResult {
            let observation = MuseCodeSessionObservation(
                sessionId: "s1", snapshotId: "snap", modelId: modelId,
                totalTokens: 100, segmentKey: "seg", observedAt: Date())
            return result(total: 100,
                          contributor: modelId.hasSuffix("-contributor") ? 100 : 0,
                          observations: [observation])
        }
        model.applyMuseCodeResult(reading(modelId: "muse-spark-1.3-contributor"))
        XCTAssertTrue(spy.events.isEmpty)
        model.applyMuseCodeResult(reading(modelId: "muse-wonder-1.0"))
        model.applyMuseCodeResult(reading(modelId: "muse-wonder-1.0"))
        XCTAssertEqual(spy.events.filter { $0.kind == .museCodeStandardSession }.count, 1,
                       "the switch fires once; staying on the standard model does not refire")
        model.applyMuseCodeResult(reading(modelId: "muse-spark-1.3-contributor"))
        model.applyMuseCodeResult(reading(modelId: "muse-wonder-1.0"))
        XCTAssertEqual(spy.events.filter { $0.kind == .museCodeStandardSession }.count, 2,
                       "returning to a contributor model re-arms the session")
        XCTAssertEqual(model.museCodeStandardSessionAlert?.sessionId, "s1")
        let eventIDs = spy.events.filter { $0.kind == .museCodeStandardSession }.map(\.identifier)
        XCTAssertEqual(Set(eventIDs).count, 2)
    }

    func testStandardSessionStateSurvivesModelRecreation() {
        let (model, spy) = makeModel()
        model.applyMuseCodeResult(result(total: 3_000_000, contributor: 2_000_000))
        XCTAssertEqual(spy.events.filter { $0.kind == .museCodeStandardSession }.count, 1)
        // A fresh model over the same defaults stands in for an app
        // relaunch: the persisted detector state must keep the already
        // reported standard session from firing again.
        let (relaunched, relaunchedSpy) = makeModel()
        relaunched.applyMuseCodeResult(result(total: 3_000_000, contributor: 2_000_000))
        XCTAssertTrue(relaunchedSpy.events.isEmpty,
                      "the standard session was already reported before the relaunch")
        XCTAssertNil(relaunched.museCodeStandardSessionAlert)
    }

    func testDisabledAlertsEmitNothing() {
        let (model, spy) = makeModel()
        model.museCodeBurnAlertsEnabled = false
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        XCTAssertTrue(spy.events.isEmpty)
        XCTAssertNil(model.museCodeBurnAlert)
        XCTAssertNil(model.museCodeStandardSessionAlert)
    }

    func testTwoBurnCooldownOccurrencesHaveDifferentIDsAndRepeatedPollIsSilent() {
        let (model, spy) = makeModel()
        let first = Date()
        model.injectForTests(sections: [], now: first)
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        XCTAssertEqual(spy.events.filter { $0.kind == .museCodeBurn }.count, 1)
        model.injectForTests(sections: [], now: first.addingTimeInterval(MuseCodeBurnMonitor.alertCooldown + 1))
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        let ids = spy.events.filter { $0.kind == .museCodeBurn }.map(\.identifier)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(Set(ids).count, 2)
    }

    func testFailedBurnPersistenceDoesNotBlockStandardAlertOrConsumeTheBurnCooldown() {
        let (model, spy) = makeModel()
        var burnSaveFails = true
        model.museCodeAlertSynchronizeForTesting = { key in
            !(key == "museCodeBurnLastSent" && burnSaveFails)
        }
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        XCTAssertEqual(spy.events.map(\.kind), [.museCodeStandardSession])
        XCTAssertNil(defaults.object(forKey: "museCodeBurnLastSent"))
        burnSaveFails = false
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        XCTAssertEqual(spy.events.map(\.kind), [.museCodeStandardSession, .museCodeBurn])
    }

    func testFailedDetectorPersistenceLeavesTheStandardEventEligibleWithoutRepeatingBurn() {
        let (model, spy) = makeModel()
        var detectorSaveFails = true
        model.museCodeAlertSynchronizeForTesting = { key in
            !(key == "museCodeStandardSessionDetector" && detectorSaveFails)
        }
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        XCTAssertEqual(spy.events.map(\.kind), [.museCodeBurn])
        XCTAssertNil(defaults.object(forKey: "museCodeStandardSessionDetector"))
        detectorSaveFails = false
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        model.applyMuseCodeResult(result(total: 5_000_000, contributor: 4_000_000))
        XCTAssertEqual(spy.events.map(\.kind), [.museCodeBurn, .museCodeStandardSession])
    }

    func testPersistenceFailureDoesNotConsumeAContributorToStandardRearmAcrossRecreation() {
        let (model, spy) = makeModel()
        let contributor = MuseCodeSessionObservation(sessionId: "s1", snapshotId: "contributor",
            modelId: "muse-spark-contributor", totalTokens: 100, segmentKey: "segment", observedAt: Date())
        let standard = MuseCodeSessionObservation(sessionId: "s1", snapshotId: "standard",
            modelId: "muse-wonder", totalTokens: 100, segmentKey: "segment", observedAt: Date())
        model.applyMuseCodeResult(result(total: 100, contributor: 100, observations: [contributor]))
        model.museCodeAlertSynchronizeForTesting = { _ in false }
        model.applyMuseCodeResult(result(total: 100, contributor: 0, observations: [standard]))
        XCTAssertTrue(spy.events.isEmpty)
        let (relaunched, relaunchedSpy) = makeModel()
        relaunched.applyMuseCodeResult(result(total: 100, contributor: 0, observations: [standard]))
        relaunched.applyMuseCodeResult(result(total: 100, contributor: 0, observations: [standard]))
        XCTAssertEqual(relaunchedSpy.events.map(\.kind), [.museCodeStandardSession])
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
