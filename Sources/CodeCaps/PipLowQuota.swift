import Foundation
import QuotaCore

/// Session state for low-quota PiP auto-open.  `rowsBelowThreshold` remembers
/// the last read so crossings are detected on the edge only.
struct PipLowQuotaSession: Equatable {
    var rowsBelowThreshold: Set<String> = []
    var autoAddedRowIds: Set<String> = []
    var autoOpenSuppressed: Bool = false
    var seeded: Bool = false
}

enum PipLowQuota {
    static let thresholdChoices = [5, 10, 15, 20, 25, 30]
    static let defaultThreshold = 15

    /// Whether any honest window on this row is at or below the threshold.
    static func rowIsLow(_ row: DisplaySection, thresholdPercent: Int) -> Bool {
        let limit = Double(thresholdPercent)
        return row.section.windows.contains { snapshot in
            guard !snapshot.window.isSupplementaryVideoQuota else { return false }
            guard !row.isMasked(snapshot) else { return false }
            guard let remaining = snapshot.remainingPercent else { return false }
            return remaining <= limit
        }
    }

    static func lowRowIds(in rows: [DisplaySection], thresholdPercent: Int) -> Set<String> {
        Set(rows.filter { rowIsLow($0, thresholdPercent: thresholdPercent) }.map(\.id))
    }

    /// Applies one refresh.  Returns whether PiP should be shown after this pass.
    static func evaluate(
        rows: [DisplaySection],
        thresholdPercent: Int,
        enabled: Bool,
        session: inout PipLowQuotaSession
    ) -> Bool {
        guard enabled else {
            session.seeded = false
            return false
        }

        let currentLow = lowRowIds(in: rows, thresholdPercent: thresholdPercent)
        if !session.seeded {
            session.rowsBelowThreshold = currentLow
            session.seeded = true
            return false
        }

        let previousLow = session.rowsBelowThreshold
        var shouldOpen = false

        for id in currentLow where !previousLow.contains(id) {
            session.autoAddedRowIds.insert(id)
            shouldOpen = true
        }
        if shouldOpen {
            session.autoOpenSuppressed = false
        }

        for id in previousLow where !currentLow.contains(id) {
            session.autoAddedRowIds.remove(id)
        }

        session.rowsBelowThreshold = currentLow
        return shouldOpen
    }

    static func noteUserClosedPip(session: inout PipLowQuotaSession) {
        session.autoOpenSuppressed = true
    }
}
