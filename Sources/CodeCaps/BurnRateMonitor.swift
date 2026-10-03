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
                remainingPercent: percent)
        }
        try? history(at: historyURL).append(samples)
    }

    /// Evaluate the owner's current thresholds against everything on disk.
    static func evaluate(baseline: Double, peak: Double, now: Date = Date(),
                         historyURL: URL? = nil) -> [AnomalyDetector.Anomaly] {
        guard let samples = try? history(at: historyURL).load(), !samples.isEmpty else { return [] }
        return AnomalyDetector(baselineMultiplier: baseline, peakMultiplier: peak)
            .evaluate(samples: samples, now: now)
    }

    /// Whether there is enough history for either threshold to mean anything.
    /// A rolling 7-day average needs most of a week; the peak check needs only
    /// a few hours, because it compares against the worst hour seen so far.
    static func historySummary(now: Date = Date(),
                               historyURL: URL? = nil) -> (days: Double, enoughForBaseline: Bool, enoughForPeak: Bool) {
        guard let samples = try? history(at: historyURL).load(), let first = samples.map(\.observedAt).min() else {
            return (0, false, false)
        }
        let days = max(0, now.timeIntervalSince(first) / 86_400)
        return (days, days >= 1, days >= 1.0 / 24)
    }
}

struct BurnRateNotification: Equatable, Sendable {
    let identifier: String
    let title: String
    let body: String
    let anomalies: [AnomalyDetector.Anomaly]
    let sound: ResetAlarmSound

    init(anomalies: [AnomalyDetector.Anomaly], sound: ResetAlarmSound) {
        self.anomalies = anomalies
        self.sound = sound
        let first = anomalies[0]
        identifier = "codecaps.runaway.\(first.providerKey).\(first.windowId)"
        title = "Runaway Usage Detected"
        body = anomalies.map(\.summary).joined(separator: sentenceGap)
    }
}
