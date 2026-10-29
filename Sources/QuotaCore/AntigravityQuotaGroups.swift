import Foundation

/// Antigravity has two shared model pools, each with a short and weekly cap.
/// Per-model reports are observations of those pools, never additive quotas.
public enum AntigravityQuotaGroups {
    public static func normalize(_ windows: [QuotaWindow], includeMissing: Bool = false) -> [QuotaWindow] {
        let other = windows.filter { $0.canonicalProviderKey != "google-antigravity" }
        let reports = windows.filter { $0.canonicalProviderKey == "google-antigravity" }
        guard !reports.isEmpty else { return windows }
        var result = other
        for family in ["gemini", "third-party"] {
            for period in ["5h", "weekly"] {
                let candidates = reports.filter { !$0.isSubModelLimit && pool($0) == family && cadence($0) == period }
                // Prefer the latest observation.  Tied model observations of the same
                // shared pool use the lower value; never average or add percentages.
                let selected = candidates.sorted {
                    let left = $0.occurredDate ?? .distantPast
                    let right = $1.occurredDate ?? .distantPast
                    if left != right { return left > right }
                    return ($0.boundedRemainingPercent ?? 101) < ($1.boundedRemainingPercent ?? 101)
                }.first
                guard selected != nil || includeMissing else { continue }
                let title = family == "gemini" ? "Gemini Models" : "Third-Party Models"
                var value = selected ?? QuotaWindow(id: "", provider: "Antigravity", label: "", remainingUnknown: true, occurredAt: "")
                value.id = "antigravity:\(family):\(period)"
                value.provider = "Antigravity"
                value.providerKey = "google-antigravity"
                value.providerLabel = "Antigravity"
                value.via = "antigravity"
                value.modelId = nil
                // No single model id survives the pooling, but the pool itself
                // is the family a consumer can route on, so publish it.
                value.modelType = family
                value.label = "\(title) · \(period == "5h" ? QuotaWindowVocabulary.fiveHour : QuotaWindowVocabulary.sevenDay)"
                value.window = period
                // Model-specific units cannot establish a shared absolute cap.
                value.absoluteRemaining = nil
                value.absoluteLimit = nil
                value.quotaUnit = nil
                // The grouped summary builds its windows without a status, so
                // a pool at zero would otherwise publish "unknown" and a
                // consumer would route to it.  Restate the derived fields.
                result.append(value.normalizedForExport())
            }
        }
        let subModels = reports.filter { $0.isSubModelLimit }
        for subModel in subModels {
            result.append(subModel.normalizedForExport())
        }
        return result
    }

    // MARK: - Pools

    /// One Antigravity model pool, summarised across its own windows.
    ///
    /// Antigravity sells two independent pools, and collapsing them into a
    /// single percentage is what made an exhausted Claude/GPT weekly read as
    /// "Antigravity 0%" while Gemini still had most of its allowance.  Every
    /// surface that shows one number per platform asks this type for its number
    /// instead of taking the minimum across the provider.
    public struct Pool: Equatable, Sendable {
        /// `gemini` or `third-party`.  Matches the exported window id segment.
        public let key: String
        /// The pool's own windows, five-hour first.
        public let windows: [QuotaWindow]
        /// The lowest remaining percentage among the windows that still count.
        public let remainingPercent: Double?
        /// True when this pool's weekly window reports zero remaining.
        public let weeklyExhausted: Bool
        /// The window `remainingPercent` was taken from.
        public let drivingWindowId: String?
        /// That window's reset, so a row's countdown matches its percentage.
        public let resetAt: Date?
        /// Windows that report a percentage which must not be believed — a
        /// five-hour window under an exhausted weekly cap.
        public let maskedWindowIds: Set<String>

        public init(
            key: String,
            windows: [QuotaWindow],
            remainingPercent: Double?,
            weeklyExhausted: Bool,
            drivingWindowId: String?,
            resetAt: Date?,
            maskedWindowIds: Set<String>
        ) {
            self.key = key
            self.windows = windows
            self.remainingPercent = remainingPercent
            self.weeklyExhausted = weeklyExhausted
            self.drivingWindowId = drivingWindowId
            self.resetAt = resetAt
            self.maskedWindowIds = maskedWindowIds
        }
    }

    /// The pool keys, in display order.
    public static let poolKeys = ["gemini", "third-party"]

    /// Whether a pool's weekly cap is spent.  A weekly that reports a number
    /// is spent at or below the rounding threshold; one that reports no number
    /// falls back to the provider's own word for it.
    ///
    /// The threshold is `QuotaCapRule.spentThreshold` rather than a second
    /// constant kept here:  the pool used to carry its own copy, and once the
    /// weekly decision moved to the shared rule nothing read that copy, so it
    /// survived only as dead code kept alive by a test -- which is how a live
    /// copy of the same question could drift elsewhere without failing
    /// anything.  The number itself, and the reason it is half a point, live
    /// in `QuotaCapRule`:  the provider reports a fractional remaining and the
    /// interface rounds 0.4% to 0%, so an exact-zero test let a cap through
    /// and the five-hour window under it was then believed when its percentage
    /// must not be (owner 2026-10-19, "Antigravity is saying vendor reset 5h
    /// quota early while the 7d is still at cap and unchanged").
    private static func weeklyIsSpent(_ window: QuotaWindow) -> Bool {
        QuotaCapRule.isExhausted(remainingPercent: window.boundedRemainingPercent,
                                 providerSaysExhausted: window.isExhausted)
    }

    /// Splits Antigravity windows into their two pools.  Windows that belong to
    /// no recognisable pool are dropped rather than guessed at, and a pool with
    /// no windows at all is omitted.
    public static func pools(from windows: [QuotaWindow], now: Date = Date()) -> [Pool] {
        let reports = windows.filter { $0.canonicalProviderKey == "google-antigravity" }
        var result: [Pool] = []
        for key in poolKeys {
            let owned = reports.filter { poolKey(for: $0) == key }
            guard !owned.isEmpty else { continue }
            let ordered = owned.sorted { left, right in
                let leftSub = left.isSubModelLimit
                let rightSub = right.isSubModelLimit
                if leftSub != rightSub { return !leftSub }
                let leftWeekly = cadence(left) == "weekly"
                let rightWeekly = cadence(right) == "weekly"
                if leftWeekly != rightWeekly { return !leftWeekly }
                return left.id < right.id
            }
            // Only a fresh window may spend the pool.  A copy of a period that
            // ended carries no live information, so it must not claim the
            // allowance is gone, and the shared cap rule beside it is
            // percentage-level, so it cannot tell the two apart.  The phone
            // and the widget already ask the shared freshness rule here;  the
            // Mac did not, so one pool read live on one surface and spent on
            // another.
            let spentWeekly = ordered.first {
                !$0.isSubModelLimit && cadence($0) == "weekly" && weeklyIsSpent($0)
                    && QuotaWindowSnapshot(window: $0, now: now).isFresh
            }
            let weeklyExhausted = spentWeekly != nil
            let masked: Set<String> = weeklyExhausted
                ? Set(ordered.filter { !$0.isSubModelLimit && cadence($0) == "5h" }.map(\.id))
                : []
            // A stale observation is still shown, but it never sets the pool's
            // headline number while a fresh one exists.  Sub-models do not drive
            // the pool headline.
            let counted = ordered.filter {
                !$0.isSubModelLimit
                    && !masked.contains($0.id)
                    && $0.boundedRemainingPercent != nil
                    && QuotaWindowSnapshot(window: $0, now: now).isFresh
            }
            let driving = counted.min {
                ($0.boundedRemainingPercent ?? 100) < ($1.boundedRemainingPercent ?? 100)
            }
            // A pool whose weekly cap is spent is at its cap even when the
            // provider reports no number for that weekly — it says the
            // allowance is gone in words and leaves the figure out.  The
            // weekly then drives the pool at zero, so the row names the cap
            // that binds instead of offering a number the owner cannot act
            // on, and its reset is the one worth counting down to.
            let headline = driving ?? spentWeekly
            result.append(Pool(key: key,
                               windows: ordered,
                               remainingPercent: QuotaCapRule.publishedReading(
                                   remainingPercent: headline?.boundedRemainingPercent,
                                   allowanceSpent: weeklyExhausted),
                               weeklyExhausted: weeklyExhausted,
                               drivingWindowId: headline?.id,
                               resetAt: headline?.resetDate,
                               maskedWindowIds: masked))
        }
        return result
    }

    /// Whether this window represents a sub-model limit rather than a primary pool window.
    public static func isSubModel(_ value: QuotaWindow) -> Bool {
        value.isSubModelLimit
    }

    /// The ids of windows whose percentage must not be shown or counted: a
    /// five-hour window is meaningless while its pool's weekly cap is spent.
    public static func maskedWindowIds(in windows: [QuotaWindow], now: Date = Date()) -> Set<String> {
        pools(from: windows, now: now).reduce(into: Set<String>()) { $0.formUnion($1.maskedWindowIds) }
    }

    /// Which pool a window belongs to, or nil when it names neither.
    public static func poolKey(for value: QuotaWindow) -> String? {
        pool(value)
    }

    /// Whether a window reports a five-hour or a weekly cadence.
    public static func cadenceKey(for value: QuotaWindow) -> String? {
        cadence(value)
    }

    private static func pool(_ value: QuotaWindow) -> String? {
        let identity = [value.modelId, value.modelType, value.label].compactMap { $0 }.joined(separator: " ").lowercased()
        if identity.contains("gemini") || identity.contains("argon") { return "gemini" }
        if ["third-party", "third party", "third_party", "claude", "gpt", "openai", "anthropic"].contains(where: identity.contains) { return "third-party" }
        // A producer that leaves the pool out of the label and model fields
        // ("7-day window", no model) still names the pool in its bucket id:
        // `gemini-weekly`, `3p-5h`, `3p-weekly`.  Without this a pool's weekly
        // window belonged to no pool and was not drawn in any Antigravity row,
        // while the phone, which files every non-Gemini window under
        // Third-Party, drew it.  Only a window the fields above could not
        // place reaches this line.
        // The id is either the bare bucket, a `:`-joined path ending in it, or a
        // JSON array of strings kept whole inside the id string
        // (`["producer","instance","3p-weekly"]`), whose last element is it.
        let bucket: String
        if value.id.first == "[",
           let elements = try? JSONDecoder().decode([String].self, from: Data(value.id.utf8)),
           let last = elements.last {
            bucket = last.lowercased()
        } else {
            bucket = value.id.lowercased().split(separator: ":").last.map(String.init) ?? ""
        }
        if bucket.hasPrefix("gemini-") { return "gemini" }
        if bucket.hasPrefix("3p-") { return "third-party" }
        return nil
    }

    private static func cadence(_ value: QuotaWindow) -> String? {
        let token = value.window?.lowercased().replacingOccurrences(of: " ", with: "")
        if ["weekly", "week", "1w", "7d", "168h", "10080m"].contains(token ?? "") || value.label.lowercased().contains("weekly") { return "weekly" }
        if ["5h", "5hr", "5-hour", "5hours", "300m"].contains(token ?? "") { return "5h" }
        // The helper's model quotaInfo is the short pool.  A weekly reading
        // must be explicitly identified; a reset's distance is not a duration.
        if token == nil && value.sourceApp == "local-mac" && value.modelId != nil { return "5h" }
        return nil
    }
}
