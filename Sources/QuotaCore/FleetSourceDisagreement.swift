import Foundation

/// Shared rules for when two quota feeds disagree and how to pick a headline reading.
public struct FleetSourceReading: Equatable, Sendable {
    public let remainingPercent: Double?
    public let observedAt: Date?

    public init(remainingPercent: Double?, observedAt: Date?) {
        self.remainingPercent = remainingPercent
        self.observedAt = observedAt
    }
}

public enum FleetSourceDisagreement {
    /// Both feeds must report within this window to show a disagreement alert.
    public static let alertFreshnessWindow: TimeInterval = 30 * 60

    public static func isObservedWithinAlertWindow(_ observedAt: Date?, now: Date) -> Bool {
        guard let observedAt else { return false }
        return now.timeIntervalSince(observedAt) <= alertFreshnessWindow
    }

    public static func shouldShowDisagreementAlert(
        primary: FleetSourceReading,
        duplicate: FleetSourceReading,
        now: Date,
        minimumDelta: Double = 10
    ) -> Bool {
        guard let primaryPercent = primary.remainingPercent,
              let duplicatePercent = duplicate.remainingPercent else { return false }
        guard isObservedWithinAlertWindow(primary.observedAt, now: now),
              isObservedWithinAlertWindow(duplicate.observedAt, now: now) else { return false }
        return abs(primaryPercent - duplicatePercent) >= minimumDelta
    }

    public static func freshestReading(_ readings: [FleetSourceReading]) -> FleetSourceReading? {
        readings.max { left, right in
            (left.observedAt ?? .distantPast) < (right.observedAt ?? .distantPast)
        }
    }

    public static func isStaleAmongPeers(_ reading: FleetSourceReading, peers: [FleetSourceReading]) -> Bool {
        guard let freshest = freshestReading(peers), let freshAt = freshest.observedAt else {
            return reading.observedAt == nil
        }
        guard let observed = reading.observedAt else { return true }
        return observed < freshAt
    }
}
