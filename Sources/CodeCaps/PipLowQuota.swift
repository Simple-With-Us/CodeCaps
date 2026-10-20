import Foundation
import QuotaCore

/// Session state for low-quota PiP auto-open.  `rowsBelowThreshold` remembers
/// the last read so crossings are detected on the edge only.
struct PipLowQuotaSession: Equatable {
    var rowsBelowThreshold: Set<String> = []
    var autoAddedRowIds: Set<String> = []
    var autoOpenSuppressed: Bool = false
    var seeded: Bool = false
    var lastObservedAtByRow: [String: Date] = [:]
}

enum PipLowQuota {
    static let thresholdChoices = [5, 10, 15, 20, 25, 30]
    static let defaultThreshold = 15

    /// Whether any honest window on this row is at or below the threshold.
    static func rowIsLow(_ row: DisplaySection, thresholdPercent: Int,
                         issues: [String: String] = [:], disabledSources: Set<String> = []) -> Bool {
        guard issues[row.providerKey] == nil else { return false }
        let limit = Double(thresholdPercent)
        return row.section.windows.contains { snapshot in
            guard !snapshot.window.isSupplementaryVideoQuota else { return false }
            guard !row.isMasked(snapshot) else { return false }
            guard snapshot.isFresh, !snapshot.window.remainingUnknown, !snapshot.window.skip,
                  !disabledSources.contains(snapshot.window.source ?? "") else { return false }
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
        issues: [String: String] = [:],
        disabledSources: Set<String> = [],
        session: inout PipLowQuotaSession
    ) -> Bool {
        guard enabled else {
            session.seeded = false
            session.lastObservedAtByRow = [:]
            return false
        }

        var shouldOpen = false
        for row in rows {
            guard issues[row.providerKey] == nil else { continue }
            let relevant = row.section.windows.filter {
                !$0.window.isSupplementaryVideoQuota && !row.isMasked($0)
            }
            let usable = relevant.filter {
                $0.isFresh && !$0.window.remainingUnknown && !$0.window.skip
                    && $0.remainingPercent != nil
                    && !disabledSources.contains($0.window.source ?? "")
            }
            let low = usable.filter { ($0.remainingPercent ?? 100) <= Double(thresholdPercent) }
            // Partial data can prove a low allowance, but cannot prove recovery.
            guard !usable.isEmpty, !low.isEmpty || usable.count == relevant.count else { continue }
            let observedAt = low.isEmpty ? usable.compactMap(\.observedAt).min() : low.compactMap(\.observedAt).max()
            guard let observedAt else { continue }
            let previousDate = session.lastObservedAtByRow[row.id]
            guard previousDate == nil || observedAt > previousDate! else { continue }
            session.lastObservedAtByRow[row.id] = observedAt
            if low.isEmpty {
                session.rowsBelowThreshold.remove(row.id)
                session.autoAddedRowIds.remove(row.id)
            } else {
                let crossed = !session.rowsBelowThreshold.contains(row.id)
                session.rowsBelowThreshold.insert(row.id)
                if previousDate != nil && crossed {
                    session.autoAddedRowIds.insert(row.id)
                    shouldOpen = true
                }
            }
        }
        if shouldOpen {
            session.autoOpenSuppressed = false
        }

        session.seeded = true
        return shouldOpen
    }

    static func noteUserClosedPip(session: inout PipLowQuotaSession) {
        session.autoOpenSuppressed = true
    }
}
