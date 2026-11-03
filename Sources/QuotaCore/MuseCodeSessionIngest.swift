import Foundation

/// The Muse bridge to Usage Monitor, built against the verified
/// session-event contract (Usage Monitor PR #1862): POST the v2 envelope to
/// `/api/ingest/usage` with the `muse-code` scoped producer token, one token
/// event per session observation.
///
/// Delta discipline is the contract's core: a session's latest snapshot
/// total is cumulative for its current segment, so the bridge posts only the
/// positive delta since its previous observation — never the cumulative
/// total, which the server would sum into a double count.  When a session's
/// segment resets (or its model changes), the new segment's total is the
/// delta.  Event ids are stable per (session, snapshot, model), so a replay
/// after a failed post dedupes server-side instead of double-counting.
public enum MuseCodeSessionIngest {
    public static let producerId = "muse-code"
    public static let provider = "muse-code"
    public static let service = "muse-code"
    public static let source = "muse-session-stores"
    public static let maxEventsPerBatch = 100
    public static let endpoint = URL(string: "https://usage.jays.services/api/ingest/usage")!

    public static func eventId(sessionId: String, snapshotId: String, modelId: String) -> String {
        "codecaps-muse-code:\(sessionId):\(snapshotId):\(modelId)"
    }

    public static func event(observation: MuseCodeSessionObservation, delta: Int) -> [String: Any] {
        let metadata: [String: Any] = [
            "sessionId": observation.sessionId,
            "contributor": observation.isContributor,
            "source": source
        ]
        let event: [String: Any] = [
            "eventId": eventId(sessionId: observation.sessionId,
                               snapshotId: observation.snapshotId,
                               modelId: observation.modelId),
            "provider": provider,
            "service": service,
            "producerKeyRef": observation.modelId,
            "metricType": "usage",
            "unit": "token",
            "quantity": delta,
            "billingMode": "estimated",
            "confidence": "estimated",
            "occurredAt": ISO8601DateFormatter().string(from: observation.observedAt),
            "metadata": metadata
        ]
        return event
    }

    public static func eventBatches(events: [[String: Any]]) -> [[[String: Any]]] {
        stride(from: 0, to: events.count, by: maxEventsPerBatch).map { offset in
            Array(events[offset..<min(offset + maxEventsPerBatch, events.count)])
        }
    }

    public static func batchData(events: [[String: Any]]) throws -> Data {
        let root: [String: Any] = [
            "schemaVersion": 2,
            "producerId": producerId,
            "events": events
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }
}

/// One positive delta the bridge owes the server, with the observation it
/// came from.
public struct MuseCodePlannedEvent: Codable, Equatable, Sendable {
    public let observation: MuseCodeSessionObservation
    public let delta: Int

    public init(observation: MuseCodeSessionObservation, delta: Int) {
        self.observation = observation
        self.delta = delta
    }
}

/// Pure delta planning, so the discipline is testable without a server: the
/// previous observation per session in, the events to post and the baselines
/// to keep out.  The caller persists `updated` only after every batch is
/// acknowledged, so a failed post retries the same deltas next refresh.
public enum MuseCodeDeltaPlanner {
    public static let maxTrackedSessions = 1_024

    public static func plan(observations: [MuseCodeSessionObservation],
                            previous: [String: MuseCodeSessionObservation])
        -> (events: [MuseCodePlannedEvent], updated: [String: MuseCodeSessionObservation]) {
        var updated = previous
        var events: [MuseCodePlannedEvent] = []
        for observation in observations {
            guard observation.totalTokens >= 0 else { continue }
            let prior = updated[observation.sessionId]
            // A rotated or delayed snapshot must never rewind an acknowledged baseline.
            if let prior, observation.observedAt < prior.observedAt { continue }
            let delta: Int
            if let prior, prior.segmentKey == observation.segmentKey,
               prior.modelId == observation.modelId {
                guard observation.totalTokens >= prior.totalTokens else { continue }
                delta = observation.totalTokens - prior.totalTokens
            } else {
                // First observation of the session, a segment reset, or a
                // model switch: the current segment's total is the delta.
                delta = observation.totalTokens
            }
            if delta > 0 {
                events.append(MuseCodePlannedEvent(observation: observation, delta: delta))
            }
            updated[observation.sessionId] = observation
        }
        if updated.count > maxTrackedSessions {
            updated = Dictionary(uniqueKeysWithValues: updated.values
                .sorted { $0.observedAt > $1.observedAt }
                .prefix(maxTrackedSessions)
                .map { ($0.sessionId, $0) })
        }
        return (events, updated)
    }
}

/// Usage Monitor's ingest acknowledgment.  A batch counts as delivered only
/// when the acknowledgment is complete: every counter present and
/// non-negative, `received` equal to the number sent, and the dispositions
/// adding up to `received`.
public struct MuseCodeIngestAcknowledgment: Decodable, Equatable, Sendable {
    public let received: Int
    public let persisted: Int
    public let duplicates: Int
    public let pruned: Int
    public let rejected: Int

    public func isComplete(sent: Int) -> Bool {
        let counts = [received, persisted, duplicates, pruned, rejected]
        guard counts.allSatisfy({ $0 >= 0 }), received == sent else { return false }
        // Subtract from the bounded sent count, so hostile counts cannot
        // overflow while checking the complete disposition of the batch.
        var unaccounted = received
        for count in [persisted, duplicates, pruned, rejected] {
            guard count <= unaccounted else { return false }
            unaccounted -= count
        }
        return unaccounted == 0
    }
}

public struct MuseCodeIngestSummary: Equatable, Sendable {
    public var sent: Int
    public var persisted: Int
    public var duplicates: Int
    public var pruned: Int
    public var rejected: Int

    public init(sent: Int = 0, persisted: Int = 0, duplicates: Int = 0,
                pruned: Int = 0, rejected: Int = 0) {
        self.sent = sent
        self.persisted = persisted
        self.duplicates = duplicates
        self.pruned = pruned
        self.rejected = rejected
    }
}

/// Posts Muse token events to Usage Monitor's `/api/ingest/usage`, in
/// batches of at most 100 events, with the v2 telemetry headers.
public struct MuseCodeSessionPoster: Sendable {
    private let transport: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public init(transport: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil) {
        self.transport = transport ?? { request in
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw QuotaPublisherError.transport("Invalid response.")
            }
            return (data, http)
        }
    }

    public func publish(events: [[String: Any]], to endpoint: URL, token: String?,
                        shouldContinue: @Sendable () async -> Bool = { true }) async throws -> MuseCodeIngestSummary {
        var summary = MuseCodeIngestSummary()
        for batch in MuseCodeSessionIngest.eventBatches(events: events) {
            guard await shouldContinue() else { throw CancellationError() }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            request.setValue("2", forHTTPHeaderField: "x-usage-telemetry-version")
            if let token = token.map(sanitizedToken(_:)), !token.isEmpty {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            request.httpBody = try MuseCodeSessionIngest.batchData(events: batch)
            let (data, http) = try await transport(request)
            guard (200..<300).contains(http.statusCode) else {
                throw QuotaPublisherError.httpStatus(http.statusCode, nil)
            }
            guard let acknowledgment = try? JSONDecoder().decode(MuseCodeIngestAcknowledgment.self, from: data),
                  acknowledgment.isComplete(sent: batch.count) else {
                throw QuotaPublisherError.serverError(
                    "Usage Monitor returned an incomplete ingest acknowledgment.")
            }
            summary.sent += batch.count
            summary.persisted += acknowledgment.persisted
            summary.duplicates += acknowledgment.duplicates
            summary.pruned += acknowledgment.pruned
            summary.rejected += acknowledgment.rejected
        }
        return summary
    }
}
