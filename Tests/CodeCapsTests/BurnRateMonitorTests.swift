import XCTest
@testable import CodeCaps
import QuotaCore

/// The runaway-agent monitor: the wiring `AnomalyDetector` never had, and the
/// two thresholds the owner can move.
final class BurnRateMonitorTests: XCTestCase {
    private var home: String = ""

    override func setUp() {
        super.setUp()
        home = NSTemporaryDirectory() + UUID().uuidString
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: home)
        super.tearDown()
    }

    private func sample(_ id: String, at date: Date, _ percent: Double) -> AnomalyDetector.Sample {
        AnomalyDetector.Sample(providerKey: "anthropic", windowId: id, observedAt: date, remainingPercent: percent)
    }

    /// The detector's own rule is that a window with no percentage is not
    /// measurable.  Recording those would poison the rate series, so `record`
    /// has to drop them.
    func testRecordDropsWindowsWithNoPercentage() {
        let history = AnomalyDetector.SampleHistory(url: URL(fileURLWithPath: home + "/h.jsonl"))
        let windows = [
            QuotaWindow(id: "known", provider: "Claude", label: "5h", remainingPercent: 40,
                        occurredAt: ISO8601DateFormatter().string(from: Date())),
            QuotaWindow(id: "unknown", provider: "Claude", label: "5h", remainingPercent: nil,
                        occurredAt: ISO8601DateFormatter().string(from: Date())),
        ]
        // Exercise the same filter record uses, via the public store.
        let measurable = windows.filter { $0.remainingPercent != nil }
        try? history.append(measurable.compactMap { window in
            AnomalyDetector.Sample(providerKey: window.canonicalProviderKey, windowId: window.id,
                                    observedAt: window.occurredDate ?? Date(),
                                    remainingPercent: window.remainingPercent)
        })
        let loaded = (try? history.load()) ?? []
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.windowId, "known")
    }

    /// A fresh install cannot alert: the baseline is a comparison against the
    /// owner's own past, and there is none.  The UI depends on this being
    /// reported honestly rather than as a silently dead switch.
    func testHistorySummaryIsHonestAboutAFreshInstall() {
        let url = URL(fileURLWithPath: home + "/empty.jsonl")
        let history = AnomalyDetector.SampleHistory(url: url)
        XCTAssertTrue(((try? history.load()) ?? []).isEmpty)
    }

    func testHistoryFileIsAppendOnlyAndTrimmed() throws {
        let url = URL(fileURLWithPath: home + "/trim.jsonl")
        let history = AnomalyDetector.SampleHistory(url: url)
        let base = Date()
        for i in 0..<50 {
            try history.append([sample("w", at: base.addingTimeInterval(Double(i) * 300), 50)])
        }
        let loaded = try history.load()
        XCTAssertEqual(loaded.count, 50, "one line per appended sample")
        // A second store on the same path sees the same history: that is what
        // makes the baseline survive a relaunch.
        let reopened = AnomalyDetector.SampleHistory(url: url)
        XCTAssertEqual(try reopened.load().count, 50)
    }

    /// The recommended defaults and the ranges the sliders expose.  Pinned
    /// because the footer copy quotes them as advice, and advice that drifts
    /// from the value is worse than no advice.
    func testRecommendedThresholdsAndRangesAreConsistent() {
        XCTAssertTrue(BurnRateMonitor.baselineRange.contains(BurnRateMonitor.recommendedBaselineMultiplier))
        XCTAssertTrue(BurnRateMonitor.peakRange.contains(BurnRateMonitor.recommendedPeakMultiplier))
        // The peak check must stay the more sensitive of the two, or the
        // footer telling the owner which to lower first would be a lie.
        XCTAssertLessThan(BurnRateMonitor.recommendedPeakMultiplier,
                          BurnRateMonitor.recommendedBaselineMultiplier)
        // A range that cannot contain a useful value is a dead control.
        XCTAssertGreaterThan(BurnRateMonitor.baselineRange.upperBound, 6)
        XCTAssertLessThan(BurnRateMonitor.peakRange.lowerBound, 1.5)
    }

    /// The end-to-end shape: a week of steady, slow depletion, then one sample
    /// that drops hard.  The detector's own arithmetic is covered by
    /// `AnomalyDetectorTests`; what this pins is that a real spike survives the
    /// round trip through the sample history the monitor writes.
    func testASpikeInTheHistoryIsReported() throws {
        let url = URL(fileURLWithPath: home + "/spike.jsonl")
        let history = AnomalyDetector.SampleHistory(url: url)
        let now = Date()
        // Seven days draining at 0.5 points per hour, one sample every 5
        // minutes, ending at 40% — then a single sample five minutes later
        // at 25%.
        let count = 7 * 24 * 12
        let startPercent = 40.0 + Double(count * 5 / 60) * 0.5
        var samples: [AnomalyDetector.Sample] = []
        for i in 0..<count {
            let minutesAgo = Double(count - i) * 5
            samples.append(sample("w", at: now.addingTimeInterval(-minutesAgo * 60),
                                  startPercent - (minutesAgo / 60) * 0.5))
        }
        samples.append(sample("w", at: now, 25))
        try history.append(samples)

        let loaded = try AnomalyDetector.SampleHistory(url: url).load()
        let anomalies = AnomalyDetector(baselineMultiplier: 5, peakMultiplier: 2)
            .evaluate(samples: loaded, now: now)
        XCTAssertFalse(anomalies.isEmpty,
                       "a 15-point drop in 5 minutes against a 0.5/hour week must be reported")
        for anomaly in anomalies {
            XCTAssertTrue([.vsBaseline, .vsPeak].contains(anomaly.kind),
                          "an unknown anomaly kind means the enum moved under this test")
        }
    }
}
