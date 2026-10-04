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
        let vsPeak = anomalies.first { $0.kind == .vsPeak }
        XCTAssertNotNil(vsPeak, "Expected a vsPeak anomaly; got \(anomalies.map(\.summary))")
        XCTAssertEqual(vsPeak?.providerKey, "anthropic")
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
        let samples = (0..<4).map { index in
            AnomalyDetector.Sample(providerKey: "p", windowId: "w",
                                   observedAt: t.addingTimeInterval(Double(index * 300)),
                                   remainingPercent: 90 - Double(index * 5),
                                   resetAt: t.addingTimeInterval(Double(7200 + index * 300)))
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
