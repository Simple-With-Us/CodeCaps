import XCTest
@testable import CodeCaps
import QuotaCore

@MainActor
final class MonitorModelRunawayAlertTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var directory: URL!
    private var historyURL: URL { directory.appendingPathComponent("history.jsonl") }

    override func setUp() {
        super.setUp()
        suiteName = "com.jays.codecaps.runaway-alert." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
        defaults = nil
        directory = nil
        super.tearDown()
    }

    func testEnabledRefreshEvaluatesFreshLocalReadAndDeliversWithSelectedSound() async throws {
        try seedSteadyHistory()
        let model = makeModel()
        model.alarmSound = .submarine
        model.burnRateAlertsEnabled = true
        var delivered: [BurnRateNotification] = []
        model.runawayNotificationForTesting = { delivered.append($0) }
        model.localResultForTesting = LocalQuotaResult(windows: [localWindow(remaining: latestRemaining(drop: 10))])

        await refreshAndWait(model)

        XCTAssertFalse(model.activeRunawayAnomalies.isEmpty)
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered[0].sound, .submarine)
        XCTAssertEqual(delivered[0].anomalies, model.activeRunawayAnomalies)
        XCTAssertTrue(delivered[0].title.contains("↑USAGE:"), "title must report the usage spike; owner renamed this from \"Runaway Usage\" on 2026-10-08")
        XCTAssertTrue(delivered[0].title.contains("("), "title must include window cadence")
        XCTAssertEqual(model.runawayAlertHistory.first?.timestamp,
                       delivered[0].anomalies.first?.observedAt,
                       "notification activation must find the exact saved alert observation")
    }

    func testDisabledAlertsStillRecordSamplesWithoutPublishingOrDelivering() async throws {
        try seedSteadyHistory()
        let model = makeModel()
        var delivered: [BurnRateNotification] = []
        model.runawayNotificationForTesting = { delivered.append($0) }
        model.localResultForTesting = LocalQuotaResult(windows: [localWindow(remaining: latestRemaining(drop: 10))])

        await refreshAndWait(model)

        XCTAssertTrue(model.activeRunawayAnomalies.isEmpty)
        XCTAssertTrue(delivered.isEmpty)
        XCTAssertEqual(try AnomalyDetector.SampleHistory(url: historyURL).load().count, 2_030,
                       "the disabled path still adds the successful refresh sample")
    }

    func testCooldownSurvivesRelaunchAndSuppressesSameWindowEpisode() async throws {
        try seedSteadyHistory()
        let first = makeModel()
        first.burnRateAlertsEnabled = true
        first.localResultForTesting = LocalQuotaResult(windows: [localWindow(remaining: latestRemaining(drop: 10))])
        var firstDeliveries = 0
        first.runawayNotificationForTesting = { _ in firstDeliveries += 1 }
        await refreshAndWait(first)
        XCTAssertEqual(firstDeliveries, 1)

        let relaunched = makeModel()
        relaunched.burnRateAlertsEnabled = true
        relaunched.localResultForTesting = LocalQuotaResult(windows: [localWindow(remaining: latestRemaining(drop: 10))])
        var relaunchedDeliveries = 0
        relaunched.runawayNotificationForTesting = { _ in relaunchedDeliveries += 1 }
        await refreshAndWait(relaunched)

        XCTAssertFalse(relaunched.activeRunawayAnomalies.isEmpty,
                       "the condition remains visible even while its notification is cooling down")
        XCTAssertEqual(relaunchedDeliveries, 0)
    }

    func testStaleOrMissingLocalReadingClearsVisibleAnomalyWithoutDelivery() async throws {
        try seedSteadyHistory()
        let model = makeModel()
        model.burnRateAlertsEnabled = true
        var delivered = 0
        model.runawayNotificationForTesting = { _ in delivered += 1 }
        model.localResultForTesting = LocalQuotaResult(windows: [localWindow(remaining: latestRemaining(drop: 10))])
        await refreshAndWait(model)
        XCTAssertFalse(model.activeRunawayAnomalies.isEmpty)
        XCTAssertEqual(delivered, 1)

        let stale = localWindow(remaining: latestRemaining(drop: 10), observedAt: Date().addingTimeInterval(-3_600))
        model.localResultForTesting = LocalQuotaResult(windows: [stale])
        await refreshAndWait(model)
        XCTAssertTrue(model.activeRunawayAnomalies.isEmpty)
        XCTAssertEqual(delivered, 1)

        model.localResultForTesting = LocalQuotaResult(windows: [localWindow(remaining: latestRemaining(drop: 10))],
                                                       issues: ["anthropic": "The reader could not refresh this provider."])
        await refreshAndWait(model)
        XCTAssertTrue(model.activeRunawayAnomalies.isEmpty,
                      "a failed provider read cannot surface an older historical spike")
        XCTAssertEqual(delivered, 1)

        model.localResultForTesting = LocalQuotaResult()
        await refreshAndWait(model)
        XCTAssertTrue(model.activeRunawayAnomalies.isEmpty)
        XCTAssertEqual(delivered, 1)

        model.localResultForTesting = LocalQuotaResult(windows: [localWindow(remaining: latestRemaining(drop: 10))])
        model.setLocalEnabled(false)
        await waitForRefresh(model)
        XCTAssertTrue(model.activeRunawayAnomalies.isEmpty)
        XCTAssertEqual(delivered, 1)
    }

    func testChangingThresholdReevaluatesTheCurrentReading() async throws {
        try seedSteadyHistory()
        let model = makeModel()
        model.burnRateAlertsEnabled = true
        model.anomalyPeakMultiplier = 4
        let remaining = latestRemaining(drop: 0.5)
        model.localResultForTesting = LocalQuotaResult(windows: [localWindow(remaining: remaining)])
        var delivered = 0
        model.runawayNotificationForTesting = { _ in delivered += 1 }
        await refreshAndWait(model)
        XCTAssertTrue(model.activeRunawayAnomalies.isEmpty)
        XCTAssertEqual(delivered, 0)

        model.anomalyPeakMultiplier = 2.5

        XCTAssertTrue(model.activeRunawayAnomalies.contains { $0.kind == .vsPeak })
        XCTAssertEqual(delivered, 1)
    }

    func testDisablingAlertsClearsVisibleStateButKeepsCooldownHistory() async throws {
        try seedSteadyHistory()
        let model = makeModel()
        model.burnRateAlertsEnabled = true
        model.localResultForTesting = LocalQuotaResult(windows: [localWindow(remaining: latestRemaining(drop: 10))])
        model.runawayNotificationForTesting = { _ in }
        await refreshAndWait(model)
        XCTAssertFalse(model.activeRunawayAnomalies.isEmpty)

        model.burnRateAlertsEnabled = false

        XCTAssertTrue(model.activeRunawayAnomalies.isEmpty)
        XCTAssertNotNil(defaults.dictionary(forKey: "runawayAlertLastSent"))
    }

    func testHasActiveRunawayAnomalyAccuratelyIdentifiesRowAndPool() {
        let now = Date()
        let model = makeModel()
        let geminiWindow = QuotaWindow(id: "gemini-5h", provider: "Antigravity", providerKey: "google-antigravity",
                                       label: "Gemini 5h", remainingPercent: 71, resetAt: nil, window: "5h", occurredAt: ISO8601DateFormatter().string(from: now))
        let thirdPartyWindow = QuotaWindow(id: "third-5h", provider: "Antigravity", providerKey: "google-antigravity",
                                           label: "Third-Party 5h", remainingPercent: 100, resetAt: nil, window: "5h", occurredAt: ISO8601DateFormatter().string(from: now))
        let claudeWindow = QuotaWindow(id: "claude-5h", provider: "anthropic", providerKey: "anthropic",
                                       label: "Claude 5h", remainingPercent: 1, resetAt: nil, window: "5h", occurredAt: ISO8601DateFormatter().string(from: now))

        let geminiSection = QuotaPlatformSection(providerKey: "google-antigravity", providerLabel: "Antigravity", via: "antigravity", expected: true, windows: [QuotaWindowSnapshot(window: geminiWindow, now: now)])
        let thirdSection = QuotaPlatformSection(providerKey: "google-antigravity", providerLabel: "Antigravity", via: "antigravity", expected: true, windows: [QuotaWindowSnapshot(window: thirdPartyWindow, now: now)])
        let claudeSection = QuotaPlatformSection(providerKey: "anthropic", providerLabel: "Claude", via: nil, expected: true, windows: [QuotaWindowSnapshot(window: claudeWindow, now: now)])

        let geminiRow = DisplaySection(id: "google-antigravity:gemini", providerKey: "google-antigravity", title: "Antigravity · Gemini", platformTitle: "Antigravity", section: geminiSection, poolKey: "gemini", remainingPercent: 71, resetAt: nil, maskedWindowIds: [])
        let thirdRow = DisplaySection(id: "google-antigravity:third-party", providerKey: "google-antigravity", title: "Antigravity · Third-Party", platformTitle: "Antigravity", section: thirdSection, poolKey: "third-party", remainingPercent: 100, resetAt: nil, maskedWindowIds: [])
        let claudeRow = DisplaySection(id: "anthropic", providerKey: "anthropic", title: "Claude", platformTitle: "Claude", section: claudeSection, poolKey: nil, remainingPercent: 1, resetAt: nil, maskedWindowIds: [])

        // Inject anomaly targeting ONLY Gemini
        let geminiAnomaly = AnomalyDetector.Anomaly(providerKey: "google-antigravity", windowId: "gemini-5h", kind: .vsBaseline, multiplier: 3.7, summary: "Spending fast")
        model.injectRunawayAnomaliesForTests([geminiAnomaly])

        XCTAssertTrue(model.hasActiveRunawayAnomaly(for: geminiRow))
        XCTAssertFalse(model.hasActiveRunawayAnomaly(for: thirdRow), "Third-Party pool must not show flame when only Gemini triggered anomaly")
        XCTAssertFalse(model.hasActiveRunawayAnomaly(for: claudeRow))

        // Now inject anomaly for Claude too
        let claudeAnomaly = AnomalyDetector.Anomaly(providerKey: "anthropic", windowId: "claude-5h", kind: .vsBaseline, multiplier: 4.2, summary: "Spending fast")
        model.injectRunawayAnomaliesForTests([geminiAnomaly, claudeAnomaly])

        XCTAssertTrue(model.hasActiveRunawayAnomaly(for: geminiRow))
        XCTAssertFalse(model.hasActiveRunawayAnomaly(for: thirdRow))
        XCTAssertTrue(model.hasActiveRunawayAnomaly(for: claudeRow))
    }

    private func makeModel() -> MonitorModel {
        let model = MonitorModel(defaults: defaults, burnRateHistoryURL: historyURL)
        model.skipsSnapshotIOForTesting = true
        return model
    }

    private func localWindow(remaining: Double, observedAt: Date = Date()) -> QuotaWindow {
        QuotaWindow(id: "anthropic:5h", provider: "Claude", providerKey: "anthropic",
                    label: "5-hour window", remainingPercent: remaining,
                    window: "5h", occurredAt: ISO8601DateFormatter().string(from: observedAt))
    }

    private func seedSteadyHistory() throws {
        let now = Date()
        let history = AnomalyDetector.SampleHistory(url: historyURL)
        let samplesPerWeek = 7 * 24 * 12
        let start = now.addingTimeInterval(-Double(samplesPerWeek + 13) * 300)
        var samples: [AnomalyDetector.Sample] = []
        for index in 0...samplesPerWeek {
            let observedAt = start.addingTimeInterval(Double(index) * 300)
            samples.append(sample(at: observedAt, percent: percent(at: observedAt, start: start)))
        }
        let lastBaselineTime = samples.last!.observedAt
        let currentHourStart = now.addingTimeInterval(-3_600)
        for index in 0...11 {
            let observedAt = currentHourStart.addingTimeInterval(Double(index) * 300)
            if observedAt > lastBaselineTime {
                samples.append(sample(at: observedAt, percent: percent(at: observedAt, start: start)))
            }
        }
        try history.append(samples)
    }

    private func latestRemaining(drop: Double) -> Double {
        let now = Date()
        let start = now.addingTimeInterval(-Double(7 * 24 * 12 + 13) * 300)
        return percent(at: now, start: start) - drop
    }

    private func percent(at date: Date, start: Date) -> Double {
        70 - date.timeIntervalSince(start) / 3_600 * 0.1
    }

    private func sample(at date: Date, percent: Double) -> AnomalyDetector.Sample {
        AnomalyDetector.Sample(providerKey: "anthropic", windowId: "anthropic:5h",
                               observedAt: date, remainingPercent: percent)
    }

    private func refreshAndWait(_ model: MonitorModel) async {
        model.refresh()
        await waitForRefresh(model)
    }

    private func waitForRefresh(_ model: MonitorModel) async {
        for _ in 0..<2_000 {
            if !model.isRefreshing { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("The injected local refresh did not finish")
    }
}
