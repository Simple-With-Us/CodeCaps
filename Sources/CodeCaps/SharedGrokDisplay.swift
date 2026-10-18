import Foundation
import QuotaCore

/// One authoritative allowance with optional presentation identities.  Aliases
/// never become raw readings, so exports, history, counts and alerts stay singular.
enum SharedGrokDisplay {
    static let options: [(id: String, title: String)] = [
        ("xai", "xAI"), ("grok", "Grok"),
        ("cursor-grok", "Cursor-Grok"), ("grok-bot", "Grok Bot")
    ]
    static let ids = Set(options.map(\.id))

    static func quotaKey(for displayID: String) -> String {
        ids.contains(displayID) ? "grok" : displayID
    }

    /// Ignore retired independent lookups arriving from older clients.  Never
    /// substitute a stale Grok Bot/weekly Cursor reading when Grok is unavailable.
    /// Cursor's own billing-cycle subscription remains a separate provider.
    static func authoritativeWindows(_ windows: [QuotaWindow]) -> [QuotaWindow] {
        var result: [QuotaWindow] = []
        var sharedIndex: [String: Int] = [:]
        for original in windows {
            let key = original.canonicalProviderKey
            if key == "grok-bot" || key == "cursor-grok" { continue }
            if key == "cursor", original.window == "weekly",
               original.source == "Cursor" || original.id.hasPrefix("local-mac:cursor:") { continue }
            guard key == "grok" || key == "xai" else {
                result.append(original)
                continue
            }
            var window = original
            window.providerKey = "grok"
            window.providerLabel = "Grok"
            // Scope by producer and account before cadence.  Two machines or
            // accounts must never borrow each other's fresh percentage.
            let cadence = ResetAlarmCadence.periodSeconds(token: original.window, label: original.label)
                .map { String($0) } ?? original.window ?? original.label
            let identity = [FleetOrigin.identity(of: original), original.machine ?? "",
                            original.sourceApp ?? "", original.accountKey ?? "",
                            original.modelId ?? "", cadence]
                .joined(separator: "\u{1F}")
            if let index = sharedIndex[identity] {
                if (window.occurredDate ?? .distantPast) > (result[index].occurredDate ?? .distantPast) {
                    result[index] = window
                }
            } else {
                sharedIndex[identity] = result.count
                result.append(window)
            }
        }
        return result
    }

    static func rows(sections: [QuotaPlatformSection], now: Date) -> [DisplaySection] {
        let shared = sections.first { $0.providerKey == "grok" }
        var rows: [DisplaySection] = []
        var inserted = false
        for section in sections {
            if ids.contains(section.providerKey) {
                guard !inserted, let shared else { continue }
                inserted = true
                let base = DisplaySection.rows(for: shared, now: now)[0]
                rows += options.map { option in
                    DisplaySection(id: option.id, providerKey: "grok", title: option.title,
                                   platformTitle: option.title,
                                   section: QuotaPlatformSection(providerKey: "grok", providerLabel: option.title,
                                                                 via: shared.via, expected: shared.expected,
                                                                 windows: shared.windows, iconHint: option.id),
                                   poolKey: nil, remainingPercent: base.remainingPercent,
                                   resetAt: base.resetAt, maskedWindowIds: base.maskedWindowIds)
                }
            } else {
                rows += DisplaySection.rows(for: section, now: now)
            }
        }
        return rows
    }

    static func visible(_ rows: [DisplaySection], selected: Set<String>) -> [DisplaySection] {
        rows.filter { !ids.contains($0.id) || selected.contains($0.id) }
    }
}
