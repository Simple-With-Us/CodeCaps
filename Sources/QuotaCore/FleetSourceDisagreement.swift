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

/// Mac CodeCaps observations are authoritative on iOS when they are fresh.
public struct FleetQuotaObservation: Equatable, Sendable {
    public let remainingPercent: Double?
    public let reportedAt: Date?
    public let isMacCodeCapsReading: Bool

    public init(remainingPercent: Double?, reportedAt: Date?, isMacCodeCapsReading: Bool) {
        self.remainingPercent = remainingPercent
        self.reportedAt = reportedAt
        self.isMacCodeCapsReading = isMacCodeCapsReading
    }
}

public struct FleetCardDisplayPick: Equatable, Sendable {
    public let chosenIndex: Int
    /// Set when the card falls back to a non-authoritative Mac reading (stale or absent).
    public let updatedLabel: String?

    public init(chosenIndex: Int, updatedLabel: String?) {
        self.chosenIndex = chosenIndex
        self.updatedLabel = updatedLabel
    }
}

public enum FleetMacReading {
    private static let producerMarkers = ["codecaps", "agent-bar", "local-mac", "usage monitor"]

    public static func isMacCodeCapsReading(id: String, source: String?, via: String?) -> Bool {
        if id.lowercased().hasPrefix("local-mac:") { return true }
        for raw in [source, via] {
            let lower = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            if lower.isEmpty { continue }
            if producerMarkers.contains(lower) { return true }
            if lower.contains("codecaps") { return true }
        }
        return false
    }

    /// Prefer a Mac CodeCaps reading reported within `freshnessWindow`; otherwise the newest feed with an Updated label.
    public static func pickCardDisplay(
        from observations: [FleetQuotaObservation],
        now: Date,
        freshnessWindow: TimeInterval = FleetSourceDisagreement.alertFreshnessWindow
    ) -> FleetCardDisplayPick? {
        guard !observations.isEmpty else { return nil }

        func isFresh(_ reportedAt: Date?) -> Bool {
            guard let reportedAt else { return false }
            return now.timeIntervalSince(reportedAt) <= freshnessWindow
        }

        func freshestIndex(in indices: [Int]) -> Int? {
            indices.max { left, right in
                let l = observations[left].reportedAt ?? .distantPast
                let r = observations[right].reportedAt ?? .distantPast
                return l < r
            }
        }

        let freshMacIndices = observations.indices.filter {
            observations[$0].isMacCodeCapsReading && isFresh(observations[$0].reportedAt)
        }
        if let macIndex = freshestIndex(in: Array(freshMacIndices)) {
            return FleetCardDisplayPick(chosenIndex: macIndex, updatedLabel: nil)
        }

        guard let chosen = freshestIndex(in: Array(observations.indices)) else { return nil }
        let reportedAt = observations[chosen].reportedAt
        let label = reportedAt.map { date in
            "Updated " + Self.updatedTimeCaption(for: date)
        }
        return FleetCardDisplayPick(chosenIndex: chosen, updatedLabel: label)
    }

    public static func updatedTimeCaption(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }
}
