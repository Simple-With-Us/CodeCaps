import Foundation

/// The status values emitted by the Usage Monitor API.
public enum QuotaWindowStatus: String, Codable, Sendable {
    case available
    case nearCap = "near_cap"
    case exhausted
    case unknown

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = QuotaWindowStatus(rawValue: value) ?? .unknown
    }

    /// The single rule that turns a bounded remaining percentage into a status.
    /// Every reader and every export path uses this one derivation so a window
    /// can never claim "unknown" while reporting a real percentage.
    public static func derived(remainingPercent: Double?) -> QuotaWindowStatus {
        guard let value = remainingPercent else { return .unknown }
        if value == 0 { return .exhausted }
        return value < 20 ? .nearCap : .available
    }
}

public struct SkipModelType: Codable, Equatable, Sendable {
    public var instanceId: String
    public var model: String

    public init(instanceId: String, model: String) {
        self.instanceId = instanceId
        self.model = model
    }
}

/// A wire-compatible quota window.  Dates intentionally remain strings on the
/// wire because the web API uses ISO-8601 strings and older responses can carry
/// an invalid timestamp that must be displayed as stale rather than repaired.
public struct QuotaWindow: Codable, Equatable, Sendable {
    public var id: String
    public var provider: String
    public var providerKey: String?
    public var providerLabel: String?
    public var via: String?
    public var sourceApp: String?
    /// Durable producer identity, separate from the human-readable machine name.
    public var producerInstanceId: String?
    public var machine: String?
    public var modelId: String?
    public var modelType: String?
    public var label: String
    public var remainingPercent: Double?
    public var absoluteRemaining: Double?
    public var absoluteLimit: Double?
    public var quotaUnit: String?
    public var planName: String?
    public var remainingUnknown: Bool
    public var isExhausted: Bool
    public var resetAt: String?
    public var window: String?
    public var status: QuotaWindowStatus
    public var skip: Bool
    public var skipReason: String?
    public var occurredAt: String
    public var source: String?
    /// When this window's period began, as an ISO-8601 string, when the provider
    /// says so explicitly (Cursor's `billingCycleStart`, Grok's and MiniMax's
    /// period start).  The elapsed-time marker prefers it over a start derived
    /// from the reset and the window's cadence.
    ///
    /// Deliberately not a coding key: it is a local display input, not part of
    /// the wire schema, so the fleet ingest payload and the handoff file are
    /// unchanged.  A window that arrives over the wire has none and falls back
    /// to the derived start.
    public var periodStart: String? = nil
    /// Whose quota this window is, for a reader that reuses one window id for
    /// whichever account is active (Grok Bot's `gbu`).  The reset alarm restarts
    /// a window's history when this changes, so switching accounts is never
    /// mistaken for a reset.  Local only, like `periodStart`: not a coding key.
    public var accountKey: String? = nil

    private enum CodingKeys: String, CodingKey {
        case id, provider, providerKey, providerLabel, via, sourceApp, modelId, modelType, label
        case remainingPercent, absoluteRemaining, absoluteLimit, quotaUnit, planName
        case remainingUnknown, isExhausted, resetAt, window, status, skip, skipReason
        case occurredAt, source, producerInstanceId, machine
    }

    public init(
        id: String,
        provider: String,
        providerKey: String? = nil,
        providerLabel: String? = nil,
        via: String? = nil,
        sourceApp: String? = nil,
        modelId: String? = nil,
        modelType: String? = nil,
        label: String,
        remainingPercent: Double? = nil,
        absoluteRemaining: Double? = nil,
        absoluteLimit: Double? = nil,
        quotaUnit: String? = nil,
        planName: String? = nil,
        remainingUnknown: Bool = false,
        isExhausted: Bool = false,
        resetAt: String? = nil,
        window: String? = nil,
        status: QuotaWindowStatus = .unknown,
        skip: Bool = false,
        skipReason: String? = nil,
        occurredAt: String,
        source: String? = nil,
        periodStart: String? = nil,
        accountKey: String? = nil,
        producerInstanceId: String? = nil,
        machine: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.providerKey = providerKey
        self.providerLabel = providerLabel
        self.via = via
        self.sourceApp = sourceApp
        self.producerInstanceId = producerInstanceId
        self.machine = machine
        self.modelId = modelId
        self.modelType = modelType
        self.label = label
        self.remainingPercent = remainingPercent
        self.absoluteRemaining = absoluteRemaining
        self.absoluteLimit = absoluteLimit
        self.quotaUnit = quotaUnit
        self.planName = planName
        self.remainingUnknown = remainingUnknown
        self.isExhausted = isExhausted
        self.resetAt = resetAt
        self.window = window
        self.status = status
        self.skip = skip
        self.skipReason = skipReason
        self.occurredAt = occurredAt
        self.source = source
        self.periodStart = periodStart
        self.accountKey = accountKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        provider = try container.decode(String.self, forKey: .provider)
        providerKey = try container.decodeIfPresent(String.self, forKey: .providerKey)
        providerLabel = try container.decodeIfPresent(String.self, forKey: .providerLabel)
        via = try container.decodeIfPresent(String.self, forKey: .via)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        producerInstanceId = try container.decodeIfPresent(String.self, forKey: .producerInstanceId)
        machine = try container.decodeIfPresent(String.self, forKey: .machine)
        modelId = try container.decodeIfPresent(String.self, forKey: .modelId)
        modelType = try container.decodeIfPresent(String.self, forKey: .modelType)
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? provider
        remainingPercent = try container.decodeIfPresent(Double.self, forKey: .remainingPercent)
        absoluteRemaining = try container.decodeIfPresent(Double.self, forKey: .absoluteRemaining)
        absoluteLimit = try container.decodeIfPresent(Double.self, forKey: .absoluteLimit)
        quotaUnit = try container.decodeIfPresent(String.self, forKey: .quotaUnit)
        planName = try container.decodeIfPresent(String.self, forKey: .planName)
        remainingUnknown = try container.decodeIfPresent(Bool.self, forKey: .remainingUnknown) ?? false
        isExhausted = try container.decodeIfPresent(Bool.self, forKey: .isExhausted) ?? false
        resetAt = try container.decodeIfPresent(String.self, forKey: .resetAt)
        window = try container.decodeIfPresent(String.self, forKey: .window)
        status = try container.decodeIfPresent(QuotaWindowStatus.self, forKey: .status) ?? .unknown
        skip = try container.decodeIfPresent(Bool.self, forKey: .skip) ?? false
        skipReason = try container.decodeIfPresent(String.self, forKey: .skipReason)
        occurredAt = try container.decodeIfPresent(String.self, forKey: .occurredAt) ?? ""
        source = try container.decodeIfPresent(String.self, forKey: .source)
    }

    public var occurredDate: Date? { ISO8601Date.parse(occurredAt) }
    public var resetDate: Date? { resetAt.flatMap(ISO8601Date.parse) }
    public var periodStartDate: Date? { periodStart.flatMap(ISO8601Date.parse) }

    /// The canonical key used by native grouping and display.
    public var canonicalProviderKey: String {
        QuotaProviders.canonicalKey(provider: provider, providerKey: providerKey, via: via)
    }

    /// Video allowances are supplementary to MiniMax's coding subscription.
    public var isSupplementaryVideoQuota: Bool {
        guard canonicalProviderKey == "minimax" else { return false }
        let identity = [modelId, modelType, label].compactMap { $0 }.joined(separator: " ").lowercased()
        return identity.contains("video") || identity.contains("hailuo")
    }

    /// Extraneous weekly video quotas (e.g. 35/35) are omitted because the daily/interval allowance (5/5)
    /// is the true operative limit and weekly doesn't accumulate if not used daily.
    public var isExtraneousWeeklyVideoQuota: Bool {
        guard isSupplementaryVideoQuota else { return false }
        let token = (window ?? "").lowercased()
        let lbl = label.lowercased()
        let wid = id.lowercased()
        return token == "1w" || token == "weekly" || token == "7d"
            || lbl.contains("weekly") || wid.contains("weekly")
            || absoluteLimit == 35
    }

    /// A bounded value suitable for display.  NaN and infinities are unknown.
    public var boundedRemainingPercent: Double? {
        guard !remainingUnknown, let value = remainingPercent, value.isFinite else { return nil }
        return min(100, max(0, value))
    }

    /// Fills in the derived fields a reader left unset, so every window leaving
    /// this app carries the same contract.  A reader that builds a window
    /// without a status — the Antigravity grouped summary, for one — would
    /// otherwise publish `unknown` at zero remaining, and a consumer that trusts
    /// `status` or `isExhausted` would route to an exhausted pool.
    ///
    /// It only ever fills, never erases.  A source that reports a window as
    /// exhausted or skipped at a non-zero percentage knows something the
    /// percentage does not — a rejected session, a suspended plan, a cap the
    /// percentage lags behind — and this also runs on the display path, where
    /// restating those fields from the percentage alone would put a pool the
    /// provider called dead back in front of the user as live.  So the status is
    /// derived only when the source left it `unknown` and a bounded percentage
    /// is there to derive it from.  Applying this twice is a no-op.
    public func normalizedForExport() -> QuotaWindow {
        var copy = self
        let bounded = boundedRemainingPercent
        copy.remainingPercent = bounded
        copy.remainingUnknown = bounded == nil
        copy.isExhausted = isExhausted || bounded == 0
        if copy.isExhausted {
            copy.status = .exhausted
        } else if status == .unknown, bounded != nil {
            copy.status = QuotaWindowStatus.derived(remainingPercent: bounded)
        }
        copy.skip = skip || copy.isExhausted
        copy.skipReason = skipReason ?? (copy.isExhausted ? "quota exhausted" : nil)
        return copy
    }
}

/// Additive per-provider terms the backend can carry on the manifest.
/// Currently a single `defaultWindowLabel` ("5h", "weekly", ...) used as a
/// fallback label when a provider has no windows yet.  Missing fields decode
/// as absent — never a decode failure — so older payloads keep working.
public struct QuotaProviderTerms: Codable, Equatable, Sendable {
    public var defaultWindowLabel: String?

    private enum CodingKeys: String, CodingKey {
        case defaultWindowLabel
    }

    public init(defaultWindowLabel: String? = nil) {
        self.defaultWindowLabel = defaultWindowLabel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        defaultWindowLabel = try container.decodeIfPresent(String.self, forKey: .defaultWindowLabel)
    }
}

public struct QuotaProviderGroup: Codable, Equatable, Sendable {
    public var provider: String
    public var providerLabel: String
    public var via: String?
    public var expected: Bool
    public var windows: [QuotaWindow]
    /// Server-side ordering for the native section list.  Absent on legacy
    /// payloads and treated as zero (the older client-side expected list did
    /// its own ordering).  Sections sort ascending by it.
    public var sortOrder: Int?
    /// Optional brand-mark asset hint from the manifest.  The native logo
    /// resolver prefers this name when present, falling back to the built-in
    /// `resourceNames` map and finally to a neutral SF Symbol.
    public var iconHint: String?
    /// Per-provider fallback terms (currently a `defaultWindowLabel`).
    public var terms: QuotaProviderTerms?

    private enum CodingKeys: String, CodingKey {
        case provider, providerLabel, via, expected, windows
        case sortOrder, iconHint, terms
    }

    public init(
        provider: String,
        providerLabel: String,
        via: String? = nil,
        expected: Bool = false,
        windows: [QuotaWindow] = [],
        sortOrder: Int? = nil,
        iconHint: String? = nil,
        terms: QuotaProviderTerms? = nil
    ) {
        self.provider = provider
        self.providerLabel = providerLabel
        self.via = via
        self.expected = expected
        self.windows = windows
        self.sortOrder = sortOrder
        self.iconHint = iconHint
        self.terms = terms
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(String.self, forKey: .provider)
        providerLabel = try container.decodeIfPresent(String.self, forKey: .providerLabel) ?? provider
        via = try container.decodeIfPresent(String.self, forKey: .via)
        expected = try container.decodeIfPresent(Bool.self, forKey: .expected) ?? false
        windows = try container.decodeIfPresent([QuotaWindow].self, forKey: .windows) ?? []
        sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder)
        iconHint = try container.decodeIfPresent(String.self, forKey: .iconHint)
        terms = try container.decodeIfPresent(QuotaProviderTerms.self, forKey: .terms)
    }
}

/// Response from GET /api/quota-windows.  `providerGroups` is additive and is
/// optional on decode so this remains compatible with the original response.
public struct QuotaResponse: Codable, Equatable, Sendable {
    public var generatedAt: String
    public var windows: [QuotaWindow]
    public var skipModelTypes: [SkipModelType]
    public var providerGroups: [QuotaProviderGroup]

    public init(
        generatedAt: String,
        windows: [QuotaWindow] = [],
        skipModelTypes: [SkipModelType] = [],
        providerGroups: [QuotaProviderGroup] = []
    ) {
        self.generatedAt = generatedAt
        self.windows = windows
        self.skipModelTypes = skipModelTypes
        self.providerGroups = providerGroups
    }

    private enum CodingKeys: String, CodingKey {
        case generatedAt, windows, skipModelTypes, providerGroups
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        generatedAt = try container.decode(String.self, forKey: .generatedAt)
        windows = try container.decode([QuotaWindow].self, forKey: .windows)
        skipModelTypes = try container.decodeIfPresent([SkipModelType].self, forKey: .skipModelTypes) ?? []
        providerGroups = try container.decodeIfPresent([QuotaProviderGroup].self, forKey: .providerGroups) ?? []
    }
}

public enum QuotaFreshness: String, Sendable {
    case fresh
    case stale
    case awaitingRefresh
}

/// A window evaluated against a particular clock.  Freshness is never cached;
/// call `snapshot(now:)` again when the UI timer advances.
public struct QuotaWindowSnapshot: Equatable, Sendable {
    public let window: QuotaWindow
    public let remainingPercent: Double?
    public let status: QuotaWindowStatus
    public let freshness: QuotaFreshness
    public let observedAt: Date?
    public let resetAt: Date?

    public var isFresh: Bool { freshness == .fresh }
    public var isStale: Bool { freshness == .stale }
    public var isAwaitingRefresh: Bool { freshness == .awaitingRefresh }
    public var isUnknown: Bool { remainingPercent == nil }

    public init(window: QuotaWindow, now: Date = Date()) {
        let normalized = window.normalizedForExport()
        self.window = normalized
        self.observedAt = normalized.occurredDate
        self.resetAt = normalized.resetDate
        self.remainingPercent = normalized.boundedRemainingPercent
        self.status = normalized.status

        let observedIsFresh: Bool
        if let observedAt {
            let age = now.timeIntervalSince(observedAt)
            observedIsFresh = age < QuotaPolicy.staleAfter && age >= -QuotaPolicy.maximumFutureSkew
        } else {
            observedIsFresh = false
        }

        if let resetAt, resetAt <= now {
            freshness = .awaitingRefresh
        } else if observedIsFresh {
            freshness = .fresh
        } else {
            freshness = .stale
        }
    }
}

public struct QuotaPlatformSection: Equatable, Sendable {
    public let providerKey: String
    public let providerLabel: String
    public let via: String?
    public let expected: Bool
    public let windows: [QuotaWindowSnapshot]
    /// Server-supplied brand-mark hint, when the backend manifest names one.
    /// `PlatformLogo` prefers this when present and falls back to the built-in
    /// resource map.  Nil for sections that never had a manifest entry.
    public let iconHint: String?

    public var isMissing: Bool { expected && windows.isEmpty }
    public var hasFreshReport: Bool {
        windows.contains { $0.isFresh && $0.remainingPercent != nil }
    }

    public init(
        providerKey: String,
        providerLabel: String,
        via: String? = nil,
        expected: Bool,
        windows: [QuotaWindowSnapshot],
        iconHint: String? = nil
    ) {
        self.providerKey = providerKey
        self.providerLabel = providerLabel
        self.via = via
        self.expected = expected
        self.windows = windows
        self.iconHint = iconHint
    }
}

public extension QuotaResponse {
    /// Recomputes all timestamps and bounded percentages using `now`.
    func normalized(now: Date = Date()) -> QuotaResponse {
        var copy = self
        copy.windows = windows.map { $0.normalized() }
        copy.providerGroups = providerGroups.map { group in
            var groupCopy = group
            groupCopy.windows = group.windows.map { $0.normalized() }
            return groupCopy
        }
        return copy
    }

    /// Returns the stable native dashboard order, followed by future provider
    /// keys supplied by the server.  Missing expected providers are explicit.
    ///
    /// Server-first: every provider the manifest lists drives both the section
    /// order and its label.  The hardcoded `QuotaProviders.expected` list only
    /// runs when the server returns an empty `providerGroups` array — i.e. the
    /// offline fallback / pre-manifest backend path.  That branch is kept as a
    /// safety net for first-launch installs before a sync has completed.
    func platformSections(now: Date = Date()) -> [QuotaPlatformSection] {
        let normalizedWindows = windows.map { $0.normalized() }
        var grouped = Dictionary<String, [QuotaWindow]>(minimumCapacity: normalizedWindows.count)
        for window in normalizedWindows {
            grouped[window.canonicalProviderKey, default: []].append(window)
        }

        // Older responses may not have top-level windows but do have the
        // additive provider groups.  Fill only absent IDs to avoid duplicates.
        var seen = Set(normalizedWindows.map { "\($0.canonicalProviderKey):\($0.id)" })
        for group in providerGroups {
            for window in group.windows.map({ $0.normalized() }) where seen.insert("\(window.canonicalProviderKey):\(window.id)").inserted {
                grouped[window.canonicalProviderKey, default: []].append(window)
            }
        }

        // Build the manifest view: key, label, via, expected, iconHint, and
        // sort order, keyed by canonical key.  Groups that canonicalize to
        // the same key merge onto one entry (first-seen fields win) instead
        // of producing two sections with the same providerKey.  Future keys
        // without a manifest entry still cannot collide with a
        // canonicalized form.
        var manifest: [(key: String, label: String, labelFromServer: Bool, via: String?, expected: Bool, iconHint: String?, sortOrder: Int?)] = []
        if providerGroups.isEmpty {
            // OFFLINE FALLBACK: server returned no provider groups.  Use the
            // bundled list as the only source of order/labels.  An admin who
            // adds a provider must ship it through the server manifest, not by
            // editing this list.
            for provider in QuotaProviders.expected {
                manifest.append((provider.key, provider.label, false, provider.via, true, nil, 0))
            }
        } else {
            // Server-first: the manifest is authoritative.  Iterate in the
            // server-supplied array order (it already arrives sorted by
            // sortOrder), merging groups that canonicalize to the same key
            // (e.g. two `via == "antigravity"` groups fold onto
            // "google-antigravity") onto the first entry instead of emitting
            // duplicate sections with the same providerKey.  Fields the
            // first entry lacked are filled in from the later group; a
            // non-empty server label in a later group also replaces the
            // hardcoded fallback the entry carried when its own group
            // omitted the label.
            var manifestIndex: [String: Int] = [:]
            for group in providerGroups {
                let key = QuotaProviders.canonicalKey(provider: group.provider, providerKey: nil, via: group.via)
                guard !QuotaProviders.hidden.contains(key) else { continue }
                if let existing = manifestIndex[key] {
                    var entry = manifest[existing]
                    let serverLabel = group.providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !entry.labelFromServer, !serverLabel.isEmpty {
                        entry.label = serverLabel
                        entry.labelFromServer = true
                    }
                    entry.via = entry.via ?? group.via
                    entry.expected = entry.expected || group.expected
                    entry.iconHint = entry.iconHint ?? group.iconHint
                    entry.sortOrder = entry.sortOrder ?? group.sortOrder
                    manifest[existing] = entry
                } else {
                    manifestIndex[key] = manifest.count
                    let trimmed = group.providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
                    let label = trimmed.isEmpty ? QuotaProviders.label(for: key) : trimmed
                    manifest.append((key, label, !trimmed.isEmpty, group.via, group.expected, group.iconHint, group.sortOrder))
                }
            }
            // Re-sort only when at least one group actually supplied a
            // `sortOrder`.  A Phase-1 backend emits `providerGroups` with no
            // `sortOrder` at all; a tiebreak over all-zero orders would reorder
            // the dashboard alphabetically by label, contradict the documented
            // server order, and make the curated `QuotaProviders.expected`
            // order unreachable.  With no `sortOrder` anywhere, the server's
            // array order stands.
            if manifest.contains(where: { $0.sortOrder != nil }) {
                manifest.sort { lhs, rhs in
                    let l = lhs.sortOrder ?? 0
                    let r = rhs.sortOrder ?? 0
                    if l != r { return l < r }
                    return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
                }
            }
        }

        var sections: [QuotaPlatformSection] = []
        for entry in manifest {
            sections.append(makeSection(key: entry.key, label: entry.label, via: entry.via, expected: entry.expected, iconHint: entry.iconHint, grouped: grouped, now: now))
        }

        // Future keys: windows whose canonical key is in neither the manifest
        // nor the hidden set.  These still need a section, with the server's
        // group label winning over the hardcoded one.
        let knownKeys = Set(manifest.map(\.key))
        let futureKeys = grouped.keys.filter { key in
            !QuotaProviders.hidden.contains(key) && !knownKeys.contains(key)
        }.sorted()
        for key in futureKeys {
            let group = providerGroups.first { QuotaProviders.canonicalKey(provider: $0.provider, providerKey: nil, via: $0.via) == key }
            let groupLabel = group?.providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = groupLabel?.isEmpty == false ? groupLabel! : QuotaProviders.label(for: key)
            sections.append(makeSection(key: key, label: label, via: group?.via, expected: false, iconHint: group?.iconHint, grouped: grouped, now: now))
        }
        return sections
    }

    private func makeSection(
        key: String,
        label: String,
        via: String?,
        expected: Bool,
        iconHint: String? = nil,
        grouped: [String: [QuotaWindow]],
        now: Date
    ) -> QuotaPlatformSection {
        let reports = key == "google-antigravity"
            ? AntigravityQuotaGroups.normalize(grouped[key] ?? [], includeMissing: true)
            : grouped[key] ?? []
        let snapshots = reports.map { QuotaWindowSnapshot(window: $0, now: now) }
            .sorted { left, right in
                if key == "google-antigravity" { return left.window.id < right.window.id }
                // Cadence order: shorter periods (e.g. 5-hour) precede longer periods (e.g. weekly) across all platforms.
                let lPeriod = ResetAlarmCadence.periodSeconds(token: left.window.window, label: left.window.label)
                let rPeriod = ResetAlarmCadence.periodSeconds(token: right.window.window, label: right.window.label)
                if let lp = lPeriod, let rp = rPeriod, lp != rp {
                    return lp < rp
                }
                if lPeriod != nil && rPeriod == nil { return true }
                if lPeriod == nil && rPeriod != nil { return false }

                // Fresh low remaining values are actionable.  Stale and
                // awaiting-refresh values stay after fresh values and do not
                // compete with a real percentage.
                if left.isFresh != right.isFresh { return left.isFresh }
                if left.isFresh, left.remainingPercent != right.remainingPercent {
                    switch (left.remainingPercent, right.remainingPercent) {
                    case let (l?, r?): return l < r
                    case (_?, nil): return true
                    case (nil, _?): return false
                    default: break
                    }
                }
                return left.window.label.localizedCaseInsensitiveCompare(right.window.label) == .orderedAscending
            }
        return QuotaPlatformSection(providerKey: key, providerLabel: label, via: via, expected: expected, windows: snapshots, iconHint: iconHint)
    }
}

private extension QuotaWindow {
    func normalized() -> QuotaWindow {
        var copy = self
        copy.providerKey = canonicalProviderKey
        copy.providerLabel = providerLabel ?? QuotaProviders.label(for: copy.providerKey ?? copy.provider)
        copy.remainingPercent = boundedRemainingPercent
        copy.remainingUnknown = copy.remainingPercent == nil
        return copy
    }
}

private enum QuotaPolicy {
    static let staleAfter: TimeInterval = 30 * 60
    static let maximumFutureSkew: TimeInterval = 5 * 60
}

private enum ISO8601Date {
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let standard: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String) -> Date? {
        fractional.date(from: value) ?? standard.date(from: value)
    }
}

private enum QuotaProviders {
    struct Expected {
        let key: String
        let label: String
        let via: String?
    }

    // deepseek is retired as a quota provider (no local reader ever existed for it);
    // hidden also drops any server-pulled window that still canonicalizes to it.
    static let hidden: Set<String> = ["kimi", "github-copilot", "windsurf", "deepseek", "gemini-cli"]

    static let expected: [Expected] = [
        Expected(key: "anthropic", label: "Claude", via: nil),
        Expected(key: "openai", label: "Codex", via: nil),
        Expected(key: "google-antigravity", label: "Antigravity", via: "antigravity"),
        Expected(key: "cursor", label: "Cursor", via: nil),
        Expected(key: "xai", label: "Grok", via: nil),
        Expected(key: "grok-bot", label: "Grok Bot", via: "cursor"),
        Expected(key: "minimax", label: "MiniMax", via: nil),
        Expected(key: "muse-assist", label: "Muse Assist", via: nil),
        Expected(key: "muse-code", label: "Muse Code", via: nil),
    ]

    static func canonicalKey(provider: String, providerKey: String?, via: String?) -> String {
        if let viaLower = via?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            if viaLower == "antigravity" {
                return "google-antigravity"
            }
            if viaLower == "assist" || viaLower == "assistant" {
                return "muse-assist"
            }
            if viaLower == "code" {
                return "muse-code"
            }
        }
        let raw = (providerKey?.isEmpty == false ? providerKey! : provider)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let aliases: [String: String] = [
            "anthropic": "anthropic", "claude": "anthropic", "claude-code": "anthropic", "claude.ai": "anthropic",
            "openai": "openai", "openai-codex": "openai", "codex": "openai",
            "google": "google-antigravity", "google-antigravity": "google-antigravity", "antigravity": "google-antigravity", "antigravity-cli": "google-antigravity", "gemini": "google-antigravity",
            "cursor": "cursor",
            "xai": "xai", "grok": "xai", "grok-build": "xai",
            "grok-bot": "grok-bot", "grok bot": "grok-bot", "grokbot": "grok-bot",
            "minimax": "minimax", "minimax-code": "minimax",
            "muse-assist": "muse-assist", "muse assist": "muse-assist", "muse_assist": "muse-assist", "muse-assistant": "muse-assist", "muse assistant": "muse-assist",
            "muse-code": "muse-code", "muse code": "muse-code", "muse_code": "muse-code",
            "muse": "muse-code", "muse-cli": "muse-code", "muse-sdk": "muse-code",
            "kimi": "kimi", "moonshot": "kimi", "moonshot-ai": "kimi",
            "gemini-cli": "gemini-cli",
            "copilot": "github-copilot", "github-copilot": "github-copilot", "github_copilot": "github-copilot",
            "windsurf": "windsurf", "codeium": "windsurf",
        ]
        return aliases[raw] ?? raw
    }

    static func label(for key: String) -> String {
        expected.first(where: { $0.key == key })?.label ?? key
    }
}

/// Public aliases mirror the web quota projection helpers while retaining the
/// optional additive provider identity fields used by the native client.
public let expectedQuotaProviderKeys: [String] = QuotaProviders.expected.map(\.key)
public let EXPECTED_QUOTA_PROVIDERS: [String] = expectedQuotaProviderKeys

public func quotaProviderKey(_ provider: String, providerKey: String? = nil, via: String? = nil) -> String {
    QuotaProviders.canonicalKey(provider: provider, providerKey: providerKey, via: via)
}

public func quotaProviderLabel(_ provider: String, providerKey: String? = nil, via: String? = nil) -> String {
    QuotaProviders.label(for: quotaProviderKey(provider, providerKey: providerKey, via: via))
}

public func quotaProviderVia(_ provider: String, providerKey: String? = nil, via: String? = nil) -> String? {
    if let via, !via.isEmpty { return via }
    return quotaProviderKey(provider, providerKey: providerKey, via: via) == "google-antigravity" ? "antigravity" : nil
}

// MARK: - Window Pacing & Timespan Calculations

public struct WindowPacing: Equatable, Sendable {
    public let durationSeconds: TimeInterval
    public let elapsedSeconds: TimeInterval
    public let timeElapsedPercent: Double // 0.0 - 100.0
    public let quotaUsedPercent: Double // 0.0 - 100.0
    public let isUnderCapPace: Bool
    public let paceRatio: Double
    public let timeElapsedLabel: String
    public let resetLabel: String
    public let paceDescription: String

    public static func calculate(
        windowToken: String?,
        windowLabel: String,
        resetAt: Date?,
        remainingPercent: Double?,
        now: Date = Date(),
        periodStart: Date? = nil,
        calendar: Calendar = QuotaPeriod.billingCalendar
    ) -> WindowPacing? {
        guard let resetAt, let remainingPercent else { return nil }
        // The same span the elapsed-time marker draws, so the bar and its
        // "Day 3 of 7" caption can never disagree: an explicit start wins, and a
        // monthly window is a calendar month rather than a flat 30 days.
        guard let span = QuotaPeriodSpan.resolve(
            token: windowToken,
            label: windowLabel,
            resetAt: resetAt,
            explicitStart: periodStart,
            calendar: calendar
        ) else {
            return nil
        }
        let durationSeconds = span.duration
        guard durationSeconds > 0 else { return nil }

        let windowStart = span.start
        let elapsed = max(0, min(durationSeconds, now.timeIntervalSince(windowStart)))
        let timePercent = min(100, max(0, (elapsed / durationSeconds) * 100))
        let usedPercent = min(100, max(0, 100 - remainingPercent))

        let remainingSeconds = max(0, resetAt.timeIntervalSince(now))
        let isUnderCap = usedPercent <= (timePercent + 5.0) // 5% grace buffer

        let timeElapsedLabel: String
        if durationSeconds >= 86400 * 6 { // Weekly / 7-day
            let elapsedDays = Int(ceil(elapsed / 86400))
            let totalDays = Int(round(durationSeconds / 86400))
            timeElapsedLabel = "Day \(max(1, elapsedDays)) of \(totalDays)"
        } else if durationSeconds >= 86400 { // Daily / 24-hour
            let elapsedHours = Int(elapsed / 3600)
            timeElapsedLabel = "\(elapsedHours)h of 24h elapsed"
        } else { // 5-hour, 1-hour, etc.
            let elapsedHours = Int(elapsed / 3600)
            let elapsedMins = Int((elapsed.truncatingRemainder(dividingBy: 3600)) / 60)
            if elapsedHours > 0 {
                timeElapsedLabel = "\(elapsedHours)h \(elapsedMins)m elapsed"
            } else {
                timeElapsedLabel = "\(elapsedMins)m elapsed"
            }
        }

        let resetLabel: String
        let remMinutes = max(1, Int(ceil(remainingSeconds / 60)))
        if remMinutes >= 1440 {
            resetLabel = "Resets in \(remMinutes / 1440)d \((remMinutes % 1440) / 60)h"
        } else if remMinutes >= 60 {
            resetLabel = "Resets in \(remMinutes / 60)h \(remMinutes % 60)m"
        } else {
            resetLabel = "Resets in \(remMinutes)m"
        }

        let paceRatio = timePercent > 0 ? (usedPercent / timePercent) : 1.0
        let paceDescription: String
        if usedPercent == 0 {
            paceDescription = "0% used · Fully available"
        } else if isUnderCap {
            paceDescription = "On track · \(Int(usedPercent.rounded()))% used at \(Int(timePercent.rounded()))% of window"
        } else {
            paceDescription = "Ahead of pace · \(Int(usedPercent.rounded()))% used at \(Int(timePercent.rounded()))% of window"
        }

        return WindowPacing(
            durationSeconds: durationSeconds,
            elapsedSeconds: elapsed,
            timeElapsedPercent: timePercent,
            quotaUsedPercent: usedPercent,
            isUnderCapPace: isUnderCap,
            paceRatio: paceRatio,
            timeElapsedLabel: timeElapsedLabel,
            resetLabel: resetLabel,
            paceDescription: paceDescription
        )
    }

    public static func parseDurationSeconds(token: String?, label: String) -> TimeInterval? {
        let combined = "\(token ?? "") \(label)".lowercased()
        if combined.contains("weekly") || combined.contains("7-day") || combined.contains("7d") || combined.contains("7 day") {
            return 7 * 86400
        }
        if combined.contains("monthly") || combined.contains("30d") || combined.contains("30-day") || combined.contains("month") {
            return 30 * 86400
        }
        if combined.contains("daily") || combined.contains("24h") || combined.contains("24-hour") || combined.contains("1d") || combined.contains("day") {
            return 86400
        }
        if combined.contains("5-hour") || combined.contains("5h") || combined.contains("5 hour") {
            return 5 * 3600
        }
        if combined.contains("1-hour") || combined.contains("1h") || combined.contains("1 hour") {
            return 3600
        }
        if combined.contains("2-hour") || combined.contains("2h") {
            return 2 * 3600
        }
        if combined.contains("3-hour") || combined.contains("3h") {
            return 3 * 3600
        }
        if combined.contains("6-hour") || combined.contains("6h") {
            return 6 * 3600
        }
        if combined.contains("12-hour") || combined.contains("12h") {
            return 12 * 3600
        }
        return nil
    }
}

public extension QuotaWindowSnapshot {
    func pacing(now: Date = Date(), calendar: Calendar = QuotaPeriod.billingCalendar) -> WindowPacing? {
        WindowPacing.calculate(
            windowToken: window.window,
            windowLabel: window.label,
            resetAt: resetAt,
            remainingPercent: remainingPercent,
            now: now,
            periodStart: window.periodStartDate,
            calendar: calendar
        )
    }
}

// MARK: - Platform Custom Metadata

public struct PlatformCustomInfo: Codable, Equatable, Sendable {
    public var customSubtitle: String
    public var planName: String
    public var costUsd: String
    public var renewalDateText: String
    public var showCostAndRenewal: Bool

    public init(
        customSubtitle: String = "",
        planName: String = "",
        costUsd: String = "",
        renewalDateText: String = "",
        showCostAndRenewal: Bool = false
    ) {
        self.customSubtitle = customSubtitle
        self.planName = planName
        self.costUsd = costUsd
        self.renewalDateText = renewalDateText
        self.showCostAndRenewal = showCostAndRenewal
    }
}

/// The Renewal Date field is a free-text override.  When the owner has not
/// typed one, a platform that actually reports a billing-cycle end (Cursor's
/// `billingCycleEnd`) fills it in.  A 5-hour or weekly quota reset is not a
/// plan renewal, so those windows are ignored.
public enum BillingRenewal {
    public static func text(
        for windows: [QuotaWindow],
        now: Date = Date(),
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        let dates = windows.compactMap { window -> Date? in
            guard window.window == "billing-cycle" else { return nil }
            return window.resetDate
        }
        guard let date = dates.filter({ $0 > now }).min() ?? dates.max() else { return nil }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter.string(from: date)
    }
}
