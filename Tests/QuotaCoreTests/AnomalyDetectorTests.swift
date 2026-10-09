import Foundation
import XCTest
@testable import QuotaCore

/// Pinned unit tests for `AnomalyDetector` — pure logic, no IO.
final class AnomalyDetectorTests: XCTestCase {
    /// A flat baseline has no meaningful multiplier.  The detector must not
    /// invent one by dividing through an arbitrary epsilon.
    func testFlatBaselineDoesNotInventRatio() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var samples: [AnomalyDetector.Sample] = []
        // Baseline: 7 days of flat 100% — no depletion.  Sampled twice a
        // day across the week.
        for day in 1...6 {
            let t = now.addingTimeInterval(Double(-day) * 24 * 3600)
            samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                                 observedAt: t, remainingPercent: 100))
            samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                                 observedAt: t.addingTimeInterval(12 * 3600),
                                 remainingPercent: 100))
        }
        // Current hour: 100% -> 50% in 30 minutes, then a third sample at
        // 60 minutes, dropping to 0%.
        samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                             observedAt: now.addingTimeInterval(-1800),
                             remainingPercent: 100))
        samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                             observedAt: now.addingTimeInterval(-300),
                             remainingPercent: 0))
        let anomalies = AnomalyDetector().evaluate(samples: samples, now: now)
        XCTAssertTrue(anomalies.isEmpty)
    }

    /// A bucket whose current rate matches the baseline — should NOT fire.
    func testDoesNotFlagSteadyUsage() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var samples: [AnomalyDetector.Sample] = []
        // Baseline: drop 0.5 % per day, every day, for 6 days.  That gives a
        // constant pairwise rate of 0.5 / 24 = 0.0208 %/h — the baseline.
        // `day` is the number of full days before `now`.
        for day in 1...6 {
            let t = now.addingTimeInterval(-Double(day) * 24 * 3600)
            samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                                 observedAt: t, remainingPercent: 100 - Double(day) * 0.5))
        }
        // Current hour: drop at the same 0.0208 %/h pace.  In 25 minutes the
        // expected drop is 0.0208 × (25 / 60) ≈ 0.0087 %.
        let drop = 0.0208 * (25.0 / 60.0)
        samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                             observedAt: now.addingTimeInterval(-1800),
                             remainingPercent: 97.0))
        samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                             observedAt: now.addingTimeInterval(-300),
                             remainingPercent: 97.0 - drop))
        let anomalies = AnomalyDetector().evaluate(samples: samples, now: now)
        XCTAssertTrue(anomalies.isEmpty, "Steady usage should not flag any anomaly, got \(anomalies)")
    }

    /// A bucket whose current rate is much higher than the prior-week peak —
    /// fires `vsPeak` but not necessarily `vsBaseline`.
    func testFlagsRateAbovePriorPeak() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var samples: [AnomalyDetector.Sample] = []
        // Prior week: a sharp one-hour drop of 30%, then flat — that is
        // the prior peak rate.
        for day in 1...6 {
            let t = now.addingTimeInterval(Double(-day) * 24 * 3600)
            samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                                 observedAt: t, remainingPercent: 100))
        }
        // Three days ago, several measured hours, including one peak hour.
        let peakHourStart = now.addingTimeInterval(-3 * 24 * 3600)
        samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                             observedAt: peakHourStart, remainingPercent: 100))
        samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                             observedAt: peakHourStart.addingTimeInterval(3600),
                             remainingPercent: 70))
        samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                             observedAt: peakHourStart.addingTimeInterval(7200),
                             remainingPercent: 65))
        samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                             observedAt: peakHourStart.addingTimeInterval(10_800),
                             remainingPercent: 60))
        // Current hour: drop 90% in 30 minutes — well above the prior peak.
        samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                             observedAt: now.addingTimeInterval(-1800),
                             remainingPercent: 100))
        samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                             observedAt: now.addingTimeInterval(-300),
                             remainingPercent: 10))
        let anomalies = AnomalyDetector().evaluate(samples: samples, now: now)
        XCTAssertEqual(anomalies.count, 1, "Expected one collapsed anomaly; got \(anomalies.map(\.summary))")
        let anomaly = anomalies[0]
        XCTAssertNotNil(anomaly.peakRatio, "Expected the peak bar to clear; got \(anomalies.map(\.summary))")
        XCTAssertEqual(anomaly.providerKey, "anthropic")
    }

    /// Two flat histories should not yield fabricated multipliers.
    func testMultipleFlatBucketsDoNotProduceRatios() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var samples: [AnomalyDetector.Sample] = []
        // Anthropic 5h: flat baseline.
        for day in 1...6 {
            let t = now.addingTimeInterval(Double(-day) * 24 * 3600)
            samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                                 observedAt: t, remainingPercent: 100))
        }
        samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                             observedAt: now.addingTimeInterval(-1800),
                             remainingPercent: 100))
        samples.append(.init(providerKey: "anthropic", windowId: "anthropic:5h",
                             observedAt: now.addingTimeInterval(-300),
                             remainingPercent: 0))
        // Cursor weekly: also flat baseline, also draining fast.
        for day in 1...6 {
            let t = now.addingTimeInterval(Double(-day) * 24 * 3600)
            samples.append(.init(providerKey: "cursor", windowId: "cursor:weekly",
                                 observedAt: t, remainingPercent: 100))
        }
        samples.append(.init(providerKey: "cursor", windowId: "cursor:weekly",
                             observedAt: now.addingTimeInterval(-1800),
                             remainingPercent: 100))
        samples.append(.init(providerKey: "cursor", windowId: "cursor:weekly",
                             observedAt: now.addingTimeInterval(-300),
                             remainingPercent: 5))
        let anomalies = AnomalyDetector().evaluate(samples: samples, now: now)
        XCTAssertTrue(anomalies.isEmpty)
    }

    /// Bucket ID suffix after the last colon becomes the human label.
    func testWindowLabelExtractsCadence() {
        XCTAssertEqual(AnomalyDetector.windowLabel(windowId: "anthropic:5h"), "5h")
        XCTAssertEqual(AnomalyDetector.windowLabel(windowId: "cursor:weekly"), "weekly")
        XCTAssertEqual(AnomalyDetector.windowLabel(windowId: "noColon"), "noColon")
    }

    func testHistorySegmentsSplitResetAccountRecoveryAndGap() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        func sample(_ minute: Int, _ percent: Double, account: String = "a",
                    reset: Date? = nil) -> AnomalyDetector.Sample {
            .init(providerKey: "p", windowId: "w", observedAt: t.addingTimeInterval(Double(minute * 60)),
                  remainingPercent: percent, accountKey: account, resetAt: reset)
        }
        let reset = t.addingTimeInterval(20_000)
        let input = [sample(0, 90), sample(5, 80), sample(10, 100), sample(15, 90),
                     sample(20, 80, account: "b"),
                     sample(25, 70, account: "b", reset: t.addingTimeInterval(27 * 60)),
                     sample(30, 65, account: "b", reset: reset),
                     sample(31, 60, account: "b", reset: reset),
                     sample(100, 50, account: "b", reset: reset)]
        let segments = AnomalyDetector.historySegments(samples: input,
                                                        now: t.addingTimeInterval(7000), maxGap: 3600)
        XCTAssertEqual(segments.map(\.count), [2, 2, 2, 2, 1])
    }

    func testHistoryRejectsInvalidAndDeduplicatesCachedSamples() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        func sample(_ minute: Int, _ percent: Double) -> AnomalyDetector.Sample {
            .init(providerKey: "p", windowId: "w", observedAt: t.addingTimeInterval(Double(minute * 60)),
                  remainingPercent: percent)
        }
        let segments = AnomalyDetector.historySegments(
            samples: [sample(0, 80), sample(0, 80), sample(5, .nan), sample(6, .infinity),
                      sample(7, -1), sample(8, 101), sample(10, 70), sample(11, 60),
                      sample(12, 50)], now: t.addingTimeInterval(11 * 60))
        XCTAssertEqual(segments.flatMap { $0 }.map(\.remainingPercent), [80, 70, 60])
    }

    func testMovingResetEstimateDoesNotSplitSlidingWindow() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        var samples: [AnomalyDetector.Sample] = []
        for index in 0..<4 {
            let elapsed = Double(index) * 300
            let remaining = 90.0 - Double(index) * 5
            let observedAt = t.addingTimeInterval(elapsed)
            let resetAt = t.addingTimeInterval(7_200 + elapsed)
            samples.append(AnomalyDetector.Sample(providerKey: "p", windowId: "w",
                                                  observedAt: observedAt,
                                                  remainingPercent: remaining,
                                                  resetAt: resetAt))
        }
        let segments = AnomalyDetector.historySegments(samples: samples,
                                                        now: t.addingTimeInterval(900))
        XCTAssertEqual(segments.map(\.count), [4])
    }

    func testOneHistoricalPairCannotBecomeBaseline() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func sample(_ secondsAgo: Int, _ percent: Double) -> AnomalyDetector.Sample {
            .init(providerKey: "p", windowId: "w", observedAt: now.addingTimeInterval(-Double(secondsAgo)),
                  remainingPercent: percent)
        }
        let samples = [sample(7200, 95), sample(6900, 90), sample(1800, 80), sample(300, 20)]
        XCTAssertTrue(AnomalyDetector().evaluate(samples: samples, now: now).isEmpty)
    }

    func testDisjointShortIntervalsDoNotClaimAnHourOfCoverage() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func sample(_ secondsAgo: Int, _ percent: Double) -> AnomalyDetector.Sample {
            .init(providerKey: "p", windowId: "w", observedAt: now.addingTimeInterval(-Double(secondsAgo)),
                  remainingPercent: percent)
        }
        let samples = [sample(86_400, 90), sample(86_100, 89),
                       sample(64_800, 90), sample(64_500, 89),
                       sample(43_200, 90), sample(42_900, 89),
                       sample(1800, 80), sample(300, 20)]
        XCTAssertTrue(AnomalyDetector().evaluate(samples: samples, now: now).isEmpty)
    }

    func testHistoricalRateWeightsMinutesByDuration() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func sample(_ secondsAgo: Int, _ percent: Double) -> AnomalyDetector.Sample {
            .init(providerKey: "p", windowId: "w", observedAt: now.addingTimeInterval(-Double(secondsAgo)),
                  remainingPercent: percent)
        }
        let samples = [sample(10_800, 90), sample(7200, 89), sample(7140, 88),
                       sample(7080, 87), sample(1800, 80), sample(300, 75.833333333)]
        let anomaly = AnomalyDetector(baselineMultiplier: 2, peakMultiplier: 2)
            .evaluate(samples: samples, now: now).first { $0.kind == .vsBaseline }
        XCTAssertNotNil(anomaly)
        XCTAssertEqual(anomaly?.comparisonRatePercentPerHour ?? 0, 3 / (62.0 / 60), accuracy: 0.001)
        XCTAssertEqual(anomaly?.historyCoverageHours ?? 0, 62.0 / 60, accuracy: 0.001)
    }

    func testOtherAccountHistoryCannotSupplyBaseline() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func sample(_ secondsAgo: Int, _ percent: Double, _ account: String) -> AnomalyDetector.Sample {
            .init(providerKey: "p", windowId: "w", observedAt: now.addingTimeInterval(-Double(secondsAgo)),
                  remainingPercent: percent, accountKey: account)
        }
        let samples = [sample(10_800, 90, "a"), sample(9000, 85, "a"),
                       sample(7200, 80, "a"), sample(5400, 75, "a"),
                       sample(1800, 70, "b"), sample(300, 20, "b")]
        XCTAssertTrue(AnomalyDetector().evaluate(samples: samples, now: now).isEmpty)
    }

    func testAnomalyCarriesMeasuredRatesAndCoverage() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func sample(_ secondsAgo: Int, _ percent: Double) -> AnomalyDetector.Sample {
            .init(providerKey: "p", windowId: "w", observedAt: now.addingTimeInterval(-Double(secondsAgo)),
                  remainingPercent: percent)
        }
        let samples = [sample(10_800, 90), sample(9000, 85), sample(7200, 80),
                       sample(5400, 75), sample(1800, 70), sample(300, 20)]
        let anomaly = AnomalyDetector().evaluate(samples: samples, now: now).first
        XCTAssertNotNil(anomaly)
        XCTAssertEqual(anomaly?.observedAt, now.addingTimeInterval(-300))
        XCTAssertEqual(anomaly?.ratePercentPerHour ?? 0, 120, accuracy: 0.001)
        XCTAssertEqual(anomaly?.comparisonRatePercentPerHour ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(anomaly?.historyCoverageHours ?? 0, 1.5, accuracy: 0.001)
        XCTAssertTrue(anomaly?.summary.contains("available history") == true)
    }

    func testLegacySampleAndAnomalyDecodeWithoutOptionalFields() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sampleData = Data(#"{"providerKey":"p","windowId":"w","observedAt":"2023-11-14T22:13:20Z","remainingPercent":50}"#.utf8)
        let sample = try decoder.decode(AnomalyDetector.Sample.self, from: sampleData)
        XCTAssertNil(sample.accountKey)
        XCTAssertNil(sample.resetAt)
        let anomalyData = Data(#"{"providerKey":"p","windowId":"w","kind":"vsPeak","multiplier":2,"summary":"old"}"#.utf8)
        let anomaly = try decoder.decode(AnomalyDetector.Anomaly.self, from: anomalyData)
        XCTAssertNil(anomaly.ratePercentPerHour)
    }

    func testSampleHistoryDeduplicatesAndKeepsPrivatePermissions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("history.jsonl")
        let history = AnomalyDetector.SampleHistory(url: url)
        let sample = AnomalyDetector.Sample(providerKey: "p", windowId: "w", observedAt: Date(),
                                            remainingPercent: 50)
        try history.append([sample, sample])
        try history.append([sample])
        XCTAssertEqual(try history.load().count, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
    }
}

// MARK: - One alert per event, and a peak check that can actually fire
//
// Owner report 2026-10-09: two alerts arrived back to back for one burst —
// "8.0x your 5hr average" and "8.6x your 7d average" — and the "Versus Your
// Measured Peak" slider appeared to do nothing.
//
// Both had the same cause.  A single window was appending *two* anomalies when
// both comparisons were satisfied, and nothing collapsed them; and the peak
// comparison used the single fastest sample ever recorded, which made the
// slider unreachable in 99.3% of measured hours on this Mac's own data.
extension AnomalyDetectorTests {
    private func busySamples(now: Date, count: Int = 40) -> [AnomalyDetector.Sample] {
        var out: [AnomalyDetector.Sample] = []
        // Steady ~2%/hour for `count` hours (stays inside 0…100), then a sprint
        // in the current hour without splitting history on an invalid level.
        for h in stride(from: count, through: 1, by: -1) {
            out.append(.init(providerKey: "p", windowId: "w",
                             observedAt: now.addingTimeInterval(-Double(h) * 3600),
                             remainingPercent: 100 - Double(count - h) * 2))
        }
        let prior = 100 - Double(count - 1) * 2
        out.append(.init(providerKey: "p", windowId: "w",
                         observedAt: now.addingTimeInterval(-1800),
                         remainingPercent: prior))
        out.append(.init(providerKey: "p", windowId: "w",
                         observedAt: now.addingTimeInterval(-300),
                         remainingPercent: max(5, prior - 15)))
        return out
    }

    /// The headline case: one burst, one anomaly.
    func testOneWindowBurstThatClearsBothBarsProducesOneAnomaly() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let detector = AnomalyDetector(baselineMultiplier: 3.0, peakMultiplier: 1.1)
        let anomalies = detector.evaluate(samples: busySamples(now: now), now: now)
        let forThisWindow = anomalies.filter { $0.windowId == "w" }
        XCTAssertEqual(forThisWindow.count, 1,
                       "one window clearing both bars produced \(forThisWindow.count) alerts")
    }

    /// Both ratios are still recorded, so the UI can say "clears both bars"
    /// without re-deriving them from a rate that has since moved.
    func testBothRatiosAreCarriedOnTheSingleAnomaly() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let detector = AnomalyDetector(baselineMultiplier: 3.0, peakMultiplier: 1.1)
        let anomaly = try XCTUnwrap(detector.evaluate(samples: busySamples(now: now), now: now)
            .first { $0.windowId == "w" })
        XCTAssertNotNil(anomaly.baselineRatio, "the cleared average comparison was dropped")
        XCTAssertNotNil(anomaly.peakRatio, "the cleared peak comparison was dropped")
        XCTAssertEqual(anomaly.multiplier, max(anomaly.baselineRatio ?? 0, anomaly.peakRatio ?? 0),
                       "the headline should be the stronger of the two comparisons")
    }

    /// The stronger comparison names the event.  Preferring peak merely because
    /// it fired would relabel a mild overrun of the average as a record.
    func testTheStrongerComparisonIsTheOneNamed() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let detector = AnomalyDetector(baselineMultiplier: 1.1, peakMultiplier: 1.05)
        let anomaly = try XCTUnwrap(detector.evaluate(samples: busySamples(now: now), now: now)
            .first { $0.windowId == "w" })
        let stronger = (anomaly.baselineRatio ?? 0) >= (anomaly.peakRatio ?? 0) ? AnomalyDetector.Anomaly.Kind.vsBaseline
                                                                                 : .vsPeak
        XCTAssertEqual(anomaly.kind, stronger)
    }

    /// The percentile that replaced the maximum: rare enough to mean something,
    /// and it must not be reachable by the median hour.
    func testPeakReferenceIsAPercentileNotTheMaximum() throws {
        let rates: [Double] = Array(repeating: 10, count: 99) + [500]
        let reference = try XCTUnwrap(AnomalyDetector.peakRatePercentile(rates))
        XCTAssertEqual(reference, 10, accuracy: 0.001,
                       "with one outlier in a hundred, the reference should be the ordinary rate, not 500")
        // Against 500 the old slider could never fire; against 10 it can.
        XCTAssertGreaterThan(50 / reference, 1.5, "a 5x sprint must clear a 1.5x peak bar now")
    }

    /// Too little history for a percentile to mean anything.
    func testPeakReferenceFallsBackToTheMaximumWithFewSamples() throws {
        let reference = try XCTUnwrap(AnomalyDetector.peakRatePercentile([1, 2, 3, 40]))
        XCTAssertEqual(reference, 40, accuracy: 0.001)
        XCTAssertNil(AnomalyDetector.peakRatePercentile([]))
    }

    /// The plain rate the owner asked for, which needs no history at all.
    func testThePlainRateIsCarriedOnItsOwn() throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let anomaly = try XCTUnwrap(AnomalyDetector(baselineMultiplier: 3.0, peakMultiplier: 2.0)
            .evaluate(samples: busySamples(now: now), now: now).first { $0.windowId == "w" })
        let rate = try XCTUnwrap(anomaly.ratePercentPerHour)
        XCTAssertGreaterThan(rate, 0, "the %/hour reading is the one number that needs no prior week")
    }
}

/// Pinned tests for plan-change detection: a step discontinuity in
/// remainingPercent mid-window suppresses the runaway alert while the
/// baseline recalibrates (7 days).
final class PlanChangeDetectionTests: XCTestCase {
    private func sample(_ provider: String, _ window: String, at offset: TimeInterval, percent: Double,
                        from now: Date) -> AnomalyDetector.Sample {
        .init(providerKey: provider, windowId: window,
              observedAt: now.addingTimeInterval(offset), remainingPercent: percent)
    }

    /// A 40-point instant drop (the $100→$20 plan resize shape) is a plan change.
    func testDetectsPlanChangeStep() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var samples: [AnomalyDetector.Sample] = []
        // Steady baseline: 90% an hour ago, 88% 45 min ago.
        samples.append(sample("antigravity", "gemini:5h", at: -3600, percent: 90, from: now))
        samples.append(sample("antigravity", "gemini:5h", at: -2700, percent: 88, from: now))
        // Plan resize: 88% -> 48% in one 15-minute interval.
        samples.append(sample("antigravity", "gemini:5h", at: -1800, percent: 48, from: now))
        samples.append(sample("antigravity", "gemini:5h", at: -900, percent: 47, from: now))

        let changes = AnomalyDetector.detectPlanChanges(samples: samples, now: now)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].providerKey, "antigravity")
        XCTAssertEqual(changes[0].windowId, "gemini:5h")
        XCTAssertTrue(changes[0].isActive(now: now))
        // Recalibration is 7 days after the change.
        let expected = now.addingTimeInterval(-1800).addingTimeInterval(7 * 86_400)
        XCTAssertEqual(changes[0].recalibratedAt?.timeIntervalSince1970 ?? 0,
                       expected.timeIntervalSince1970, accuracy: 1)
    }

    /// A 10-point drop is heavy use, not a plan change.
    func testSmallDropIsNotPlanChange() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            sample("antigravity", "gemini:5h", at: -3600, percent: 90, from: now),
            sample("antigravity", "gemini:5h", at: -1800, percent: 80, from: now),
        ]
        XCTAssertTrue(AnomalyDetector.detectPlanChanges(samples: samples, now: now).isEmpty)
    }

    /// A 30-point move spread over 3 hours is a burn, not a discontinuity.
    func testGradualMoveIsNotPlanChange() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            sample("antigravity", "gemini:5h", at: -3 * 3600, percent: 90, from: now),
            sample("antigravity", "gemini:5h", at: 0, percent: 60, from: now),
        ]
        XCTAssertTrue(AnomalyDetector.detectPlanChanges(samples: samples, now: now).isEmpty)
    }

    /// A jump back up is a window reset, not a plan change — and resets
    /// already split segments, so no step is visible.
    func testResetJumpIsNotPlanChange() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            sample("antigravity", "gemini:5h", at: -3600, percent: 10, from: now),
            sample("antigravity", "gemini:5h", at: -1800, percent: 100, from: now),
        ]
        XCTAssertTrue(AnomalyDetector.detectPlanChanges(samples: samples, now: now).isEmpty)
    }

    /// A plan change older than 7 days no longer suppresses anomalies.
    func testPlanChangeExpiresAfter7Days() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = now.addingTimeInterval(-8 * 86_400)
        let change = AnomalyDetector.PlanChange(providerKey: "p", windowId: "w", changedAt: old)
        XCTAssertFalse(change.isActive(now: now))
        XCTAssertTrue(change.isActive(now: old.addingTimeInterval(6 * 86_400)))
    }

    /// The owner's Settings-text signal stays active until the text changes.
    func testManualPlanChangeStaysActive() {
        let change = AnomalyDetector.PlanChange(providerKey: "p", windowId: "w",
                                                changedAt: nil, isManual: true)
        XCTAssertTrue(change.isActive())
        XCTAssertTrue(change.isActive(now: Date.distantFuture))
        XCTAssertNil(change.recalibratedAt)
    }

    /// Settings text mentioning a plan/cost change is an explicit signal.
    func testMentionsPlanChange() {
        XCTAssertTrue(PlatformCustomInfo(renewalDateText: "on 5th, but ↓ $50/mo plan then (1x)").mentionsPlanChange)
        XCTAssertTrue(PlatformCustomInfo(planName: "downgrade to Basic").mentionsPlanChange)
        XCTAssertTrue(PlatformCustomInfo(costUsd: "$20 → $100").mentionsPlanChange)
        XCTAssertFalse(PlatformCustomInfo(planName: "Pro", costUsd: "$20/mo",
                                          renewalDateText: "on the 5th").mentionsPlanChange)
        XCTAssertFalse(PlatformCustomInfo().mentionsPlanChange)
    }

    /// The package failures: a cliff that is still the latest sample is the
    /// live burn.  It must stay a runaway, not a 7-day plan change.
    func testLiveCliffStaysRunaway() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func sample(_ secondsAgo: Int, _ percent: Double) -> AnomalyDetector.Sample {
            .init(providerKey: "p", windowId: "w",
                  observedAt: now.addingTimeInterval(-Double(secondsAgo)),
                  remainingPercent: percent)
        }
        let samples = [sample(10_800, 90), sample(9000, 85), sample(7200, 80),
                       sample(5400, 75), sample(1800, 70), sample(300, 20)]
        XCTAssertTrue(AnomalyDetector.detectPlanChanges(samples: samples, now: now).isEmpty)
        let anomaly = AnomalyDetector().evaluate(samples: samples, now: now).first
        XCTAssertNotNil(anomaly)
        XCTAssertEqual(anomaly?.ratePercentPerHour ?? 0, 120, accuracy: 0.001)
    }

    /// The same size of drop, once a later sample shows the new level held,
    /// is a plan change and the runaway check stands down.
    func testSettledStepSuppressesRunaway() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        func sample(_ secondsAgo: Int, _ percent: Double) -> AnomalyDetector.Sample {
            .init(providerKey: "p", windowId: "w",
                  observedAt: now.addingTimeInterval(-Double(secondsAgo)),
                  remainingPercent: percent)
        }
        let samples = [sample(10_800, 90), sample(9000, 85), sample(7200, 80),
                       sample(5400, 75), sample(1800, 70), sample(900, 30), sample(300, 29)]
        XCTAssertEqual(AnomalyDetector.detectPlanChanges(samples: samples, now: now).count, 1)
        XCTAssertTrue(AnomalyDetector().evaluate(samples: samples, now: now).isEmpty)
    }

    /// Two large steps in a row are still spending.  That is not a settled resize.
    func testContinuedBurnIsNotPlanChange() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            sample("antigravity", "gemini:5h", at: -2700, percent: 90, from: now),
            sample("antigravity", "gemini:5h", at: -1800, percent: 50, from: now),
            sample("antigravity", "gemini:5h", at: -900, percent: 20, from: now),
        ]
        XCTAssertTrue(AnomalyDetector.detectPlanChanges(samples: samples, now: now).isEmpty)
    }

    /// A downgrade that ends a segment (the next sample is a later session)
    /// still counts once the step has aged out of the live-burn hour, and the
    /// runaway check stands down for the fresh burn that follows.
    func testAgedTrailingStepIsPlanChangeAndSuppressesRunaway() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var samples: [AnomalyDetector.Sample] = []
        var percent = 90.0
        for ago in stride(from: 14_400, through: 7_200, by: -300) {
            samples.append(sample("p", "w", at: -Double(ago), percent: percent, from: now))
            percent -= 0.2
        }
        samples.append(sample("p", "w", at: -6_900, percent: percent, from: now))
        samples.append(sample("p", "w", at: -6_600, percent: percent - 44, from: now))
        samples.append(sample("p", "w", at: -600, percent: percent - 45, from: now))
        samples.append(sample("p", "w", at: -300, percent: percent - 74, from: now))

        let changes = AnomalyDetector.detectPlanChanges(samples: samples, now: now)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].changedAt?.timeIntervalSince1970 ?? 0,
                       now.addingTimeInterval(-6_600).timeIntervalSince1970, accuracy: 1)
        XCTAssertTrue(AnomalyDetector().evaluate(samples: samples, now: now).isEmpty,
                      "the aged step invalidates the baseline, so the later burn is not a runaway")
    }

    /// The same cliff, while its newest sample is still inside the live-burn
    /// hour, stays a runaway.  Ten minutes is not `planChangeUnconfirmedQuiet`.
    func testRecentTrailingCliffStaysRunaway() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            sample("p", "w", at: -10_800, percent: 99, from: now),
            sample("p", "w", at: -9_000, percent: 98.5, from: now),
            sample("p", "w", at: -7_200, percent: 98, from: now),
            sample("p", "w", at: -5_400, percent: 97.5, from: now),
            sample("p", "w", at: -3_000, percent: 92, from: now),
            sample("p", "w", at: -2_700, percent: 90, from: now),
            sample("p", "w", at: -2_400, percent: 89, from: now),
            sample("p", "w", at: -600, percent: 19, from: now),
        ]
        XCTAssertTrue(AnomalyDetector.detectPlanChanges(samples: samples, now: now).isEmpty)
        XCTAssertFalse(AnomalyDetector().evaluate(samples: samples, now: now).isEmpty)
    }

    /// Two settled resizes in one continuously polled segment: the later
    /// change is the anchor, so recalibration follows the second resize.
    func testLatestSettledStepWins() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let samples = [
            sample("p", "w", at: -3_600, percent: 90, from: now),
            sample("p", "w", at: -3_300, percent: 88, from: now),
            sample("p", "w", at: -3_000, percent: 48, from: now),
            sample("p", "w", at: -2_700, percent: 47, from: now),
            sample("p", "w", at: -2_400, percent: 46, from: now),
            sample("p", "w", at: -2_100, percent: 45, from: now),
            sample("p", "w", at: -1_800, percent: 15, from: now),
            sample("p", "w", at: -1_500, percent: 14, from: now),
            sample("p", "w", at: -1_200, percent: 13, from: now),
        ]
        let changes = AnomalyDetector.detectPlanChanges(samples: samples, now: now)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(changes[0].changedAt?.timeIntervalSince1970 ?? 0,
                       now.addingTimeInterval(-1_800).timeIntervalSince1970, accuracy: 1)
    }
}
