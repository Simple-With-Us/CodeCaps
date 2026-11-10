import Foundation

/// One muse-code session's current model, as one poll of the session store
/// observed it.  This is the detector's input, kept separate from the
/// reader's `MuseCodeSessionObservation` because a session whose current
/// segment carries no model id must be representable: `modelId` is nil for
/// such a session, and a nil model is never an event.
public struct MuseCodeSessionModelObservation: Equatable, Sendable {
    public let sessionId: String
    public let modelId: String?
    public let observedAt: Date

    public init(sessionId: String, modelId: String?, observedAt: Date) {
        self.sessionId = sessionId
        self.modelId = modelId
        self.observedAt = observedAt
    }

    /// Adapts the reader's latest observation for one session.  The reader
    /// only emits observations for snapshots that carry a model, so the
    /// adapted `modelId` is never nil today; the detector still tolerates
    /// nil for any future source that can produce one.
    public init(_ observation: MuseCodeSessionObservation) {
        self.init(sessionId: observation.sessionId,
                  modelId: observation.modelId,
                  observedAt: observation.observedAt)
    }
}

/// A standard-model session event: one firing of the
/// `museCodeStandardSession` alert kind.  The payload names the session,
/// the model it is on, and when it was observed — the three facts that say
/// which run of work left the contributor models.
public struct MuseCodeStandardSessionEvent: Equatable, Sendable {
    public let sessionId: String
    public let modelId: String
    public let observedAt: Date

    public init(sessionId: String, modelId: String, observedAt: Date) {
        self.sessionId = sessionId
        self.modelId = modelId
        self.observedAt = observedAt
    }

    public var title: String { "Muse Standard Model Session" }

    public var body: String {
        "Session \(sessionId) is running on the standard model \(modelId)."
            + sentenceGap
            + "Observed at \(Self.centralTimestamp(observedAt))."
    }

    private static func centralTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "America/Chicago")
        formatter.dateFormat = "MMM d, yyyy h:mm a"
        return formatter.string(from: date)
    }
}

/// Event-based detection of standard-model Muse sessions.
///
/// This replaces the contributor token share as the monitor's contributor
/// finding.  A share computed from rotating session snapshots moves for
/// reasons unrelated to the question — stale sessions inside the window,
/// token weight, last-segment attribution — and reads below 100% even when
/// every live session is on a contributor model.  Presence has no such
/// noise: a session either is on a standard model or it is not.
///
/// The detector is a small state machine over polls.  It remembers the last
/// model each session was observed on and fires exactly when a session
/// enters a standard model:
///
/// - a session observed for the first time, already on a standard model;
/// - a session whose model changed from a contributor model to a standard
///   model.
///
/// A session that stays on the same standard model across polls does not
/// refire.  A session that returns to a contributor model re-arms, so going
/// standard again is a new event.  Observations with no model id are
/// ignored entirely — they neither fire nor touch the tracked state — so a
/// model-less segment can neither manufacture an event nor mask a later
/// contributor-to-standard switch.
///
/// The state is `Codable` so the owner of the detector can persist it with
/// the same JSON-in-UserDefaults pattern the plugin already uses for the
/// Usage Monitor bridge baselines, and detection survives app relaunches.
public struct MuseCodeStandardSessionDetector: Codable, Equatable, Sendable {
    /// The last model each tracked session was observed on, by session id.
    /// Only model-bearing observations are recorded, so a session absent
    /// here has never been observed with a model.
    public private(set) var lastKnownModels: [String: String]

    /// When each tracked session was last observed, for staleness eviction.
    /// Blobs persisted before the cap existed carry no stamps; those sessions
    /// are kept and stamped on their next observation.
    public private(set) var lastObservedAt: [String: Date]

    /// A session not observed for this long is no longer live: the reader's
    /// window is ninety minutes, so a full day absent means it ended.
    public static let sessionStateTTL: TimeInterval = 24 * 3_600
    /// Backstop bound on tracked sessions; the least recently observed are
    /// evicted first.
    public static let maxTrackedSessions = 512

    public init(lastKnownModels: [String: String] = [:], lastObservedAt: [String: Date] = [:]) {
        self.lastKnownModels = lastKnownModels
        self.lastObservedAt = lastObservedAt
    }

    private enum CodingKeys: String, CodingKey { case lastKnownModels, lastObservedAt }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastKnownModels = try container.decode([String: String].self, forKey: .lastKnownModels)
        lastObservedAt = try container.decodeIfPresent([String: Date].self, forKey: .lastObservedAt) ?? [:]
    }

    /// A contributor model is a model id ending in `-contributor`.
    public static func isContributor(modelId: String) -> Bool {
        modelId.hasSuffix("-contributor")
    }

    /// A standard model is any non-empty model id that is not a contributor
    /// model.  A missing model id is not standard — it is no information.
    public static func isStandard(modelId: String?) -> Bool {
        guard let modelId, !modelId.isEmpty else { return false }
        return !isContributor(modelId: modelId)
    }

    /// Feeds one poll's session observations and returns the events that
    /// fire, in observation order.
    ///
    /// On the first poll after install the tracked state is empty, so every
    /// session in that first scan counts as first-observed and fires if it
    /// is on a standard model.  That is deliberate: a standard session that
    /// was already running when the monitor was installed is still a
    /// standard session, and suppressing it would hide exactly the finding
    /// the alert exists for.
    @discardableResult
    public mutating func observe(
        _ observations: [MuseCodeSessionModelObservation]
    ) -> [MuseCodeStandardSessionEvent] {
        evictExpiredSessions(relativeTo: observations.map(\.observedAt).max())
        var events: [MuseCodeStandardSessionEvent] = []
        for observation in observations {
            lastObservedAt[observation.sessionId] = observation.observedAt
            guard let modelId = observation.modelId, !modelId.isEmpty else { continue }
            let previous = lastKnownModels[observation.sessionId]
            let wasContributor = previous.map { Self.isContributor(modelId: $0) } ?? false
            if Self.isStandard(modelId: modelId), previous == nil || wasContributor {
                events.append(MuseCodeStandardSessionEvent(
                    sessionId: observation.sessionId, modelId: modelId,
                    observedAt: observation.observedAt))
            }
            lastKnownModels[observation.sessionId] = modelId
        }
        trimToCap()
        return events
    }

    /// Drops sessions whose last observation is older than the TTL.  Runs
    /// before the poll so an evicted session that returns fires once as
    /// first-observed, which a day-long absence warrants.  An empty poll
    /// falls back to the wall clock so idle periods still advance expiry.
    private mutating func evictExpiredSessions(relativeTo newest: Date?) {
        let cutoff = (newest ?? Date()).addingTimeInterval(-Self.sessionStateTTL)
        for (sessionId, observedAt) in lastObservedAt where observedAt < cutoff {
            lastKnownModels.removeValue(forKey: sessionId)
            lastObservedAt.removeValue(forKey: sessionId)
        }
    }

    /// Trims the state to the cap by evicting the least recently observed.
    /// Sessions without a liveness stamp predate the stamp field: any session
    /// still live after the first poll of this version has been stamped, so
    /// an unstamped entry is stale and sorts oldest, evicted first.
    private mutating func trimToCap() {
        guard lastKnownModels.count > Self.maxTrackedSessions else { return }
        let overflow = lastKnownModels.count - Self.maxTrackedSessions
        let oldest = lastKnownModels.keys.sorted {
            (lastObservedAt[$0] ?? .distantPast) < (lastObservedAt[$1] ?? .distantPast)
        }.prefix(overflow)
        for sessionId in oldest {
            lastKnownModels.removeValue(forKey: sessionId)
            lastObservedAt.removeValue(forKey: sessionId)
        }
    }

    /// The sessions in one poll whose current model is standard, as events
    /// with no firing semantics: the presence test the burn rule uses.  A
    /// standard session that has been running for an hour still counts here
    /// even though its start event fired long ago.
    public static func standardSessions(
        in observations: [MuseCodeSessionModelObservation]
    ) -> [MuseCodeStandardSessionEvent] {
        observations.compactMap { observation in
            guard let modelId = observation.modelId,
                  isStandard(modelId: modelId) else { return nil }
            return MuseCodeStandardSessionEvent(sessionId: observation.sessionId,
                                                 modelId: modelId,
                                                 observedAt: observation.observedAt)
        }
    }
}
