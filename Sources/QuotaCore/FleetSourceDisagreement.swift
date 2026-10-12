import Foundation

/// Shared rules for when two quota feeds disagree and how to pick a headline reading.
public struct FleetSourceReading: Equatable, Sendable {
    public let remainingPercent: Double?
    public let reportedAt: Date?

    public init(remainingPercent: Double?, reportedAt: Date?) {
        self.remainingPercent = remainingPercent
        self.reportedAt = reportedAt
    }
}

public enum FleetSourceDisagreement {
    /// Both feeds must report within this window to show a disagreement alert.
    public static let alertFreshnessWindow: TimeInterval = 20 * 60

    public static let minimumAlertDelta: Double = 10

    public static func isReportedWithinAlertWindow(_ reportedAt: Date?, now: Date) -> Bool {
        guard let reportedAt else { return false }
        return now.timeIntervalSince(reportedAt) <= alertFreshnessWindow
    }

    public static func shouldShowDisagreementAlert(
        primary: FleetSourceReading,
        duplicate: FleetSourceReading,
        now: Date,
        minimumDelta: Double = minimumAlertDelta
    ) -> Bool {
        guard let primaryPercent = primary.remainingPercent,
              let duplicatePercent = duplicate.remainingPercent else { return false }
        guard isReportedWithinAlertWindow(primary.reportedAt, now: now),
              isReportedWithinAlertWindow(duplicate.reportedAt, now: now) else { return false }
        return abs(primaryPercent - duplicatePercent) >= minimumDelta
    }

    public static func freshestReading(_ readings: [FleetSourceReading]) -> FleetSourceReading? {
        readings.max { left, right in
            (left.reportedAt ?? .distantPast) < (right.reportedAt ?? .distantPast)
        }
    }

    public static func isStaleAmongPeers(_ reading: FleetSourceReading, peers: [FleetSourceReading]) -> Bool {
        guard let freshest = freshestReading(peers), let freshAt = freshest.reportedAt else {
            return reading.reportedAt == nil
        }
        guard let reported = reading.reportedAt else { return true }
        return reported < freshAt
    }
}
