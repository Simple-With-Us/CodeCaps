import Foundation
import QuotaCore

/// One atomic personal checkpoint keeps acknowledged baselines and uncertain deltas together.
struct MuseCodeBridgeCheckpoint: Codable {
    struct Pending: Codable {
        let events: [MuseCodePlannedEvent]
        let updated: [String: MuseCodeSessionObservation]
    }
    var version = 1
    var receiver = MuseCodeSessionIngest.endpoint.absoluteString
    var producer = MuseCodeSessionIngest.producerId
    var observations: [String: MuseCodeSessionObservation] = [:]
    var pending: Pending?

    var hasExpectedScope: Bool {
        version == 1 && receiver == MuseCodeSessionIngest.endpoint.absoluteString
            && producer == MuseCodeSessionIngest.producerId
            && observations.count <= MuseCodeDeltaPlanner.maxTrackedSessions
            && (pending?.updated.count ?? 0) <= MuseCodeDeltaPlanner.maxTrackedSessions
            && (pending?.events.count ?? 0) <= MuseCodeDeltaPlanner.maxTrackedSessions
            && observations.values.allSatisfy { $0.totalTokens >= 0 }
            && (pending?.updated.values.allSatisfy { $0.totalTokens >= 0 } ?? true)
            && (pending?.events.allSatisfy { $0.delta > 0 && $0.observation.totalTokens >= 0 } ?? true)
    }

    enum Failure: Error { case invalid, persistence }
}
