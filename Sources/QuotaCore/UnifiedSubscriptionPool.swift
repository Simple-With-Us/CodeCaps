import Foundation

/// Coordinates the unified subscription allowance pool shared across Cursor,
/// xAI, Grok, and Grok Bot.
///
/// Under the hood, Cursor's included weekly pool (Composer / Grok), xAI's
/// subscription allowance, Grok's subscription credits, and Grok Bot's weekly
/// meter (Cursor DashboardService or `gbu`) tap into the same underlying pool.
/// When any one of these sources provides a live reading, that reading is
/// shared across all participant providers so none of them report "stale
/// reading" or "unavailable" while another source has a fresh reading.
public enum UnifiedSubscriptionPool {
    /// The canonical provider keys that participate in this shared pool.
    public static let participantKeys: Set<String> = ["cursor", "xai", "grok", "grok-bot"]

    /// The window ids that name the shared pool, per participant.
    ///
    /// Each entry is the id's last two components:  the segment that names
    /// the window's family and the token that names the window inside it.
    /// They are compared in full, so a window that merely mentions a pool
    /// word, or whose id merely starts with a pool token, is not the pool.
    ///
    /// `plan` is the Cursor reader's included pool, `subscription` the Grok
    /// reader's credits and the fleet's xAI collector's bucket, and `weekly`
    /// and `gbu-weekly` the two Grok Bot readers' weekly meter.  The `unknown`
    /// entries are the placeholders a reader writes when it could not read the
    /// provider:  they carry no number, and the pool fills them in place
    /// rather than adding a second row beside them.
    ///
    /// The xAI provider takes the `grok` segment as well:  the fleet files
    /// the Grok credits payload under the xAI key, and the id it carries
    /// names the reader that produced it.
    ///
    /// An id that is not listed here is not in the pool.  That is the safe
    /// direction:  a window that cannot be named confidently stays out rather
    /// than standing in for the pool reading.
    private static let canonicalPoolWindowIDs: [String: Set<String>] = [
        "cursor": ["cursor:plan", "cursor:unknown", "cursor:subscription"],
        "xai": ["xai:subscription", "grok:subscription"],
        "grok": ["grok:subscription", "grok:unknown"],
        "grok-bot": ["grok-bot:weekly", "grok-bot:gbu-weekly", "grok-bot:unknown",
                    "grok-bot:gbu-unknown", "grok-bot:subscription"],
    ]

    /// The labels of the windows that sit beside the pool rather than in it.
    ///
    /// They are matched in full.  The id is the identity of a window, so a
    /// label that merely mentions one of these words no longer decides
    /// anything on its own:  the id decides, and a label that is one of
    /// these keeps its window out.
    private static let nonCanonicalPoolLabels: Set<String> = [
        // The plan metadata window this app writes for a provider it has no
        // reading for.  It carries no reading at all.
        "plan details",
        // The meters that report money rather than the included pool.
        "billing cycle spend",
        "api credits",
        // A per-account allowance, which is a separate quota of its own.
        "account allowance",
    ]

    /// The cadence tokens of the windows that sit beside the pool.
    ///
    /// Cursor's plan spend meter reports the billing cycle and shares the
    /// pool's own window id, so the cadence is what tells the two apart.
    private static let nonCanonicalCadenceTokens: Set<String> = ["billing-cycle"]

    /// The quota units that mean money rather than the included pool.
    private static let currencyUnits: Set<String> = ["$", "usd", "us$"]

    /// Whether a window belongs to this shared subscription pool.
    public static func isPoolWindow(_ window: QuotaWindow) -> Bool {
        let key = window.canonicalProviderKey
        guard participantKeys.contains(key) else { return false }
        if window.isSupplementaryVideoQuota { return false }
        // A financial spend meter is not the included pool.
        if currencyUnits.contains(normalizedToken(window.quotaUnit)) { return false }
        // A billing cycle is not the included pool either.
        if nonCanonicalCadenceTokens.contains(normalizedToken(window.window)) { return false }
        // The id names the window: its last two components must be exactly
        // one of the canonical ids, matched in full.  Comparing in full is the
        // point: a substring test let a window that merely mentioned "api"
        // or "account" decide, and let an id that merely started with a pool
        // word join the pool by accident.
        guard let identity = poolIdentity(of: window.id),
              canonicalPoolWindowIDs[key]?.contains(identity) == true
        else { return false }
        // A label this codebase mints for a window beside the pool keeps it
        // out, even when its id names the pool.
        guard !nonCanonicalPoolLabels.contains(normalizedToken(window.label)) else { return false }
        return true
    }

    /// Finds the freshest, most authoritative reading among candidate windows.
    public static func freshestReading(in windows: [QuotaWindow], now: Date = Date()) -> QuotaWindow? {
        // An absolute balance alone cannot replace a percentage meter.  Keep the
        // target reading until a usable shared percentage is available.
        let candidates = windows.filter {
            isPoolWindow($0) && $0.boundedRemainingPercent != nil
                && QuotaWindowSnapshot(window: $0, now: now).isFresh
                && (!$0.skip || $0.boundedRemainingPercent == 0)
        }
        return candidates.max { a, b in
            let dateA = a.occurredDate ?? .distantPast
            let dateB = b.occurredDate ?? .distantPast
            if dateA != dateB { return dateA < dateB }
            let snapA = QuotaWindowSnapshot(window: a, now: now)
            let snapB = QuotaWindowSnapshot(window: b, now: now)
            if snapA.isFresh != snapB.isFresh { return !snapA.isFresh && snapB.isFresh }
            let localA = a.sourceApp == "local-mac"
            let localB = b.sourceApp == "local-mac"
            if localA != localB { return !localA && localB }
            return false
        }
    }

    /// Canonical pool window ID for a given participant key.
    ///
    /// Every participant is named with the same `:subscription` token: the
    /// four rows are one pool, and the rest of the app reads the pool by that
    /// token.  `UsageMonitorPushMetadata.bucketId` files an xAI window under
    /// the `xai:subscription` bucket only when the id's suffix is exactly
    /// `subscription`, and `QuotaResponse.dedupedGrokSubscription` pairs a
    /// Grok row with an xAI row only when both ids end in `:subscription`, so
    /// a participant named `:plan` landed in a second Usage Monitor bucket
    /// and escaped the dedupe.
    public static func canonicalWindowId(for providerKey: String) -> String {
        switch providerKey {
        case "cursor": return "local-mac:cursor:subscription"
        case "xai": return "local-mac:xai:subscription"
        case "grok": return "local-mac:grok:subscription"
        case "grok-bot": return "local-mac:grok-bot:subscription"
        default: return "local-mac:\(providerKey):subscription"
        }
    }

    /// Canonical pool window label for a given participant key.
    public static func canonicalWindowLabel(for providerKey: String) -> String {
        switch providerKey {
        case "cursor": return "Included plan"
        case "xai": return "Subscription window"
        case "grok": return "Subscription window"
        case "grok-bot": return "Included weekly"
        default: return "Subscription window"
        }
    }

    /// Creates an adapted pool window for the given participant key from a source window.
    public static func adapt(_ source: QuotaWindow, for providerKey: String) -> QuotaWindow {
        var copy = source
        copy.provider = QuotaProviders.label(for: providerKey)
        copy.providerKey = providerKey
        copy.providerLabel = QuotaProviders.label(for: providerKey)
        // Participant IDs describe the target provider, never the donor. Keep
        // origin in dedicated fields; a remote donor is not this Mac's reader.
        let participantID = canonicalWindowId(for: providerKey)
        let origin = poolOrigin(of: source)
        if source.id.hasPrefix("local-mac:"), source.sourceApp == "local-mac" {
            copy.id = participantID
        } else {
            let originKey = encodedOriginKey(origin)
            copy.id = participantID.replacingOccurrences(of: "local-mac:", with: "shared-pool:\(originKey):")
        }
        copy.label = canonicalWindowLabel(for: providerKey)
        copy.remainingUnknown = false
        copy.sourceApp = source.sourceApp
        // The row the pool injects is a participant of the pool and it carries
        // the collector that produced the number.  The dedupe must not read it
        // as a second collector's report of the same pool.
        copy.sharedPoolOrigin = origin
        return copy.normalizedForExport()
    }

    /// The donor's identity, taken from the first provenance field that has a
    /// value.
    ///
    /// An empty field is not an identity.  Two donors that both leave the
    /// field blank would otherwise share one id, and the dedupe and the
    /// exhaustion tracking would read them as the same donor.
    public static func poolOrigin(of source: QuotaWindow) -> String {
        // A row the pool filled in already names the producer of the number.
        // That name comes first, so the origin stays steady when the row is
        // elected as the donor on a later round: without it the origin would
        // name the row's own collector and flap on every refresh.
        if let shared = source.sharedPoolOrigin?.trimmingCharacters(in: .whitespacesAndNewlines),
           !shared.isEmpty {
            return shared
        }
        let candidates = [source.producerInstanceId, source.machine, source.source, source.id]
        for candidate in candidates {
            guard let candidate else { continue }
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return source.id
    }

    /// The origin encoded for use in an id.
    ///
    /// The id ends up in cache keys, file names, URLs and alert keys, so the
    /// encoding has to be safe in all of them: base64url without padding,
    /// which carries none of the characters that break a path or a query.
    public static func encodedOriginKey(_ origin: String) -> String {
        Data(origin.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Updates or injects the freshest reading across all participant providers present
    /// or expected in the window list.
    public static func share(windows: [QuotaWindow], now: Date = Date(), targetKeys: Set<String>? = nil) -> [QuotaWindow] {
        guard let best = freshestReading(in: windows, now: now) else {
            return windows
        }

        let bestDate = best.occurredDate ?? .distantPast
        let keysToUpdate = targetKeys ?? participantKeys
        // The collector that produced the reading the pool shares.  It is
        // resolved the way `adapt` resolves an origin, and it names the
        // producer rather than the row: `source` keeps naming the row's own
        // collector, so switching one producer off in Settings cannot hide
        // the pool reading on every other row.
        //
        // A row the pool filled in on an earlier round already carries the
        // producer's name, and that name wins.  Without it the origin would
        // name the row's own collector when that row was elected as the
        // donor on the next round, and it would flap on every refresh.
        let donorOrigin = poolOrigin(of: best)

        var result: [QuotaWindow] = []
        var participantsHandled = Set<String>()

        for window in windows {
            let key = window.canonicalProviderKey
            if keysToUpdate.contains(key) && isPoolWindow(window) {
                participantsHandled.insert(key)
                let windowDate = window.occurredDate ?? .distantPast
                if window.hasReading && windowDate >= bestDate {
                    // Current window is already as fresh or fresher than best
                    result.append(window)
                } else {
                    // Update this window with the fresher reading from best
                    var updated = window
                    // A donor that cannot report a value must not erase the
                    // target's own.  `freshestReading` only accepts a donor
                    // with a bounded percentage, so the percentage is always
                    // there; the absolute amounts and the unit are not, and a
                    // target that knows its own limit keeps it.
                    updated.remainingPercent = best.remainingPercent ?? window.remainingPercent
                    updated.absoluteRemaining = best.absoluteRemaining ?? window.absoluteRemaining
                    updated.absoluteLimit = best.absoluteLimit ?? window.absoluteLimit
                    updated.quotaUnit = best.quotaUnit ?? window.quotaUnit
                    updated.status = best.status
                    updated.isExhausted = best.isExhausted
                    updated.resetAt = best.resetAt ?? window.resetAt
                    updated.periodStart = best.periodStart ?? window.periodStart
                    // The number is the pool's, so it was observed when the
                    // donor observed it, and the row is dated then.  A row
                    // that kept its own older date would read as stale while
                    // showing a live number.
                    updated.occurredAt = best.occurredAt
                    // The row keeps its own collector.  The number is the
                    // pool's, but the row is still this provider's, and
                    // `disabledSources` switches off one collector at a time:
                    // a shared row that wore the donor's name disappeared
                    // from every other row when that collector was switched
                    // off.
                    updated.source = window.source ?? best.source
                    updated.sourceApp = window.sourceApp ?? best.sourceApp ?? "local-mac"
                    updated.planName = window.planName ?? best.planName
                    updated.window = best.window ?? window.window ?? "weekly"
                    updated.remainingUnknown = false
                    updated.skip = best.skip
                    updated.skipReason = best.skipReason
                    // The row now shows the pool's reading, so it names the
                    // collector that produced it.  The dedupe leaves the
                    // pool's own rows alone, so the Grok and xAI rows of one
                    // pool cannot tie on time and lose one of themselves.
                    updated.sharedPoolOrigin = donorOrigin
                    result.append(updated.normalizedForExport())
                }
            } else {
                result.append(window)
            }
        }

        let presentKeys = Set(windows.map(\.canonicalProviderKey))
        for key in keysToUpdate where !participantsHandled.contains(key) {
            if presentKeys.contains(key) || targetKeys != nil {
                result.append(adapt(best, for: key))
            }
        }

        return result
    }

    // MARK: - Canonical matching

    /// The provider and the token a window id names.
    ///
    /// An id carries an optional source prefix (`local-mac:grok:subscription`,
    /// `shared-pool:<origin>:grok:subscription`), so the last two components
    /// are the identity, exactly as `QuotaResponse.dedupedGrokSubscription`
    /// reads them.
    private static func poolIdentity(of id: String) -> String? {
        let parts = id.split(separator: ":")
        guard parts.count >= 2 else { return nil }
        return "\(parts[parts.count - 2]):\(parts[parts.count - 1])"
    }

    /// A comparable form of a label, unit or token: trimmed and lowercased,
    /// so the canonical sets are compared against the value the reader wrote
    /// rather than against its spacing.
    private static func normalizedToken(_ value: String?) -> String {
        (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
