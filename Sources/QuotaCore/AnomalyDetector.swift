import Foundation

/// Surfaces "your usage is going down faster than usual" signals.
///
/// Two thresholds, both user-tunable, both default to a value that fires only
/// when the rate is well outside the owner's own recent pattern:
///
/// 1. **`baselineMultiplier`** — current hour's rate of change vs measured
///    recent history.  Default 5×.
///
/// 2. **`peakMultiplier`** — current hour's rate of change vs the highest
///    measured rate in available history.  Default 2×.
///
/// Rate is computed as `percentPerHour` from consecutive samples in the
/// history file.  Reset, account, and data gaps are discontinuities.
///
/// The detector is pure: a `Sample` array in, an `[Anomaly]` array out.
/// Persistence and the IO plumbing live elsewhere.
public struct AnomalyDetector: Sendable {
    public struct Sample: Codable, Equatable, Sendable {
        public let providerKey: String
        public let windowId: String
        public let observedAt: Date
        /// 0…100.  nil is treated as "not measurable" and skipped.
        public let remainingPercent: Double?
        /// Absolute remaining quota (tokens, USD, videos…) when the reader
        /// reports it.  The detector prefers this over % when consistently
        /// available: absolute burn is immune to plan-size changes.
        public let absoluteRemaining: Double?
        public let accountKey: String?
        public let resetAt: Date?
        public let periodStart: Date?

        public init(providerKey: String, windowId: String, observedAt: Date, remainingPercent: Double?,
                    absoluteRemaining: Double? = nil,
                    accountKey: String? = nil, resetAt: Date? = nil, periodStart: Date? = nil) {
            self.providerKey = providerKey
            self.windowId = windowId
            self.observedAt = observedAt
            self.remainingPercent = remainingPercent
            self.absoluteRemaining = absoluteRemaining
            self.accountKey = accountKey
            self.resetAt = resetAt
            self.periodStart = periodStart
        }
    }

    public struct Anomaly: Equatable, Sendable, Codable {
        public enum Kind: String, Codable, Sendable, Equatable {
            /// Current rate is N× the measured historical average.
            case vsBaseline
            /// Current rate is N× the measured historical peak rate.
            case vsPeak
        }
        public let providerKey: String
        public let windowId: String
        public let kind: Kind
        /// The actual multiplier observed, e.g. 6.4 means current is 6.4× the
        /// comparison baseline.  Always > 1.
        public let multiplier: Double
        /// Example: "Spending fast vs 5h: 6.4× your average over available history."
        public let summary: String
        /// Percentage points of allowance depleted per hour.
        public let ratePercentPerHour: Double?
        public let comparisonRatePercentPerHour: Double?
        public let observedAt: Date?
        /// Span between the earliest and latest valid comparison samples.
        public let historyCoverageHours: Double?
        /// Both ratios, when both were exceeded, so the settings screen can say
        /// "cleared both the average and the peak bar" without re-deriving them.
        /// `multiplier` alone is not enough for that, which is why these are
        /// stored rather than recomputed from a rate that has since moved.
        public let baselineRatio: Double?
        public let peakRatio: Double?

        public init(providerKey: String, windowId: String, kind: Kind, multiplier: Double, summary: String,
                    ratePercentPerHour: Double? = nil, comparisonRatePercentPerHour: Double? = nil,
                    observedAt: Date? = nil, historyCoverageHours: Double? = nil,
                    baselineRatio: Double? = nil, peakRatio: Double? = nil) {
            self.providerKey = providerKey
            self.windowId = windowId
            self.kind = kind
            self.multiplier = multiplier
            self.summary = summary
            self.ratePercentPerHour = ratePercentPerHour
            self.comparisonRatePercentPerHour = comparisonRatePercentPerHour
            self.observedAt = observedAt
            self.historyCoverageHours = historyCoverageHours
            self.baselineRatio = baselineRatio
            self.peakRatio = peakRatio
        }

        /// The plain rate the owner asked for (2026-10-09): "%/hour" on its own
        /// tells someone how fast quota is going without reference to any prior
        /// week, and needs no multiplier to be read.
        ///
        /// One hour's worth of depletion is `100 - remainingPercent`, so the
        /// fraction of a whole window being burned per hour is that over the
        /// window's own period.  Returned as a percentage of the window burned
        /// per hour, so `2.5%` reads as "a quarter of this window, every hour".
        public var windowPercentPerHour: Double? {
            guard let ratePercentPerHour else { return nil }
            return ratePercentPerHour
        }
    }

    /// A detected plan/quota-size change: a step discontinuity in
    /// remainingPercent mid-window that is NOT a window reset.  Resets (a jump
    /// back up to a fresh window) already split history segments; a plan
    /// change is a sudden level shift that then holds.  The same size of drop
    /// with no later sample stays a runaway signal until it has aged out of
    /// the live-burn hour.  While the baseline is still mostly old-plan data,
    /// burn-rate comparisons are invalid, so the runaway detector stands down
    /// for this window until the baseline is all new-plan data (7 days).
    /// Downgrades are detected from the % step; upgrades (a jump up that is
    /// not a reset) are not yet distinguished from resets.
    public struct PlanChange: Equatable, Sendable, Codable {
        public let providerKey: String
        public let windowId: String
        /// The sample time at which the discontinuity was observed, or nil
        /// when the owner noted the change in Settings text (no date known).
        public let changedAt: Date?
        /// True when the owner noted the change in Settings text rather than
        /// the detector finding a discontinuity.  Stays active until the
        /// Settings text no longer mentions a change.
        public let isManual: Bool

        /// Stats become valid again 7 days after the change, once the rolling
        /// baseline is all new-plan data.  Nil for manual signals.
        public var recalibratedAt: Date? {
            changedAt.map { $0.addingTimeInterval(7 * 86_400) }
        }

        public func isActive(now: Date = Date()) -> Bool {
            if isManual { return true }
            guard let recalibratedAt else { return false }
            return now < recalibratedAt
        }

        /// Stable identity for SwiftUI lists.
        public var planChangeId: String { "\(providerKey)\u{1F}\(windowId)" }

        public init(providerKey: String, windowId: String, changedAt: Date?, isManual: Bool = false) {
            self.providerKey = providerKey
            self.windowId = windowId
            self.changedAt = changedAt
            self.isManual = isManual
        }
    }

    /// The minimum single-interval drop (percentage points) that counts as a
    /// plan-change step.  Normal burn — even a heavy agent afternoon — moves a
    /// few points per sample; a plan resize teleports the level.
    public static let planChangeStepPoints: Double = 25

    /// The maximum gap between the two samples of a step.  A 25-point move
    /// spread over many hours is heavy use, not a discontinuity.
    public static let planChangeMaxGap: TimeInterval = 2 * 3600

    /// How long a trailing step must sit with no follow-up sample before it
    /// counts as a plan change.  The runaway check only treats the last 15
    /// minutes as the live burn; an hour without a confirming sample means
    /// that interval is no longer the current burn.
    public static let planChangeUnconfirmedQuiet: TimeInterval = 3600

    public var baselineMultiplier: Double
    public var peakMultiplier: Double

    public init(baselineMultiplier: Double = 5.0, peakMultiplier: Double = 2.0) {
        self.baselineMultiplier = baselineMultiplier
        self.peakMultiplier = peakMultiplier
    }

    /// Evaluate `samples` and return every (provider, window) pair whose
    /// current-hour rate exceeds the configured thresholds.  One Anomaly per
    /// (provider, window, kind) — the same window can fire both `vsBaseline`
    /// and `vsPeak` if both thresholds are crossed.
    public func evaluate(samples: [Sample], now: Date = Date()) -> [Anomaly] {
        guard baselineMultiplier.isFinite, baselineMultiplier > 1,
              peakMultiplier.isFinite, peakMultiplier > 1 else { return [] }
        let groups = Dictionary(grouping: Self.historySegments(samples: samples, now: now,
                                                               maxGap: 3600)) {
            PairKey(provider: $0[0].providerKey, window: $0[0].windowId)
        }
        // A plan change invalidates the baseline for its window: the runaway
        // check stands down there until the baseline is all new-plan data.
        // Thresholds and tuning are untouched; the window is simply skipped.
        let planChanged: Set<PairKey> = Set(
            Self.detectPlanChanges(samples: samples, now: now)
                .filter { $0.isActive(now: now) }
                .map { PairKey(provider: $0.providerKey, window: $0.windowId) }
        )
        var out: [Anomaly] = []
        for (key, segments) in groups {
            guard !planChanged.contains(key) else { continue }
            guard let latest = segments.max(by: { $0.last!.observedAt < $1.last!.observedAt }),
                  let observedAt = latest.last?.observedAt,
                  now.timeIntervalSince(observedAt) <= 15 * 60,
                  let currentRate = Self.currentHourRatePercent(samples: latest, now: now),
                  currentRate > 0 else { continue }
            let historical = segments.filter { $0[0].accountKey == latest[0].accountKey }.flatMap { segment in
                Self.historicalPairs(segment, now: now)
            }
            // Disjoint five-minute islands are not an hour of observation.
            // Sum measured pair durations rather than the wall-clock span.
            let coverage = historical.reduce(0) { $0 + $1.hours }
            guard historical.count >= 3, coverage >= 1 else { continue }
            let depletion = historical.reduce(0) { $0 + $1.rate * $1.hours }
            let baselineRate = depletion / coverage
            let peakRate = Self.peakRatePercentile(historical.map(\.rate))
            let windowLabel = Self.windowLabel(windowId: key.window)

            // Both comparisons, then **one** anomaly per window.
            //
            // Owner report 2026-10-09: two alerts arrived back to back for the
            // same event — "8.0x your 5hr average" and "8.6x your 7d average".
            // They were not a coincidence and not two windows either: one
            // window was producing two anomalies, because the baseline check and
            // the peak check were both satisfied and each appended its own.
            // Nothing collapsed them, so the same burst was announced twice in
            // slightly different words.
            //
            // A single number per event is the answer. The stronger comparison
            // wins, because it is the one the owner's own thresholds were set
            // to trigger on, and the summary is phrased against the larger
            // window rather than whichever fired first. `kind` still records how
            // many times the rate cleared each bar, which is what the settings
            // screen needs to explain itself.
            var baselineRatio: Double?
            if baselineRate > 0 {
                let ratio = currentRate / baselineRate
                if ratio.isFinite, ratio >= baselineMultiplier { baselineRatio = ratio }
            }
            var peakRatio: Double?
            if let peak = peakRate {
                let ratio = currentRate / peak
                if ratio.isFinite, ratio >= peakMultiplier { peakRatio = ratio }
            }
            guard baselineRatio != nil || peakRatio != nil else { continue }

            // Whichever ratio is larger is the one worth saying out loud.  Preferring
            // peak merely because it fired would relabel a mild overrun of the
            // average as a record-beating event, since the peak bar is normally
            // crossed first when both are met.
            let exceededPeak = (peakRatio ?? 0) > (baselineRatio ?? 0)
            let headline = max(baselineRatio ?? 0, peakRatio ?? 0)
            let comparisonRate = exceededPeak ? peakRate : baselineRate
            out.append(Anomaly(
                providerKey: key.provider,
                windowId: key.window,
                kind: exceededPeak ? .vsPeak : .vsBaseline,
                multiplier: headline,
                summary: Self.summary(kind: exceededPeak ? .vsPeak : .vsBaseline,
                                      ratio: headline,
                                      window: windowLabel,
                                      comparison: exceededPeak
                                        ? "your measured peak"
                                        : "your average over available history"),
                ratePercentPerHour: currentRate, comparisonRatePercentPerHour: comparisonRate,
                observedAt: observedAt, historyCoverageHours: coverage,
                baselineRatio: baselineRatio, peakRatio: peakRatio))
        }
        return out
    }

    /// Detect plan/quota-size changes across the sample history.  A step is a
    /// drop of at least `planChangeStepPoints` inside `planChangeMaxGap` that
    /// is not a window reset.  An interior step counts once a later sample
    /// shows it settled.  The trailing step of a segment has no later sample
    /// there, so it counts only after `planChangeUnconfirmedQuiet`.  Returns
    /// the latest change per provider+window; callers filter with
    /// `isActive(now:)` for the 7-day recalibration window.
    public static func detectPlanChanges(samples: [Sample], now: Date = Date()) -> [PlanChange] {
        var latest: [PairKey: PlanChange] = [:]
        for segment in Self.historySegments(samples: samples, now: now) {
            guard let first = segment.first, segment.count >= 2 else { continue }
            let key = PairKey(provider: first.providerKey, window: first.windowId)
            let pts = segment.sorted { $0.observedAt < $1.observedAt }
            // Interior intervals have a follow-up sample that can prove the
            // level held.  The trailing interval has none, so it qualifies
            // only once it has aged out of the live-burn hour.
            var candidates: [(Sample, Sample, Sample?)] = []
            if pts.count >= 3 {
                for index in 0..<(pts.count - 2) {
                    candidates.append((pts[index], pts[index + 1], pts[index + 2]))
                }
            }
            let last = pts[pts.count - 1]
            if last.observedAt.timeIntervalSince(now) <= -planChangeUnconfirmedQuiet {
                candidates.append((pts[pts.count - 2], last, nil))
            }
            for (prev, curr, next) in candidates {
                guard Self.isSettledPlanStep(prev: prev, curr: curr, next: next) else { continue }
                let change = PlanChange(providerKey: key.provider,
                                        windowId: key.window,
                                        changedAt: curr.observedAt)
                if let existing = latest[key], let existingAt = existing.changedAt,
                   (change.changedAt ?? .distantPast) <= existingAt {
                    continue
                }
                latest[key] = change
            }
        }
        return latest.values.sorted {
            ($0.changedAt ?? .distantPast) < ($1.changedAt ?? .distantPast)
        }
    }

    /// A resize teleports, then sits.  The follow-up sample has to fall
    /// inside the step window and spend at less than half the step's rate.
    /// Another large step means the burn is still running, which is a runaway
    /// signal rather than a new plan.  A nil follow-up is the aged trailing
    /// step: the caller has already required `planChangeUnconfirmedQuiet`.
    private static func isSettledPlanStep(prev: Sample, curr: Sample, next: Sample?) -> Bool {
        guard let prevPct = prev.remainingPercent,
              let currPct = curr.remainingPercent else { return false }
        let gap = curr.observedAt.timeIntervalSince(prev.observedAt)
        guard gap > 0, gap <= planChangeMaxGap else { return false }
        let drop = prevPct - currPct
        guard drop >= planChangeStepPoints else { return false }
        guard let next else { return true }
        guard let nextPct = next.remainingPercent else { return false }
        let laterGap = next.observedAt.timeIntervalSince(curr.observedAt)
        guard laterGap > 0, laterGap <= planChangeMaxGap else { return false }
        let laterDrop = currPct - nextPct
        guard laterDrop < planChangeStepPoints else { return false }
        let stepRate = drop / (gap / 3600)
        let laterRate = laterDrop / (laterGap / 3600)
        return laterRate < stepRate * 0.5
    }

    private struct PairKey: Hashable {
        let provider: String
        let window: String
    }

    private struct SampleKey: Hashable {
        let pair: PairKey
        let time: Date

        init(pair: PairKey, time: Date) {
            self.pair = pair
            // JSONEncoder's ISO-8601 strategy stores whole seconds.  Match
            // that precision so a persisted refresh deduplicates on reload.
            self.time = Date(timeIntervalSince1970: floor(time.timeIntervalSince1970))
        }
    }

    /// Valid, chronological series for graphing and rate calculations.  A
    /// reset, account change, allowance recovery, or long gap starts a new
    /// segment.  A sliding reset estimate may move on every refresh, so only
    /// crossing the previously advertised reset time creates a reset split.
    /// No synthetic points are inserted.
    public static func historySegments(samples: [Sample], now: Date = Date(),
                                       maxGap: TimeInterval = 30 * 60) -> [[Sample]] {
        guard maxGap.isFinite, maxGap > 0 else { return [] }
        var unique: [SampleKey: Sample] = [:]
        for sample in samples {
            guard sample.observedAt.timeIntervalSinceReferenceDate.isFinite,
                  sample.observedAt <= now,
                  let percent = sample.remainingPercent,
                  percent.isFinite, (0...100).contains(percent),
                  !sample.providerKey.isEmpty, !sample.windowId.isEmpty else { continue }
            let key = SampleKey(pair: PairKey(provider: sample.providerKey, window: sample.windowId),
                                time: sample.observedAt)
            unique[key] = sample
        }
        let grouped = Dictionary(grouping: unique.values) {
            PairKey(provider: $0.providerKey, window: $0.windowId)
        }
        var segments: [[Sample]] = []
        for group in grouped.values {
            let sorted = group.sorted { $0.observedAt < $1.observedAt }
            var current: [Sample] = []
            for sample in sorted {
                if let previous = current.last,
                   sample.observedAt.timeIntervalSince(previous.observedAt) > maxGap
                    || sample.remainingPercent! > previous.remainingPercent!
                    || sample.accountKey != previous.accountKey
                    || (previous.resetAt.map { $0 > previous.observedAt && $0 <= sample.observedAt } ?? false)
                    || sample.periodStart != previous.periodStart {
                    segments.append(current)
                    current = []
                }
                current.append(sample)
            }
            if !current.isEmpty { segments.append(current) }
        }
        return segments.sorted { $0[0].observedAt < $1[0].observedAt }
    }

    private struct HistoricalPair {
        let rate: Double
        let hours: Double
    }

    /// The high percentile of measured hourly rates, used instead of the
    /// single fastest sample.
    ///
    /// Owner analysis 2026-10-09, over 3,656 real hourly intervals from this
    /// Mac's own history: comparing against the maximum meant the peak check
    /// could not fire in **99.3%** of measured hours at the default 1.5x,
    /// because the maximum is an outlier by definition — the median
    /// current-rate/peak ratio was 0.05 and the p99 only 1.30.  A control that
    /// almost never does anything is worse than no control, because it still
    /// looks like a setting.
    ///
    /// The 99th percentile is the right reference for "unusually fast": rare
    /// without being unreachable, so a multiplier above 1.0 carries meaning.
    /// Against this, 1.5x alerts on hours that beat nearly every hour you have
    /// ever measured, rather than the single worst one.
    static func peakRatePercentile(_ rates: [Double]) -> Double? {
        let positive = rates.filter { $0 > 0 }.sorted()
        guard !positive.isEmpty else { return nil }
        // Too few samples for a percentile to mean anything; the maximum is
        // then the honest choice rather than a fabricated rank.
        guard positive.count >= 20 else { return positive.last }
        let rank = Int((Double(positive.count) * 0.99).rounded(.up)) - 1
        return positive[min(max(rank, 0), positive.count - 1)]
    }

    private static func historicalPairs(_ samples: [Sample], now: Date) -> [HistoricalPair] {
        let start = now.addingTimeInterval(-7 * 24 * 3600)
        let end = now.addingTimeInterval(-3600)
        guard samples.count >= 2 else { return [] }
        return (1..<samples.count).compactMap { index in
            let a = samples[index - 1], b = samples[index]
            let hours = b.observedAt.timeIntervalSince(a.observedAt) / 3600
            guard a.observedAt >= start, b.observedAt < end,
                  hours > 0, hours <= 1 else { return nil }
            return HistoricalPair(rate: max(0, (a.remainingPercent! - b.remainingPercent!) / hours),
                                  hours: hours)
        }
    }

    /// Append-only JSONL store for sample history.  Lives in the same directory
    /// as `quota-windows.json` so the two are co-managed.
    public struct SampleHistory: Sendable {
        public let url: URL

        public init(url: URL) {
            self.url = url
        }

        /// Append `samples` to the history file, one JSON object per line.
        /// Creates the parent directory if missing.  Caps the file size by
        /// trimming to the last `maxBytes` after the append so the file does
        /// not grow without bound.
        public func append(_ samples: [Sample], maxBytes: Int = 4 * 1024 * 1024) throws {
            guard !samples.isEmpty else { return }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                   withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.withoutEscapingSlashes]
            let fm = FileManager.default
            // Dedup against a tail read only: decoding the whole file here ran
            // a multi-megabyte parse on the main thread on every recorded
            // refresh.  Duplicates can only come from re-appending a recent
            // batch (identical observedAt timestamps), so the tail is
            // sufficient; load() dedups by key on read anyway, making a missed
            // older duplicate harmless.
            var seen = tailSampleKeys(maxBytes: 64 * 1024)
            let fresh = samples.filter { sample in
                guard sample.observedAt.timeIntervalSinceReferenceDate.isFinite,
                      let percent = sample.remainingPercent,
                      percent.isFinite, (0...100).contains(percent) else { return false }
                return seen.insert(SampleKey(pair: PairKey(provider: sample.providerKey,
                                                           window: sample.windowId),
                                             time: sample.observedAt)).inserted
            }
            guard !fresh.isEmpty else { return }
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url)
            try autoreleasepool {
                try handle.seekToEnd()
                for sample in fresh {
                    var line = try encoder.encode(sample)
                    line.append(0x0A) // \n
                    try handle.write(contentsOf: line)
                }
            }
            try handle.close()
            // Trim if over the cap — keep the second half, which is the
            // most recent data and the only part that matters for the
            // rolling baseline.
            if let attrs = try? fm.attributesOfItem(atPath: url.path),
               let size = attrs[.size] as? Int, size > maxBytes {
                let head = try Data(contentsOf: url, options: .mappedIfSafe)
                let trimTo = maxBytes * 3 / 4
                if head.count > trimTo {
                    let trimmed = head.suffix(trimTo)
                    try trimmed.write(to: url, options: .atomic)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                }
            }
        }

        /// SampleKeys decoded from the last `maxBytes` of the history file, for
        /// append-time dedup without a full parse.  The first line of the
        /// slice may be cut mid-line and is skipped.
        private func tailSampleKeys(maxBytes: Int) -> Set<SampleKey> {
            guard let full = try? Data(contentsOf: url, options: .mappedIfSafe), !full.isEmpty else { return [] }
            let sliced = full.count > maxBytes
            let tail: Data = sliced ? full.suffix(maxBytes) : full
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var seen = Set<SampleKey>()
            var lines = tail.split(separator: 0x0A, omittingEmptySubsequences: true)
            if sliced { lines = Array(lines.dropFirst()) }
            for line in lines {
                if let sample = try? decoder.decode(Sample.self, from: Data(line)) {
                    seen.insert(SampleKey(pair: PairKey(provider: sample.providerKey,
                                                       window: sample.windowId),
                                          time: sample.observedAt))
                }
            }
            return seen
        }

        /// Load every sample currently on disk.
        public func load() throws -> [Sample] {            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var out: [Sample] = []
            var start = data.startIndex
            while start < data.endIndex {
                let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
                let line = data[start..<end]
                start = (end < data.endIndex) ? data.index(after: end) : end
                if line.isEmpty { continue }
                if let sample = try? decoder.decode(Sample.self, from: line) {
                    out.append(sample)
                }
            }
            var unique: [SampleKey: Sample] = [:]
            for sample in out {
                unique[SampleKey(pair: PairKey(provider: sample.providerKey,
                                               window: sample.windowId),
                                 time: sample.observedAt)] = sample
            }
            return unique.values.sorted { $0.observedAt < $1.observedAt }
        }
    }

    // MARK: - Rate math

    /// Rate over the most recent hour, in percent-per-hour.  Computed as
    /// a least-squares slope on the last hour of samples with non-nil
    /// remainingPercent.  Returns nil if fewer than two usable samples
    /// fall in the window or the slope is non-positive (i.e. quota is
    /// recovering, not depleting).
    static func currentHourRatePercent(samples: [Sample], now: Date) -> Double? {
        let cutoff = now.addingTimeInterval(-3600)
        let recent = samples.filter { $0.observedAt >= cutoff && $0.remainingPercent != nil }
        guard recent.count >= 2,
              recent.last!.observedAt.timeIntervalSince(recent.first!.observedAt) >= 300 else { return nil }
        return ratePerHour(samples: recent)
    }

    /// Slope of `remainingPercent` vs `observedAt`, in percent-per-hour.
    /// Uses least-squares so an irregular sample schedule does not bias
    /// the result.  Returns nil if the samples are too clustered or the
    /// slope is non-positive.
    static func ratePerHour(samples: [Sample]) -> Double? {
        let usable = samples.filter { $0.remainingPercent != nil }
        guard usable.count >= 2 else { return nil }
        let t0 = usable.first!.observedAt.timeIntervalSinceReferenceDate
        var sumX: Double = 0
        var sumY: Double = 0
        var sumXX: Double = 0
        var sumXY: Double = 0
        var n: Double = 0
        for s in usable {
            let x = (s.observedAt.timeIntervalSinceReferenceDate - t0) / 3600
            let y = s.remainingPercent!
            sumX += x
            sumY += y
            sumXX += x * x
            sumXY += x * y
            n += 1
        }
        let denom = n * sumXX - sumX * sumX
        guard denom != 0 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denom
        // slope is "% per hour".  A negative slope means the bucket is
        // depleting; positive means the bucket is recovering.  The
        // detector only cares about depletion, so non-positive slopes
        // return nil.
        return slope < 0 ? -slope : nil
    }

    static func summary(kind: Anomaly.Kind, ratio: Double, window: String, comparison: String) -> String {
        let prefix: String
        switch kind {
        case .vsBaseline: prefix = "Spending fast vs"
        case .vsPeak: prefix = "Spending faster than"
        }
        return "\(prefix) \(window): \(String(format: "%.1f", ratio))× \(comparison)."
    }

    public static func windowLabel(windowId: String) -> String {
        if let range = windowId.range(of: ":", options: .backwards) {
            return String(windowId[range.upperBound...])
        }
        return windowId
    }
}
