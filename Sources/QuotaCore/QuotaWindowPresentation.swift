import Foundation

extension QuotaWindow {
    /// The model a sub-model quota belongs to, in the provider's own words.
    ///
    /// A per-model window such as Claude's Fable weekly limit carries a
    /// cadence-only label ("7-day"), so a surface that hides a label that only
    /// repeats its cadence caption hid the one thing telling the owner which
    /// model the row was (owner, 2026-10-30).  The name comes from the reading
    /// itself: a reader that writes "<model> · <cadence>" already names the
    /// model, and otherwise the model id or type the reader recorded is used.
    ///
    /// Nil for a primary window, and for OpenAI's scoped pools, whose labels
    /// already say what they are.
    public var subModelName: String? {
        guard isSubModelLimit, canonicalProviderKey != "openai" else { return nil }
        if let separator = label.range(of: " · ") {
            let name = label[..<separator.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { return name }
        }
        for candidate in [modelType, modelId] {
            let raw = (candidate ?? "")
                .replacingOccurrences(of: "_", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !raw.isEmpty { return Self.initialCapped(raw) }
        }
        return nil
    }

    /// Each word's first letter upper-cased and the rest left as the reader
    /// wrote it, so "fable" reads "Fable" while "GPT-4o" keeps its casing.
    private static func initialCapped(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: true)
            .map { String($0.prefix(1)).uppercased() + String($0.dropFirst()) }
            .joined(separator: " ")
    }
}

/// Ordering and collapsing rules for the quota rows a surface draws.
public enum QuotaWindowPresentation {
    /// The platform's own windows first, then its per-model windows.
    ///
    /// A per-model quota is a real limit but not the one the plan is sold on,
    /// so it reads after the platform's 5-hour and 7-day windows rather than
    /// between them (owner, 2026-10-30).  The order within each group is kept.
    public static func primaryFirst(_ windows: [QuotaWindowSnapshot]) -> [QuotaWindowSnapshot] {
        windows.filter { !$0.window.isSubModelLimit } + windows.filter { $0.window.isSubModelLimit }
    }

    /// At most `limit` meters, keeping the most constrained ones.
    ///
    /// When a row that has two meters only has room for one, the one it keeps
    /// is the window with the least remaining, because that is the limit the
    /// owner hits first (owner, 2026-10-30).  A meter with no percentage ranks
    /// last.  The kept meters stay in their original order.
    public static func collapsedMeters(_ meters: [QuotaWindowSnapshot], limit: Int) -> [QuotaWindowSnapshot] {
        guard limit > 0 else { return [] }
        guard meters.count > limit else { return meters }
        let kept = meters.enumerated()
            .sorted { lhs, rhs in
                let left = lhs.element.remainingPercent ?? .infinity
                let right = rhs.element.remainingPercent ?? .infinity
                return left == right ? lhs.offset < rhs.offset : left < right
            }
            .prefix(limit)
            .map(\.offset)
            .sorted()
        return kept.map { meters[$0] }
    }
}
