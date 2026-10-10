import Foundation

/// Predicts when a quota window will run out, from the samples the app already
/// records on every refresh.
///
/// The owner's ask (2026-10-10): "when CC notices that an app is at its quota
/// right now and not working until a little over an hour from now … we'd like
/// to know when there are like, idk, 5-15min left but I know you can't possibly
/// know that exactly."
///
/// It cannot know exactly, and this does not pretend to.  It measures the rate
/// the window is actually being consumed at, projects it forward, and reports
/// how many minutes of headroom are left.  The honest output is a range of
/// minutes, not a countdown.
///
/// Deliberately simple arithmetic — a slope over the trailing samples — because
/// a forecast that costs a model and a matrix multiply to produce is a forecast
/// nobody can explain when it is wrong.
public struct QuotaExhaustionForecast: Equatable, Sendable {

    /// Why there is no forecast, when there is none.
    public enum Unavailable: String, Equatable, Sendable {
        /// No samples recorded yet — a fresh install cannot forecast anything.
        case noHistory
        /// The window is not being consumed at all, so it is not going to run out.
        case notConsuming
        /// Samples are too sparse to measure a rate: a single reading, or a gap
        /// longer than `maxSampleGap`, gives a slope that means nothing.
        case tooFewSamples
        /// `remainingPercent` was nil across the window, so there is no level
        /// to project from.
        case noReading
    }

    /// Percentage points consumed per minute, as a positive number.
    public let percentPerMinute: Double
    /// Headroom at the latest sample, in minutes.  `nil` once `unavailable` is set.
    public let minutesRemaining: Double?
    /// The level-based warning also applies: the window is close to its cap
    /// whether or not it is being consumed fast right now.
    public let isNearCap: Bool
    public let unavailable: Unavailable?
    /// The samples this forecast was measured from, oldest first.
    public let sampleCount: Int

    public var isAvailable: Bool { unavailable == nil }

    // MARK: Policy

    /// How far back to measure.  Long enough that a single quiet sample does not
    /// dominate, short enough that a burst an hour ago is not still being
    /// extrapolated.
    public static let lookback: TimeInterval = 90 * 60

    /// A gap longer than this means the app was not watching, so the slope
    /// across it is not a rate anyone observed.
    public static let maxSampleGap: TimeInterval = 30 * 60

    /// Below this consumption rate the window is idle.  Expressed in
    /// percentage points per minute: 0.01 is 0.6 points an hour, which rounds
    /// to nothing over any horizon worth warning about.
    public static let minimumRate: Double = 0.01

    /// The owner asked for roughly "5-15min left".  The horizon is the upper
    /// bound of that: warn when headroom drops under it, and report the actual
    /// figure so the warning says how urgent it is rather than just that it is.
    public static let warningHorizon: TimeInterval = 60 * 60

    /// The share **USED** at which a window counts as near its cap, independent
    /// of any forecast.
    ///
    /// The owner named these as used percentages — "97-100% on 5hr or 99-100%
    /// on 1wk" — so they are compared against `100 - remaining`.  Treating them
    /// as remaining percentages instead flagged nearly every healthy window,
    /// because 96% remaining trivially satisfies "remaining <= 97".
    public static func nearCapPercent(forCadence token: String?) -> Double {
        let combined = (token ?? "").lowercased()
        // A weekly window is a much longer commitment than a 5-hour one, so it
        // gets a stricter level: being 1% from a week away matters more than
        // being 1% from five hours away.
        if combined.contains("week") || combined.contains("7d") || combined.contains("1w") {
            return 99
        }
        return 97
    }

    // MARK: Measurement

    /// Measure one window from its samples, oldest first.  `now` bounds the
    /// trailing window and is not required to match the newest sample, so this
    /// is testable without a live clock.
    public static func measure(
        samples: [AnomalyDetector.Sample],
        now: Date,
        cadenceToken: String? = nil
    ) -> QuotaExhaustionForecast {
        let nearCapLevel = nearCapPercent(forCadence: cadenceToken)

        // Only the trailing window, and only readings that carry a percentage.
        let usable = samples
            .filter { $0.observedAt <= now }
            .filter { $0.remainingPercent != nil }
            .sorted { $0.observedAt < $1.observedAt }

        let trailing = usable.filter { now.timeIntervalSince($0.observedAt) <= lookback }

        // Near-cap is a LEVEL judgement, so it does not depend on having any
        // history at all: a fresh install can still say "this is nearly spent".
        let newest = trailing.last
        let remaining = newest?.remainingPercent
        // Used share, compared against the owner's used-percentage threshold.
        let isNearCap = remaining.map { (100 - $0) >= nearCapLevel } ?? false

        guard trailing.count >= 2 else {
            return QuotaExhaustionForecast(
                percentPerMinute: 0,
                minutesRemaining: nil,
                isNearCap: isNearCap,
                unavailable: usable.isEmpty ? .noReading : .tooFewSamples,
                sampleCount: trailing.count)
        }

        // Reject any gap the app was not watching: a slope across it is an
        // average of behaviour nobody observed.
        for (a, b) in zip(trailing, trailing.dropFirst()) {
            if b.observedAt.timeIntervalSince(a.observedAt) > maxSampleGap {
                return QuotaExhaustionForecast(
                    percentPerMinute: 0,
                    minutesRemaining: nil,
                    isNearCap: isNearCap,
                    unavailable: .tooFewSamples,
                    sampleCount: trailing.count)
            }
        }

        let first = trailing[0]
        let last = trailing[trailing.count - 1]
        let elapsed = last.observedAt.timeIntervalSince(first.observedAt) / 60
        guard elapsed > 0 else {
            return QuotaExhaustionForecast(
                percentPerMinute: 0, minutesRemaining: nil,
                isNearCap: isNearCap, unavailable: .tooFewSamples,
                sampleCount: trailing.count)
        }

        let spent = (first.remainingPercent ?? 0) - (last.remainingPercent ?? 0)
        // A window can be topped up mid-period, which shows as remaining going
        // UP. That is not a negative burn rate to project; it is no signal.
        guard spent > 0 else {
            return QuotaExhaustionForecast(
                percentPerMinute: 0,
                minutesRemaining: nil,
                isNearCap: isNearCap,
                unavailable: .notConsuming,
                sampleCount: trailing.count)
        }

        let rate = spent / elapsed
        guard rate >= minimumRate else {
            return QuotaExhaustionForecast(
                percentPerMinute: rate, minutesRemaining: nil,
                isNearCap: isNearCap, unavailable: .notConsuming,
                sampleCount: trailing.count)
        }

        let headroom = (last.remainingPercent ?? 0) / rate
        return QuotaExhaustionForecast(
            percentPerMinute: rate,
            minutesRemaining: headroom,
            isNearCap: isNearCap,
            unavailable: nil,
            sampleCount: trailing.count)
    }

    /// The warning the owner actually wants: either the window is about to run
    /// out, or it is already nearly spent and we are not watching closely
    /// enough to see it move.
    public var warrantsWarning: Bool {
        guard unavailable == nil, let minutes = minutesRemaining else { return false }
        return minutes <= Self.warningHorizon
    }

    /// "About 12 minutes", "About 1 hour".  Never a false precision: the input
    /// is a projection from a handful of samples, and claiming "12:04" would be
    /// a lie dressed as a number.
    public var humanizedHeadroom: String? {
        guard let minutes = minutesRemaining, minutes.isFinite, minutes >= 0 else { return nil }
        if minutes < 1 { return "less than a minute" }
        if minutes < 60 { return "about \(Int(minutes.rounded())) min" }
        let hours = minutes / 60
        if hours < 10 { return "about \(Int(hours.rounded())) hour\(Int(hours.rounded()) == 1 ? "" : "s")" }
        // Round to the NEAREST 12-hour band before truncating.  Truncating the
        // ratio first turned any headroom in [10, 12) hours into a factor of
        // zero, so a window with ten hours left announced "about 0 hours".
        return "about \(Int((hours / 12).rounded()) * 12) hours"
    }
}

// MARK: - Convenience over the live history

extension QuotaExhaustionForecast {
    /// Measure every window in one pass over the recorded history.
    ///
    /// One `load()` and one partition beats a `load()` per window: the history
    /// file holds every platform's samples, and re-reading it for each row is
    /// the kind of thing that makes a menu bar stutter.
    public static func measureAll(
        samples: [QuotaWindow],
        now: Date,
        historyURL: URL? = nil
    ) -> [String: QuotaExhaustionForecast] {
        var history: [AnomalyDetector.Sample] = []
        if let historyURL {
            history = (try? AnomalyDetector.SampleHistory(url: historyURL).load()) ?? []
        }
        return measureAll(samples: samples, now: now, history: history)
    }

    /// The same, when the caller already holds the history.
    public static func measureAll(
        samples: [QuotaWindow],
        now: Date,
        history: [AnomalyDetector.Sample]
    ) -> [String: QuotaExhaustionForecast] {
        let byWindow = Dictionary(grouping: history, by: { "\($0.providerKey)|\($0.windowId)" })
        var out: [String: QuotaExhaustionForecast] = [:]
        for window in samples {
            let key = "\(window.canonicalProviderKey)|\(window.id)"
            let prior = byWindow[key] ?? []
            let combined = prior + [
                AnomalyDetector.Sample(
                    providerKey: window.canonicalProviderKey,
                    windowId: window.id,
                    observedAt: now,
                    remainingPercent: window.remainingPercent)
            ]
            out[key] = measure(samples: combined, now: now, cadenceToken: window.window)
        }
        return out
    }
}