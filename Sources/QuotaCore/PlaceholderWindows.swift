import Foundation

public extension QuotaWindow {
    /// Whether the window says how much is left: a percentage, or an absolute
    /// figure (credits remaining, a limit) even with no percentage.
    var hasReading: Bool {
        boundedRemainingPercent != nil || absoluteRemaining != nil || absoluteLimit != nil
    }

    /// A window a reader emits to say "this source is present but returned no
    /// reading": it has no reading and names no cadence of its own.  Grok
    /// Bot's two readers (Cursor's DashboardService and the `gbu` CLI), Cursor's
    /// and the additive readers all emit one when their source cannot be read,
    /// so the provider's row can still say so.
    var isPlaceholder: Bool {
        guard !hasReading else { return false }
        return (window ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// What the window measures, for matching one reader's report of it against
    /// another's: the provider, the model and the label.  Two readers of one
    /// allowance agree on all three ("Grok Bot weekly" from DashboardService
    /// and from `gbu`); two models of one provider never do, even when both are
    /// weekly.
    var meterIdentity: String {
        func normalised(_ text: String?) -> String {
            (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        return [canonicalProviderKey, normalised(modelId), normalised(modelType), normalised(label)]
            .joined(separator: "|")
    }
}

public extension Array where Element == QuotaWindow {
    /// Splits the windows into those to keep and the providers that lost a
    /// placeholder.  See `droppingSupersededPlaceholders`.
    fileprivate func partitioningSupersededPlaceholders() -> (kept: [QuotaWindow], droppedFrom: Set<String>) {
        let reading = Set(filter(\.hasReading).map(\.meterIdentity))
        guard !reading.isEmpty else { return (self, []) }
        var kept: [QuotaWindow] = []
        var droppedFrom: Set<String> = []
        for window in self {
            if window.isPlaceholder && reading.contains(window.meterIdentity) {
                droppedFrom.insert(window.canonicalProviderKey)
            } else {
                kept.append(window)
            }
        }
        return (kept, droppedFrom)
    }

    /// Drops every placeholder that another window already reads.
    ///
    /// Several readers can speak for one meter.  Grok Bot has two: Cursor's
    /// DashboardService and the `gbu` CLI, both reporting "Grok Bot weekly".
    /// When one reads and the other falls back to its placeholder, the
    /// placeholder says nothing the reading does not, and it used to be drawn
    /// as a second, empty "7d" bar on the Grok Bot row.
    ///
    /// "The same meter" is the same provider, model and label
    /// (`QuotaWindow.meterIdentity`), not just the same provider: a model that
    /// returned no reading (one of MiniMax's, beside another that did read)
    /// stays visible as unknown.  A meter with no reading anywhere keeps its
    /// placeholder, so the row still says it is present and unreadable.
    ///
    /// A window that names a cadence is never a placeholder: Claude's 7d with
    /// no reading is a real statement that the weekly window is unknown.
    func droppingSupersededPlaceholders() -> [QuotaWindow] {
        partitioningSupersededPlaceholders().kept
    }
}

public extension LocalQuotaResult {
    /// The result with every superseded placeholder removed, and with it the
    /// provider's issue once none of its placeholders is left: a reader's "no
    /// readable quota" sentence goes with its placeholder, and left behind it
    /// would turn the whole row into "unavailable" over a perfectly good
    /// reading from the other reader.
    func droppingSupersededPlaceholders() -> LocalQuotaResult {
        let (kept, droppedFrom) = windows.partitioningSupersededPlaceholders()
        guard !droppedFrom.isEmpty else { return self }
        var remaining = issues
        for provider in droppedFrom where !kept.contains(where: { $0.canonicalProviderKey == provider && $0.isPlaceholder }) {
            remaining[provider] = nil
        }
        return LocalQuotaResult(windows: kept, issues: remaining, consentNeeded: consentNeeded)
    }
}
