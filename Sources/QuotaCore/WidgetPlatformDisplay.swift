import Foundation

/// Canonical platform names for widget and companion surfaces.
///
/// Widget rows must never show a raw provider id slug (e.g. lowercase `cursor`).
/// Keys stay lowercase for wiring; titles are always owner-facing labels.
public enum WidgetPlatformDisplay {
    private static let titlesByCanonicalKey: [String: String] = [
        // The Mac calls this provider Claude (QuotaProviders.expected), and the
        // phone called it Claude Code, so the two apps of one product showed
        // the same plan under two different names.  One name, taken from the
        // Mac, so the surfaces agree.
        "anthropic": "Claude",
        "openai": "Codex",
        "google-antigravity": "Antigravity",
        "cursor": "Cursor",
        "xai": "xAI",
        "grok": "Grok",
        "grok-bot": "Grok Bot",
        "minimax": "MiniMax",
        "muse-assist": "Muse Assist",
        "muse-code": "Muse Code",
        "kimi": "Kimi",
        "zcode": "ZCode",
        "github-copilot": "GitHub Copilot",
        "windsurf": "Windsurf",
        "gemini-cli": "Gemini CLI",
    ]

    /// Resolves the human-readable platform title for a canonical provider key.
    public static func title(
        canonicalKey: String,
        manifestProviderLabel: String? = nil,
        wireProvider: String? = nil
    ) -> String {
        let key = canonicalKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let known = titlesByCanonicalKey[key] { return known }

        if let manifest = manifestProviderLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !manifest.isEmpty {
            let manifestKey = manifest.lowercased()
            if let known = titlesByCanonicalKey[manifestKey] { return known }
            if manifest != manifestKey || manifest.contains(" ") {
                return manifest
            }
        }

        if let wire = wireProvider?.trimmingCharacters(in: .whitespacesAndNewlines), !wire.isEmpty {
            if let known = titlesByCanonicalKey[wire.lowercased()] { return known }
            // Preserve mixed-case / spaced wire names; only fall through for
            // raw lowercase slugs that match the canonical key.
            if wire != wire.lowercased() || wire.contains(" ") {
                return wire
            }
        }

        if let known = titlesByCanonicalKey[key] { return known }
        return key
    }

    /// Whether `title` is just the lowercase provider id, not a display name.
    public static func isRawProviderSlug(_ title: String, canonicalKey: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let key = canonicalKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == key && trimmed == trimmed.lowercased()
    }

    /// Resolves the human-readable platform subtitle, mirroring the Mac app's
    /// `displaySubtitle` and `planCostRenewalDetail`.
    ///
    /// Order of precedence:
    /// 1. Pool subtitle (e.g. "Gemini", "Third-Party" for Antigravity)
    /// 2. Custom subtitle if set by the user (`userSubtitle`)
    /// 3. Plan / Cost / Renewal string if `showCostAndRenewal` is enabled
    /// 4. User-entered plan name (`userPlanName`)
    /// 5. Detected/automatic plan name (`detectedPlanName` or `automaticPlanName`)
    /// 6. Provider-specific fallback (e.g. "free" for Muse Assist)
    public static func subtitle(
        planMetadata: PlanMetadata? = nil,
        automaticPlanName: String? = nil,
        poolSubtitle: String? = nil,
        providerKey: String? = nil
    ) -> String? {
        if let pool = poolSubtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !pool.isEmpty {
            return pool
        }
        if let meta = planMetadata {
            if let custom = meta.userSubtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
                return custom
            }
            if meta.showCostAndRenewal == true {
                let plan = meta.userPlanName ?? meta.detectedPlanName ?? automaticPlanName ?? ""
                let cost = meta.userCostUsd ?? ""
                let renewal = (meta.userRenewalDateText ?? "").isEmpty ? "" : "Renews \(meta.userRenewalDateText!)"
                let parts = [plan, cost, renewal].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !parts.isEmpty {
                    return parts.joined(separator: " · ")
                }
            }
            if let userPlan = meta.userPlanName?.trimmingCharacters(in: .whitespacesAndNewlines), !userPlan.isEmpty {
                return userPlan
            }
            if let detected = meta.detectedPlanName?.trimmingCharacters(in: .whitespacesAndNewlines), !detected.isEmpty {
                return detected
            }
        }
        if let auto = automaticPlanName?.trimmingCharacters(in: .whitespacesAndNewlines), !auto.isEmpty {
            return auto
        }
        let key = providerKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key == "muse-assist" {
            return "free"
        }
        return nil
    }
}

/// The one percentage a plan card leads with.
///
/// It is the lowest honest reading on the card, except that a Muse Assist
/// extra balance takes over only when the weekly allowance is spent.
/// The weekly row below still shows its own 0%.
public enum CardHeadline {
    public struct Reading: Equatable {
        public var isMuseAssistExtra: Bool
        public var isMasked: Bool
        /// A scoped pool allowance (a code-review or per-model bucket) is a
        /// real meter, but it is not the plan's headline:  the cap rule skips
        /// it, and counting it made the headline say 0% under a card the cap
        /// rule did not call spent (CC-214).
        public var isScopedAllowance: Bool
        public var remainingPercent: Double?

        public init(isMuseAssistExtra: Bool, isMasked: Bool, isScopedAllowance: Bool = false, remainingPercent: Double?) {
            self.isMuseAssistExtra = isMuseAssistExtra
            self.isMasked = isMasked
            self.isScopedAllowance = isScopedAllowance
            self.remainingPercent = remainingPercent
        }
    }

    public static func percent(_ readings: [Reading]) -> Double? {
        let honest = readings.filter { !$0.isMasked && !$0.isScopedAllowance }
        if let extra = honest.first(where: { $0.isMuseAssistExtra }),
           let percent = extra.remainingPercent, percent.isFinite, percent > 0 {
            return percent
        }
        return honest.compactMap(\.remainingPercent).filter { $0.isFinite }.min()
    }
}

/// How "last updated" reads.  The time alone is enough for today, but a
/// reading from an earlier day has to say so, or a day-old snapshot looks
/// current.
public enum UpdatedStamp {
    public static func label(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }
}


/// Allowance identity and source selection shared by the companion and widgets.
public enum QuotaCardProjection {
    public struct Reading: Equatable, Sendable {
        public var id: String
        public var providerKey: String
        public var label: String
        public var window: String?
        public var modelId: String?
        public var modelType: String?
        public var remainingPercent: Double?
        public var absoluteRemaining: Double?
        public var resetAt: Date?
        public var reportedAt: Date?
        public var source: String?
        public var via: String?

        public init(id: String, providerKey: String, label: String, window: String? = nil,
                    modelId: String? = nil, modelType: String? = nil,
                    remainingPercent: Double? = nil, absoluteRemaining: Double? = nil,
                    resetAt: Date? = nil, reportedAt: Date? = nil,
                    source: String? = nil, via: String? = nil) {
            self.id = id
            self.providerKey = providerKey
            self.label = label
            self.window = window
            self.modelId = modelId
            self.modelType = modelType
            self.remainingPercent = remainingPercent
            self.absoluteRemaining = absoluteRemaining
            self.resetAt = resetAt
            self.reportedAt = reportedAt
            self.source = source
            self.via = via
        }

        public var hasReading: Bool {
            remainingPercent?.isFinite == true
                || (absoluteRemaining?.isFinite == true && (absoluteRemaining ?? -1) >= 0)
        }

        /// Only these model limits have a separate detail in the companion.
        public var detailName: String? {
            let identity = [id, label, modelId ?? "", modelType ?? ""].joined(separator: " ").lowercased()
            if providerKey == "anthropic", identity.contains("fable") { return "Fable" }
            if providerKey == "google-antigravity", identity.contains("argon") { return "Argon" }
            return nil
        }

        public var isQuota: Bool {
            let lower = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !id.lowercased().hasSuffix(":plan-metadata"), lower != "plan details" else { return false }
            guard !QuotaCapRule.isSupplementaryVideoQuota(providerKey: providerKey, modelId: modelId,
                                                          modelType: modelType, label: label),
                  !QuotaCapRule.isScopedPoolAllowance(providerKey: providerKey, id: id, modelId: modelId,
                                                     modelType: modelType, label: label) else { return false }
            let subModel = QuotaCapRule.isSubModelLimit(providerKey: providerKey, id: id, modelId: modelId,
                                                      modelType: modelType, label: label)
            return !subModel || detailName != nil
        }

        public var allowanceKey: String {
            let cadence = QuotaWindowVocabulary.standardCadence(windowToken: window, label: label,
                                                                 resetAt: resetAt).lowercased()
            if let detailName { return detailName.lowercased() + ":" + cadence }
            if QuotaWindowVocabulary.isExtraAllowance(providerKey: providerKey, label: label, windowToken: window) {
                return "extra:" + cadence
            }
            // Primary model names describe observations of the same plan allowance.
            return cadence
        }

        public var displayLabel: String {
            if let detailName { return detailName + " limit" }
            if QuotaWindowVocabulary.isExtraAllowanceLabel(label) { return label }
            return QuotaWindowVocabulary.windowLabel(windowToken: window, existingLabel: label, resetAt: resetAt)
        }
    }

    public static func antigravityPeriod(_ reading: Reading) -> String? {
        let token = (reading.window ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().replacingOccurrences(of: " ", with: "")
        let label = reading.label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let weeklyLabels: Set<String> = ["weekly", "week", "7-day", "7 day", "7-day window", "7 day window"]
        let fiveHourLabels: Set<String> = ["5h", "5hr", "5-hour", "5 hours", "5-hour window", "5 hour window", "five_hour"]
        if ["weekly", "week", "1w", "7d", "168h", "10080m"].contains(token)
            || weeklyLabels.contains(label) { return "weekly" }
        if ["5h", "5hr", "5-hour", "5hours", "300m"].contains(token)
            || fiveHourLabels.contains(label) { return "5h" }
        return nil
    }

    /// Exported pool rows are authoritative; raw model observations fill only absent periods.
    public static func selectedPoolIndices(in readings: [Reading], poolKey: String, now: Date = Date()) -> [Int] {
        ["5h", "weekly"].compactMap { period in
            let indices = readings.indices.filter {
                readings[$0].detailName == nil && readings[$0].isQuota && antigravityPeriod(readings[$0]) == period
            }
            guard let pick = preferredIndex(in: indices.map { readings[$0] }, now: now,
                canonicalID: "antigravity:" + poolKey + ":" + period) else { return nil }
            return indices[pick]
        }
    }

    /// Prefer measurable, current Mac readings; otherwise use the newest current feed.
    /// An unknown placeholder never displaces a measured allowance.
    public static func preferredIndex(in readings: [Reading], now: Date = Date(),
                                      canonicalID: String? = nil) -> Int? {
        guard !readings.isEmpty else { return nil }
        let measured = readings.indices.filter { readings[$0].hasReading }
        let available = measured.isEmpty ? Array(readings.indices) : measured
        let fresh = available.filter {
            QuotaFreshnessRule.isFresh(observedAt: readings[$0].reportedAt, resetAt: readings[$0].resetAt, now: now)
        }
        let pool = fresh.isEmpty ? available : fresh
        if let canonicalID, let canonical = pool.first(where: { readings[$0].id == canonicalID }) {
            return canonical
        }
        let observations = pool.map {
            FleetQuotaObservation(remainingPercent: readings[$0].remainingPercent,
                                  reportedAt: readings[$0].reportedAt,
                                  isMacCodeCapsReading: FleetMacReading.isMacCodeCapsReading(
                                    id: readings[$0].id, source: readings[$0].source, via: readings[$0].via))
        }
        guard let pick = FleetMacReading.pickCardDisplay(from: observations, now: now) else { return pool.first }
        let chosen = pool[pick.chosenIndex]
        let chosenIsMac = observations[pick.chosenIndex].isMacCodeCapsReading
        let tied = pool.indices.filter {
            readings[pool[$0]].reportedAt == readings[chosen].reportedAt
                && observations[$0].isMacCodeCapsReading == chosenIsMac
        }.map { pool[$0] }
        return tied.min { (readings[$0].remainingPercent ?? .infinity) < (readings[$1].remainingPercent ?? .infinity) } ?? chosen
    }

    /// One honest row per allowance, primary periods first and model details last.
    /// Missing readings remain a provider status rather than an empty quota meter.
    public static func selectedIndices(in readings: [Reading], now: Date = Date()) -> [Int] {
        var groups: [String: [Int]] = [:]
        var order: [String] = []
        for index in readings.indices where readings[index].isQuota {
            let key = readings[index].allowanceKey
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(index)
        }
        let selected = order.compactMap { key -> Int? in
            guard let indices = groups[key],
                  let pick = preferredIndex(in: indices.map { readings[$0] }, now: now) else { return nil }
            let index = indices[pick]
            return readings[index].hasReading ? index : nil
        }
        return selected.sorted { left, right in
            let l = readings[left], r = readings[right]
            if (l.detailName != nil) != (r.detailName != nil) { return l.detailName == nil }
            if l.providerKey == "muse-assist" {
                let lExtra = QuotaWindowVocabulary.isExtraAllowance(providerKey: l.providerKey, label: l.label, windowToken: l.window)
                let rExtra = QuotaWindowVocabulary.isExtraAllowance(providerKey: r.providerKey, label: r.label, windowToken: r.window)
                if lExtra != rExtra { return !lExtra }
            }
            let lp = ResetAlarmCadence.periodSeconds(token: l.window, label: l.label) ?? .infinity
            let rp = ResetAlarmCadence.periodSeconds(token: r.window, label: r.label) ?? .infinity
            if lp != rp { return lp < rp }
            return left < right
        }
    }
}
