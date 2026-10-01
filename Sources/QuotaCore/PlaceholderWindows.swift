import Foundation

public extension QuotaWindow {
    /// A window a reader emits to say "this source is present but returned no
    /// reading": it has no percentage and names no cadence of its own.  Grok
    /// Bot's two readers (Cursor's DashboardService and the `gbu` CLI), Cursor's
    /// and the additive readers all emit one when their source cannot be read,
    /// so the provider's row can still say so.
    ///
    /// A window that carries an absolute figure (credits remaining, a limit) is
    /// a reading even with no percentage, so it is never a placeholder.
    var isPlaceholder: Bool {
        guard boundedRemainingPercent == nil, absoluteRemaining == nil, absoluteLimit == nil else { return false }
        return (window ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public extension Array where Element == QuotaWindow {
    /// The providers that have at least one real reading, and so need no
    /// placeholder.
    private var readingProviders: Set<String> {
        Set(filter { $0.boundedRemainingPercent != nil }.map(\.canonicalProviderKey))
    }

    /// Drops every placeholder whose provider already has a real reading.
    ///
    /// Several readers can speak for one provider.  Grok Bot has two: Cursor's
    /// DashboardService and the `gbu` CLI, both reporting "Grok Bot weekly".
    /// When one reads and the other falls back to its placeholder, the
    /// placeholder says nothing the reading does not, and it used to be drawn
    /// as a second, empty "7d" bar on the Grok Bot row.  A provider with no
    /// reading at all keeps its placeholders, so the row still says it is
    /// present and unreadable.
    ///
    /// A window that names a cadence is never a placeholder: Claude's 7d with
    /// no reading is a real statement that the weekly window is unknown.
    func droppingSupersededPlaceholders() -> [QuotaWindow] {
        let reading = readingProviders
        guard !reading.isEmpty else { return self }
        return filter { !($0.isPlaceholder && reading.contains($0.canonicalProviderKey)) }
    }
}

public extension LocalQuotaResult {
    /// The result with every superseded placeholder removed, and with it the
    /// provider's issue: a reader's "no readable quota" sentence goes with its
    /// placeholder, and left behind it would turn the whole row into
    /// "unavailable" over a perfectly good reading from the other reader.
    func droppingSupersededPlaceholders() -> LocalQuotaResult {
        let kept = windows.droppingSupersededPlaceholders()
        guard kept.count != windows.count else { return self }
        let reading = Set(kept.filter { $0.boundedRemainingPercent != nil }.map(\.canonicalProviderKey))
        var remaining = issues
        for window in windows where window.isPlaceholder && reading.contains(window.canonicalProviderKey) {
            remaining[window.canonicalProviderKey] = nil
        }
        return LocalQuotaResult(windows: kept, issues: remaining, consentNeeded: consentNeeded)
    }
}
