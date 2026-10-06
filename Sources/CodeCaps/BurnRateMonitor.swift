import Foundation
import QuotaCore

/// Drives `AnomalyDetector` — the runaway-agent alert the owner asked for.
///
/// The detector itself was already written and tested in QuotaCore, but nothing
/// in the app ever called it.  This is the missing half: it records a sample on
/// every refresh, evaluates the owner's two thresholds against the rolling
/// history, and reports what it finds.
///
/// **The history has to be earned.**  The baseline is a rolling comparison
/// against the owner's own past week, so on a fresh install there is nothing to
/// compare against and the alert cannot fire.  It needs roughly a week of
/// five-minute samples before the "vs. average" threshold means anything, and
/// a few hours before the "vs. worst hour" one does.  `hasEnoughHistory`
/// exists so the UI can say that rather than showing a silent switch.
enum BurnRateMonitor {

    /// Current hour's burn versus the rolling 7-day average hour.
    ///
    /// 5x is the shipped default and the owner-facing recommendation.  The
    /// reason to start there rather than lower: at 3x a long agent run looks
    /// exactly like a runaway, and an alert that cries wolf on a normal
    /// afternoon gets muted within a week.  At 5x the allowance is going to be
    /// gone before the window resets, which is the actual harm.  Sensible
    /// range 2-10; below 3 expect regular false alarms, above 8 a runaway
    /// that ends your quota may not trip it.
    static let recommendedBaselineMultiplier: Double = 5
    static let baselineRange: ClosedRange<Double> = 2...10

    /// Current hour's burn versus the owner's own worst hour in the last week.
    ///
    /// 2x is the default.  This one fires far more readily than the baseline —
    /// "faster than any hour you had last week" is a much lower bar than "5x
    /// your average" — which is deliberate: it is the check that catches a
    /// stuck loop, and a runaway is worth interrupting.  Range 1.1-4.  Below
    /// 1.5 it will fire on ordinary variation in your own work; above 3 it
    /// only catches the catastrophic.
    static let recommendedPeakMultiplier: Double = 2
    static let peakRange: ClosedRange<Double> = 1.1...4
    static let alertCooldown: TimeInterval = 60 * 60

    /// Where the sample history lives, beside the snapshot BotFleet reads.
    static var historyURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Usage Monitor/burn-rate-samples.jsonl")
    }

    private static func history(at url: URL?) -> AnomalyDetector.SampleHistory {
        AnomalyDetector.SampleHistory(url: url ?? historyURL)
    }

    /// One sample per window, per refresh.  Takes windows rather than platform
    /// sections because a sample only needs the key, the id and the percentage.
    static func record(_ windows: [QuotaWindow], now: Date, historyURL: URL? = nil) {
        let samples = windows.compactMap { window -> AnomalyDetector.Sample? in
            guard let percent = window.remainingPercent else { return nil }
            return AnomalyDetector.Sample(
                providerKey: window.canonicalProviderKey,
                windowId: window.id,
                observedAt: window.occurredDate ?? now,
                remainingPercent: percent,
                absoluteRemaining: window.absoluteRemaining,
                accountKey: window.accountKey,
                resetAt: window.resetDate,
                periodStart: window.periodStartDate)
        }
        try? history(at: historyURL).append(samples)
    }

    static func loadSamples(historyURL: URL? = nil) -> [AnomalyDetector.Sample] {
        (try? history(at: historyURL).load()) ?? []
    }

    /// Evaluate the owner's current thresholds against everything on disk.
    static func evaluate(baseline: Double, peak: Double, now: Date = Date(),
                         historyURL: URL? = nil) -> [AnomalyDetector.Anomaly] {
        guard let samples = try? history(at: historyURL).load(), !samples.isEmpty else { return [] }
        return AnomalyDetector(baselineMultiplier: baseline, peakMultiplier: peak)
            .evaluate(samples: samples, now: now)
    }

    /// Plan/quota-size changes detected as step discontinuities.  The runaway
    /// detector already suppresses these windows; this exposes them so the UI
    /// can show the informational plan-change state instead of an alert.
    static func evaluatePlanChanges(now: Date = Date(),
                                    historyURL: URL? = nil) -> [AnomalyDetector.PlanChange] {
        guard let samples = try? history(at: historyURL).load(), !samples.isEmpty else { return [] }
        return AnomalyDetector.detectPlanChanges(samples: samples, now: now)
    }

    /// A descriptive count only.  Detector readiness is per provider, window,
    /// account, and quota period, so one old sample cannot make all sources ready.
    static func historySummary(now: Date = Date(),
                               historyURL: URL? = nil) -> (sampleCount: Int, days: Double) {
        let samples = loadSamples(historyURL: historyURL).filter {
            $0.observedAt >= now.addingTimeInterval(-7 * 86_400) && $0.observedAt <= now
        }
        guard let first = samples.map(\.observedAt).min() else { return (0, 0) }
        return (samples.count, max(0, now.timeIntervalSince(first) / 86_400))
    }
}

public struct RunawayAlertRecord: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let timestamp: Date
    public let providerKey: String
    public let providerLabel: String
    public let windowId: String
    public let windowLabel: String
    public let multiplier: Double
    public let comparison: String
    public let summary: String
    public let ratePercentPerHour: Double?
    public let comparisonRatePercentPerHour: Double?
    public let historyCoverageHours: Double?

    public init(id: String = UUID().uuidString,
                timestamp: Date = Date(),
                providerKey: String,
                providerLabel: String,
                windowId: String,
                windowLabel: String,
                multiplier: Double,
                comparison: String,
                summary: String,
                ratePercentPerHour: Double? = nil,
                comparisonRatePercentPerHour: Double? = nil,
                historyCoverageHours: Double? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.providerKey = providerKey
        self.providerLabel = providerLabel
        self.windowId = windowId
        self.windowLabel = windowLabel
        self.multiplier = multiplier
        self.comparison = comparison
        self.summary = summary
        self.ratePercentPerHour = ratePercentPerHour
        self.comparisonRatePercentPerHour = comparisonRatePercentPerHour
        self.historyCoverageHours = historyCoverageHours
    }
}

struct BurnRateNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let anomalies: [AnomalyDetector.Anomaly]
    let sound: ResetAlarmSound
    let providerLabel: String?
    let windowLabel: String?

    init(anomalies: [AnomalyDetector.Anomaly], sound: ResetAlarmSound, providerLabel: String? = nil, windowLabel: String? = nil) {
        self.anomalies = anomalies
        self.sound = sound
        self.providerLabel = providerLabel
        self.windowLabel = windowLabel
        let first = anomalies[0]
        identifier = "codecaps.runaway.\(first.providerKey).\(first.windowId)"
        let prov = providerLabel ?? first.providerKey.capitalized
        if let windowLabel, !windowLabel.isEmpty {
            title = "Runaway Usage: \(prov) (\(windowLabel))"
        } else {
            title = "Runaway Usage: \(prov)"
        }
        let win = windowLabel.map { " (\($0))" } ?? ""
        body = anomalies.map { anomaly in
            let comp = anomaly.kind == .vsPeak ? "measured peak" : "available-history average"
            let mult = anomaly.multiplier.formatted(.number.precision(.fractionLength(1)))
            if let rate = anomaly.ratePercentPerHour {
                return "\(prov)\(win) is spending \(rate.formatted(.number.precision(.fractionLength(1)))) percentage points per hour, \(mult)× your \(comp)."
            }
            return "\(prov)\(win) is burning at \(mult)× your \(comp)."
        }.joined(separator: sentenceGap)
    }
}
