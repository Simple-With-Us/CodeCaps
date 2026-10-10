import XCTest
@testable import CodeCaps
import QuotaCore

/// The behaviour half of the running-out warning, board b860b26d.
///
/// The measurement is covered by `QuotaExhaustionForecastTests`; these pin what
/// the app DOES with it — dim the row, announce once, and stay quiet long enough
/// that the owner is not trained to dismiss it.
@MainActor
final class ExhaustionWarningTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var directory: URL!
    private var historyURL: URL { directory.appendingPathComponent("history.jsonl") }

    override func setUp() {
        super.setUp()
        suiteName = "com.jays.codecaps.exhaustion." + UUID().uuidString
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

    /// A window draining from 40% to 20% over 20 minutes is 1 point/minute, so
    /// it has about twenty minutes left — inside the horizon.
    /// A window draining at 1 percentage point a minute, sampled every five
    /// minutes across the whole span — which is what the app actually records
    /// while a window drains, and the only shape with no gap over the limit.
    private func seedDrainingWindow(historyEnd: Date, startingAt: Date? = nil) throws {
        let history = AnomalyDetector.SampleHistory(url: historyURL)
        let first = startingAt ?? historyEnd.addingTimeInterval(-20 * 60)
        var remaining = 40.0
        var samples: [AnomalyDetector.Sample] = []
        var at = first
        while at <= historyEnd {
            samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                                 observedAt: at, remainingPercent: max(0, remaining)))
            remaining -= 5
            at = at.addingTimeInterval(5 * 60)
        }
        if samples.isEmpty {
            samples = [.init(providerKey: "anthropic", windowId: "anthropic:5h",
                             observedAt: historyEnd, remainingPercent: 20)]
        }
        try history.append(samples)
    }

    private func window(remaining: Double, id: String = "anthropic:5h") -> QuotaWindow {
        QuotaWindow(id: id, provider: "Claude", providerKey: "anthropic",
                    label: "5-hour window", remainingPercent: remaining, window: "5h",
                    occurredAt: ISO8601DateFormatter().string(from: Date()))
    }

    private func makeModel() -> MonitorModel {
        let model = MonitorModel(defaults: defaults, burnRateHistoryURL: historyURL)
        model.skipsSnapshotIOForTesting = true
        model.exhaustionHistoryURLForTesting = historyURL
        return model
    }

    func testAWindowHeadingForItsCapWarnsOnce() throws {
        let now = Date()
        try seedDrainingWindow(historyEnd: now)
        let model = makeModel()
        model.exhaustionAlertsEnabled = true
        var announced: [(String, String)] = []
        model.exhaustionNotificationForTesting = { announced.append(($0, $1)) }

        model.refreshExhaustionWarningsForTesting(windows: [window(remaining: 20)], now: now)

        XCTAssertEqual(announced.count, 1, "a draining window announces")
        XCTAssertEqual(announced.first?.1, "about 20 min", "and says roughly how long is left")
        XCTAssertTrue(model.platformIsAtRisk("anthropic"))
    }

    /// The one that matters most in practice: without a cooldown, a window that
    /// drains over an hour re-announces on every refresh and becomes exactly the
    /// alert its owner learns to dismiss.
    func testTheSameWindowDoesNotAnnounceAgainInsideTheCooldown() throws {
        let now = Date()
        try seedDrainingWindow(historyEnd: now)
        let model = makeModel()
        model.exhaustionAlertsEnabled = true
        var announced = 0
        model.exhaustionNotificationForTesting = { _, _ in announced += 1 }

        model.refreshExhaustionWarningsForTesting(windows: [window(remaining: 20)], now: now)
        XCTAssertEqual(announced, 1)

        for offset in [60.0, 300.0, 900.0] {
            model.refreshExhaustionWarningsForTesting(
                windows: [window(remaining: 20)],
                now: now.addingTimeInterval(offset))
        }
        XCTAssertEqual(announced, 1, "still inside the 30 minute cooldown")

        // Past the cooldown it may speak again — but only if the history is
        // still fresh.  The forecast refuses to project across a gap the app
        // was not watching, so a realistic test has to keep polling, which is
        // what the app actually does while a window drains.
        let later = now.addingTimeInterval(MonitorModel.exhaustionCooldown + 60)
        try seedDrainingWindow(historyEnd: later, startingAt: now)
        model.refreshExhaustionWarningsForTesting(windows: [window(remaining: 5)], now: later)
        XCTAssertEqual(announced, 2, "past the cooldown, with fresh samples, it speaks again")
    }

    func testAHealthyWindowNeitherWarnsNorDims() throws {
        let now = Date()
        try seedDrainingWindow(historyEnd: now)
        let model = makeModel()
        model.exhaustionAlertsEnabled = true
        var announced = 0
        model.exhaustionNotificationForTesting = { _, _ in announced += 1 }

        // 95% left with the same rate has ~19 hours of headroom: far outside.
        model.refreshExhaustionWarningsForTesting(windows: [window(remaining: 95)], now: now)

        XCTAssertEqual(announced, 0)
        XCTAssertFalse(model.platformIsAtRisk("anthropic"))
    }

    func testTurningTheMasterSwitchOffClearsTheAtRiskState() throws {
        let now = Date()
        try seedDrainingWindow(historyEnd: now)
        let model = makeModel()
        model.exhaustionAlertsEnabled = true
        model.refreshExhaustionWarningsForTesting(windows: [window(remaining: 20)], now: now)
        XCTAssertTrue(model.platformIsAtRisk("anthropic"))

        model.exhaustionAlertsEnabled = false
        XCTAssertFalse(model.platformIsAtRisk("anthropic"),
                       "an off switch must not leave rows greyed from a previous read")
    }
}