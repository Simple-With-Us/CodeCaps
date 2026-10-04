import Foundation

// MARK: - Inputs and outputs

/// One reading of one quota window, as the reset alarm sees it.
///
/// The tracker is deliberately ignorant of rows, views and providers' own
/// shapes: the app turns whatever it shows into these, and the tracker decides
/// from them alone whether a window has reset and whether that reset is worth
/// an alarm.  That keeps the rules pure, and keeps them testable without a
/// notification centre, a clock or a refresh loop.
public struct ResetAlarmObservation: Equatable, Sendable {
    /// Where the reading came from: `local` for this Mac, `fleet:<origin>` for
    /// one machine's pulled readings.  Two scopes never share window state, so
    /// another machine's account cannot fake a reset on this one.
    public var scope: String
    /// The alarm's owner: a provider key such as `anthropic`, or a pool-scoped
    /// key such as `google-antigravity:gemini`.  Per-provider choices are keyed
    /// by this, and the largest-window rule is applied within it.
    public var providerId: String
    /// The owner-facing name used in the notification: "Claude", "Antigravity · Gemini".
    public var providerTitle: String
    /// Stable identity of the window within its provider.
    public var windowId: String
    /// The short cadence label the owner already reads in Glance: "5h", "7d", "1m".
    public var windowLabel: String
    /// How long one period of the window lasts, when the reader says.  Decides
    /// which window is the provider's largest.
    public var periodSeconds: TimeInterval?
    /// When the current period ends.
    public var resetAt: Date?
    /// Percentage remaining, or `nil` when the reading is unknown or must not
    /// be believed (an Antigravity five-hour window under a spent weekly cap).
    public var remainingPercent: Double?
    /// When the reading was taken.  Readings older than one already processed
    /// are ignored, so a late fleet report cannot rewind a window.
    public var observedAt: Date?
    /// Whose quota the window is, when one window id is shared by several
    /// accounts in turn: Grok Bot's `gbu` reuses one id for whichever account is
    /// active.  When the identity of a window changes, its state starts over
    /// without firing, because another account's reset time and percentage are
    /// not a reset of this one.  `nil` for every window with a fixed owner.
    public var identity: String?

    public init(
        scope: String,
        providerId: String,
        providerTitle: String,
        windowId: String,
        windowLabel: String,
        periodSeconds: TimeInterval?,
        resetAt: Date?,
        remainingPercent: Double?,
        observedAt: Date?,
        identity: String? = nil
    ) {
        self.scope = scope
        self.providerId = providerId
        self.providerTitle = providerTitle
        self.windowId = windowId
        self.windowLabel = windowLabel
        self.periodSeconds = periodSeconds
        self.resetAt = resetAt
        self.remainingPercent = remainingPercent
        self.observedAt = observedAt
        self.identity = identity
    }
}

/// One alarm the tracker decided should fire.
public struct ResetAlarmEvent: Equatable, Sendable {
    public enum Reason: Equatable, Sendable {
        /// The provider's largest window reset: a new week or month began.
        case newPeriod
        /// A smaller window reset after getting within the near-cap threshold
        /// of its cap during the period that just ended.  Carries the lowest
        /// percentage remaining that was observed in that period.
        case nearCap(minimumRemaining: Double)
    }

    public var scope: String
    public var providerId: String
    public var providerTitle: String
    public var windowId: String
    public var windowLabel: String
    public var periodSeconds: TimeInterval?
    /// When the period that just ended was due to end.
    public var endedPeriodResetAt: Date?
    /// The reading that revealed the reset.
    public var remainingPercent: Double?
    public var reason: Reason
    public var isVendorReset: Bool

    public init(
        scope: String,
        providerId: String,
        providerTitle: String,
        windowId: String,
        windowLabel: String,
        periodSeconds: TimeInterval?,
        endedPeriodResetAt: Date?,
        remainingPercent: Double?,
        reason: Reason,
        isVendorReset: Bool = false
    ) {
        self.scope = scope
        self.providerId = providerId
        self.providerTitle = providerTitle
        self.windowId = windowId
        self.windowLabel = windowLabel
        self.periodSeconds = periodSeconds
        self.endedPeriodResetAt = endedPeriodResetAt
        self.remainingPercent = remainingPercent
        self.reason = reason
        self.isVendorReset = isVendorReset
    }
}

// MARK: - Persisted state

/// Everything the tracker remembers between readings.  Codable so the app can
/// persist it after every evaluation: a restart or a Sparkle relaunch picks up
/// the period each window was in, so a reset that lands while the app is down
/// still fires once on the next reading, and a reset already announced never
/// fires again.
public struct ResetAlarmTrackerState: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        /// When the current period ends, as last reported.
        public var periodResetAt: Date?
        /// The lowest percentage remaining observed in the current period.
        public var minimumRemaining: Double?
        /// The latest known percentage remaining.
        public var lastRemaining: Double?
        /// When the latest processed reading was taken.
        public var lastObservedAt: Date?
        /// When the tracker last saw this window at all, for pruning.
        public var lastSeenAt: Date
        public var periodSeconds: TimeInterval?
        /// Whose quota the window last described, for windows that change hands.
        public var identity: String?

        public init(
            periodResetAt: Date?,
            minimumRemaining: Double?,
            lastRemaining: Double?,
            lastObservedAt: Date?,
            lastSeenAt: Date,
            periodSeconds: TimeInterval?,
            identity: String? = nil
        ) {
            self.periodResetAt = periodResetAt
            self.minimumRemaining = minimumRemaining
            self.lastRemaining = lastRemaining
            self.lastObservedAt = lastObservedAt
            self.lastSeenAt = lastSeenAt
            self.periodSeconds = periodSeconds
            self.identity = identity
        }
    }

    /// A fired alarm, remembered so the same reset reported by two scopes —
    /// this Mac and the fleet copy of this Mac's own account — rings once.
    public struct Fire: Codable, Equatable, Sendable {
        public var key: String
        public var periodResetAt: Date?
        public var firedAt: Date

        public init(key: String, periodResetAt: Date?, firedAt: Date) {
            self.key = key
            self.periodResetAt = periodResetAt
            self.firedAt = firedAt
        }
    }

    public var version: Int
    /// Keyed by `scope|providerId|windowId`.
    public var windows: [String: Window]
    public var recentFires: [Fire]

    public init(version: Int = 1, windows: [String: Window] = [:], recentFires: [Fire] = []) {
        self.version = version
        self.windows = windows
        self.recentFires = recentFires
    }

    /// Encodes for `UserDefaults`.  Never throws to the caller: a state that
    /// cannot be encoded is simply not saved, which costs at most one alarm.
    public func encoded() -> Data? {
        try? JSONEncoder().encode(self)
    }

    /// Decodes a saved state, or returns an empty one for missing or corrupt
    /// data.  An empty state is safe: no window fires on its first reading.
    public static func decoded(from data: Data?) -> ResetAlarmTrackerState {
        guard let data, let state = try? JSONDecoder().decode(ResetAlarmTrackerState.self, from: data) else {
            return ResetAlarmTrackerState()
        }
        return state
    }
}

// MARK: - Policy

/// The numbers the rules use, in one place.
public enum ResetAlarmPolicy {
    /// A smaller window alarms on reset only if, during the period that just
    /// ended, it came at least this close to its cap.  0 means it hit the cap.
    public static let nearCapThreshold: Double = 20
    /// How far a reported reset time may wander between readings of the same
    /// period.  Readers that compute a reset as "now plus the seconds left"
    /// jitter by a few seconds; nothing real moves a period by this much.
    public static let resetDriftTolerance: TimeInterval = 15 * 60
    /// Before its old reset time has passed, a window only counts as reset when
    /// its reset time jumps by at least this share of a period.  A rolling
    /// window whose reset creeps forward while the Mac sleeps is not a reset.
    public static let earlyResetShareOfPeriod: Double = 0.5
    /// The jump required before the old reset time when the period is unknown.
    public static let earlyResetUnknownPeriod: TimeInterval = 2 * 3_600
    /// A provider that resets a limit early can move its reset time by less
    /// than half a period.  The reset is still certain when the percentage
    /// remaining also climbed by at least this many points: a fixed-period
    /// window cannot regain quota inside one period.
    public static let earlyResetRiseMargin: Double = 10
    /// A reading stamped further ahead than this is treated as unstamped.  A
    /// fleet producer with a wrong clock, or this Mac stepping its own clock
    /// back, would otherwise freeze a window until the clock caught up.
    public static let maximumFutureSkew: TimeInterval = 5 * 60
    /// "Remaining rose" means by more than this, so rounding is not a reset.
    public static let riseEpsilon: Double = 1
    /// A mid-cycle rise of at least this many points, with the period end left
    /// where it was, is the provider handing quota back.
    ///
    /// The level the quota lands at says nothing: on 2026-10-04 Cursor's
    /// included plan came back at 89% and Grok Bot's week at 92%, and a rule
    /// that only fired at 95% or above missed both.  A fixed-period window
    /// cannot regain quota inside its own period, so the size of the rise is
    /// the evidence and 30 points is far beyond rounding or a stale reading.
    public static let vendorRestoreRise: Double = 30
    /// Windows and fires not seen for this long are forgotten.
    public static let retention: TimeInterval = 45 * 86_400
    /// A window's period counts toward "largest" for this long after it was
    /// last seen, so one refresh that misses the weekly window cannot promote
    /// the five-hour window to largest.
    public static let largestMemory: TimeInterval = 8 * 86_400
}

// MARK: - Tracker

/// The reset alarm's state machine.
///
/// For every provider and window it tracks the current period (by its reset
/// time) and the lowest percentage remaining observed in it.  When a reading
/// shows the window has moved to a later period it decides:
///
/// 1. The provider's largest window (longest period) fires on every reset,
///    even if it was never near its cap: a new week or month began.
/// 2. Any smaller window fires only if, in the period that just ended, it hit
///    its cap or came within `nearCapThreshold` of it.
///
/// Nothing else suppresses an alarm.  In particular a smaller window still
/// fires while a larger one reads 0%: a provider's larger windows include
/// model-only caps (Claude's Sonnet and Opus weeklies, one MiniMax weekly per
/// model) that say nothing about whether the provider is usable.
///
/// A window's very first reading never fires, readings with no reset time or
/// no percentage are tolerated, and each reset fires at most once.
public struct ResetAlarmTracker: Sendable {
    public private(set) var state: ResetAlarmTrackerState

    public init(state: ResetAlarmTrackerState = ResetAlarmTrackerState()) {
        self.state = state
    }

    public static func windowKey(scope: String, providerId: String, windowId: String) -> String {
        "\(scope)|\(providerId)|\(windowId)"
    }

    /// Processes one refresh worth of readings and returns the alarms to fire.
    public mutating func process(_ observations: [ResetAlarmObservation], now: Date) -> [ResetAlarmEvent] {
        var events: [ResetAlarmEvent] = []
        let groups = Dictionary(grouping: observations) { "\($0.scope)|\($0.providerId)" }
        for groupKey in groups.keys.sorted() {
            guard let group = groups[groupKey] else { continue }
            events += processGroup(group, groupKey: groupKey, now: now)
        }
        prune(now: now)
        return events
    }

    // MARK: One provider in one scope

    private struct Transition {
        let observation: ResetAlarmObservation
        let previous: ResetAlarmTrackerState.Window
        let isMidWindow: Bool
    }

    private mutating func processGroup(
        _ group: [ResetAlarmObservation],
        groupKey: String,
        now: Date
    ) -> [ResetAlarmEvent] {
        var transitions: [Transition] = []
        // Duplicate readings of one window in one batch: keep the latest.
        var seen: [String: ResetAlarmObservation] = [:]
        for observation in group {
            if let existing = seen[observation.windowId],
               (existing.observedAt ?? .distantPast) > (observation.observedAt ?? .distantPast) {
                continue
            }
            seen[observation.windowId] = observation
        }
        for windowId in seen.keys.sorted() {
            guard let observation = seen[windowId] else { continue }
            if let transition = advance(observation, now: now) {
                transitions.append(transition)
            }
        }
        guard !transitions.isEmpty else { return [] }

        let largestPeriod = self.largestPeriod(groupKey: groupKey, batch: Array(seen.values), now: now)
        var events: [ResetAlarmEvent] = []
        for transition in transitions {
            let observation = transition.observation
            let isLargest = Self.isLargest(observation.periodSeconds, largestPeriod: largestPeriod)
            let reason: ResetAlarmEvent.Reason
            if isLargest {
                reason = .newPeriod
            } else if let minimum = transition.previous.minimumRemaining,
                      minimum <= ResetAlarmPolicy.nearCapThreshold {
                reason = .nearCap(minimumRemaining: minimum)
            } else if transition.isMidWindow {
                reason = .nearCap(minimumRemaining: transition.previous.minimumRemaining ?? (transition.previous.lastRemaining ?? 80.0))
            } else {
                continue
            }

            let fireKey = transition.isMidWindow
                ? "\(observation.providerId)|\(observation.windowLabel)|midwindow"
                : "\(observation.providerId)|\(observation.windowLabel)"
            let ended = transition.isMidWindow ? (observation.observedAt ?? now) : transition.previous.periodResetAt
            if alreadyFired(key: fireKey, periodResetAt: ended) { continue }
            state.recentFires.append(.init(key: fireKey, periodResetAt: ended, firedAt: now))
            events.append(ResetAlarmEvent(
                scope: observation.scope,
                providerId: observation.providerId,
                providerTitle: observation.providerTitle,
                windowId: observation.windowId,
                windowLabel: observation.windowLabel,
                periodSeconds: observation.periodSeconds ?? transition.previous.periodSeconds,
                endedPeriodResetAt: ended,
                remainingPercent: observation.remainingPercent,
                reason: reason,
                isVendorReset: transition.isMidWindow))
        }
        // Largest first, so a combined notification leads with the new week.
        return events.sorted { lhs, rhs in
            if (lhs.reason == .newPeriod) != (rhs.reason == .newPeriod) { return lhs.reason == .newPeriod }
            return (lhs.periodSeconds ?? 0) > (rhs.periodSeconds ?? 0)
        }
    }

    /// Folds one reading into its window's state, returning the previous state
    /// when the reading reveals a new period.
    private mutating func advance(_ observation: ResetAlarmObservation, now: Date) -> Transition? {
        let key = Self.windowKey(scope: observation.scope,
                                 providerId: observation.providerId,
                                 windowId: observation.windowId)
        let reading = observation.remainingPercent.flatMap { $0.isFinite ? min(max($0, 0), 100) : nil }
        // A stamp from the future is a clock error, not a newer reading: taking
        // it at face value would make every honest reading after it look old.
        let observedAt = observation.observedAt.flatMap {
            $0 <= now.addingTimeInterval(ResetAlarmPolicy.maximumFutureSkew) ? $0 : nil
        }

        func firstReading() -> ResetAlarmTrackerState.Window {
            .init(periodResetAt: observation.resetAt,
                  minimumRemaining: reading,
                  lastRemaining: reading,
                  lastObservedAt: observedAt,
                  lastSeenAt: now,
                  periodSeconds: observation.periodSeconds,
                  identity: observation.identity)
        }

        guard var window = state.windows[key] else {
            // First reading ever: remember it, never fire.
            state.windows[key] = firstReading()
            return nil
        }
        // The window now describes someone else's quota (Grok Bot's active
        // account changed): start over, because that account's reset time and
        // percentage are not a reset of this one.
        if let identity = observation.identity, let known = window.identity, identity != known {
            state.windows[key] = firstReading()
            return nil
        }
        if window.identity == nil { window.identity = observation.identity }
        window.lastSeenAt = now
        if let period = observation.periodSeconds { window.periodSeconds = period }

        // A reading older than one already processed cannot say anything new.
        if let observed = observedAt, let last = window.lastObservedAt, observed < last {
            state.windows[key] = window
            return nil
        }

        let readAt = observedAt ?? now
        var isReset = false
        var isMidWindow = false
        var nextResetAt = window.periodResetAt

        if let previousReset = window.periodResetAt {
            let hasPassed = readAt >= previousReset.addingTimeInterval(-60)
            if let reported = observation.resetAt {
                let jump = reported.timeIntervalSince(previousReset)
                let required = hasPassed
                    ? ResetAlarmPolicy.resetDriftTolerance
                    : max(ResetAlarmPolicy.resetDriftTolerance,
                          window.periodSeconds.map { $0 * ResetAlarmPolicy.earlyResetShareOfPeriod }
                              ?? ResetAlarmPolicy.earlyResetUnknownPeriod)
                // A provider that resets early may move the reset time by less
                // than `required`; the percentage jumping back up settles it.
                var climbed = false
                if let reading, let last = window.lastRemaining {
                    climbed = reading >= last + ResetAlarmPolicy.earlyResetRiseMargin
                }
                if jump > required || (jump > ResetAlarmPolicy.resetDriftTolerance && climbed) {
                    isReset = true
                    nextResetAt = reported
                } else if jump > -ResetAlarmPolicy.resetDriftTolerance || reported > readAt {
                    // Jitter, or a correction to a reset still ahead: follow it
                    // so slow drift never adds up to a false reset.
                    nextResetAt = reported
                }
            }
            // The old period is over and the percentage went back up, even
            // though the reader has not published the next reset time yet.
            if !isReset, hasPassed, let reading, let last = window.lastRemaining,
               reading > last + ResetAlarmPolicy.riseEpsilon {
                isReset = true
                nextResetAt = observation.resetAt.flatMap { $0 > readAt ? $0 : nil }
            }
            // Mid-window reset: a quota that jumps back up while the period
            // is still running.  Three ways to see it, and none of them
            // requires the quota to land at 100%:
            //  - the quota is handed back, which shows as a large rise against
            //    a period end that did not move.
            //  - the quota jumps to full from anything less.
            //  - the quota was nearly spent and is now nearly untouched.
            if !isReset, !hasPassed, let reading, let last = window.lastRemaining {
                let jumpedToFull = reading >= 99.5 && last < 99.5
                let surgedMidWindow = last < 80.0 && reading >= 95.0
                // "Held still" and "slid with the clock" are two separate
                // questions, and asking them as two separate questions keeps
                // the verdict independent of how often this Mac happens to
                // refresh.
                //
                // A reader that reports "resets in N seconds" recomputes it
                // from the current time, so a rolling window's end advances in
                // step with the clock — by roughly the gap since the last
                // reading, at a 5-minute cadence or a 30-second one alike.
                // A vendor restore leaves the end on the same instant.  The
                // test is therefore a ratio, not an absolute bound: scaling
                // the bound by the poll gap instead would make the same
                // restore fire at a slow cadence and vanish at a fast one,
                // which is a property of when the owner happened to press
                // refresh rather than anything the provider said.
                let endMoved = observation.resetAt.map { abs($0.timeIntervalSince(previousReset)) }
                // A reading that omits its period end says nothing about it.
                // Unknown must not be read as "held still".
                let periodEndHeld = endMoved.map {
                    $0 <= ResetAlarmPolicy.resetDriftTolerance
                } ?? false
                // A reader that reports "resets in N seconds" recomputes it
                // from the current time, so a rolling window's end advances in
                // step with the clock — by roughly the gap since the last
                // reading, at a 5-minute cadence or a 30-second one alike.
                // A vendor restore leaves the end on the same instant.  The
                // test is a ratio rather than an absolute bound: scaling a
                // bound by the poll gap would make the same restore fire at a
                // slow cadence and vanish at a fast one, which is a property
                // of when the owner pressed refresh rather than of anything
                // the provider said.
                let slidWithTheClock: Bool
                if observedAt != nil, let lastObserved = window.lastObservedAt {
                    let gap = max(0, readAt.timeIntervalSince(lastObserved))
                    slidWithTheClock = gap > 0 && (endMoved ?? 0) * 2 >= gap
                } else {
                    // No trustworthy gap.  Either the reading carries no stamp,
                    // the previous one did not, or this stamp was rejected as
                    // too far in the future to be a real clock — and then
                    // `readAt` falls back to `now`, so the gap can collapse to
                    // zero and report "definitely did not slide" when the truth
                    // is "cannot tell".  In every one of those cases any
                    // movement at all disqualifies the reading.  The iOS
                    // companion sends `observedAt: nil` on every observation,
                    // which makes the unstamped case its ordinary path rather
                    // than an edge case: without it a rolling reader there
                    // could slide up to the whole drift tolerance per poll and
                    // still read as held still.
                    slidWithTheClock = (endMoved ?? 0) > 0
                }
                let quotaHandedBack = periodEndHeld && !slidWithTheClock
                    && reading >= last + ResetAlarmPolicy.vendorRestoreRise
                if jumpedToFull || surgedMidWindow || quotaHandedBack {
                    isReset = true
                    isMidWindow = true
                    nextResetAt = observation.resetAt.flatMap { $0 > readAt ? $0 : nil } ?? window.periodResetAt
                }
            }
        } else if let reported = observation.resetAt, reported > readAt {
            // No period end known — a reset was just detected without the next
            // one being published.  Adopt the first reset time still ahead; a
            // stale one would read as a second reset of the same period.
            nextResetAt = reported
        }

        let previous = window
        if isReset {
            window.periodResetAt = nextResetAt
            window.minimumRemaining = reading
            window.lastRemaining = reading
        } else {
            window.periodResetAt = nextResetAt
            if let reading {
                window.minimumRemaining = min(window.minimumRemaining ?? reading, reading)
                window.lastRemaining = reading
            }
        }
        // Assigned unconditionally, so it always means "the stamp carried by the
        // previous reading" and is nil when that reading was unstamped.  Only
        // ever writing it on a stamped reading would leave a stale anchor
        // behind for as long as the provider went without one, which would
        // measure the gap below in spans longer than a single interval.
        window.lastObservedAt = observedAt
        state.windows[key] = window
        return isReset ? Transition(observation: observation, previous: previous, isMidWindow: isMidWindow) : nil
    }

    // MARK: Largest window

    /// The longest known period among this provider's windows in this scope:
    /// the ones in this batch, plus any seen recently, so a refresh that
    /// happens to miss the weekly window does not promote the five-hour one.
    private func largestPeriod(groupKey: String, batch: [ResetAlarmObservation], now: Date) -> TimeInterval? {
        var periods = batch.compactMap(\.periodSeconds)
        let prefix = groupKey + "|"
        for (key, window) in state.windows where key.hasPrefix(prefix) {
            guard now.timeIntervalSince(window.lastSeenAt) <= ResetAlarmPolicy.largestMemory,
                  let period = window.periodSeconds else { continue }
            periods.append(period)
        }
        return periods.max()
    }

    /// A window with a known period is the largest when nothing longer is
    /// known.  A window whose period is unknown is the largest only when no
    /// window of the provider has a known period — a lone plan meter.
    static func isLargest(_ period: TimeInterval?, largestPeriod: TimeInterval?) -> Bool {
        guard let largestPeriod else { return true }
        guard let period else { return false }
        return period >= largestPeriod - 1
    }

    // MARK: Bookkeeping

    private func alreadyFired(key: String, periodResetAt: Date?) -> Bool {
        state.recentFires.contains { fire in
            guard fire.key == key else { return false }
            switch (fire.periodResetAt, periodResetAt) {
            case let (a?, b?):
                return abs(a.timeIntervalSince(b)) <= ResetAlarmPolicy.resetDriftTolerance
            default:
                return false
            }
        }
    }

    private mutating func prune(now: Date) {
        state.windows = state.windows.filter {
            now.timeIntervalSince($0.value.lastSeenAt) <= ResetAlarmPolicy.retention
        }
        state.recentFires.removeAll { now.timeIntervalSince($0.firedAt) > ResetAlarmPolicy.retention }
    }
}
