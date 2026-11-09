import Foundation

/// Where a pulled quota window came from.
///
/// New payloads carry an explicit producer instance and a separate machine
/// label.  Older responses remain readable, but a generic app name alone
/// cannot prove a window was produced by this Mac.
public enum FleetOrigin {
    /// The origin a window names, or `fleet` when it names none.
    public static func identity(of window: QuotaWindow) -> String {
        for candidate in [window.producerInstanceId, window.machine, window.source, window.sourceApp] {
            let value = (candidate ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { return value }
        }
        return "fleet"
    }

    /// Stable fleet header key: installation id first, then machine, then legacy
    /// producer labels.
    private static func fleetGroupKey(for window: QuotaWindow) -> String {
        identity(of: window).lowercased()
    }

    private static func normalizeMachineString(_ str: String) -> String {
        str.lowercased()
            .replacingOccurrences(of: ".local", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
    }

    private static func localPayloadId(_ id: String) -> String {
        let prefix = QuotaWindowVocabulary.localDeviceWindowPrefix
        return id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : id
    }

    /// Whether a pulled window is this Mac's own push coming back.  Such a
    /// window belongs under This Mac and must never be duplicated under Fleet.
    public static func isOwnPush(
        _ window: QuotaWindow,
        host: String = QuotaPublisher.producerInstanceId,
        localWindows: [QuotaWindow] = []
    ) -> Bool {
        var legacyProducerName: String?
        if let instance = window.producerInstanceId?.trimmingCharacters(in: .whitespacesAndNewlines), !instance.isEmpty {
            if instance.lowercased() == host.lowercased() { return true }
            // A UUID-shaped instance id is authoritative:  it is another
            // installation's identity, and the machine-name match below must
            // not override it.  A name-shaped one is a legacy collector's
            // machine name (the Muse Code collector wrote
            // `Mac.Jays.Services` — this Mac's own name — into the
            // producer field), so it falls through and the machine-name
            // match decides whether the window is this Mac's own (CC-217).
            if UUID(uuidString: instance) != nil { return false }
            legacyProducerName = instance
        }
        if window.id.hasPrefix(QuotaWindowVocabulary.localDeviceWindowPrefix) {
            return true
        }
        if let sourceApp = window.sourceApp?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           sourceApp == "local-mac" {
            return true
        }
        if let machine = window.machine?.trimmingCharacters(in: .whitespacesAndNewlines), !machine.isEmpty {
            let normM = normalizeMachineString(machine)
            let normLocal = normalizeMachineString(QuotaPublisher.machineName)
            let normHost = normalizeMachineString(ProcessInfo.processInfo.hostName)
            let normHostParam = normalizeMachineString(host)
            if normM == normLocal || normM == normHost || normM == normHostParam || normM == "localmac" || normM == "mac" {
                return true
            }
        }
        // A window that names its producer explicitly is only ever claimed by
        // the machine-name match above and below:  matching it to a local
        // reading by timestamp would let another installation's reading pose
        // as this Mac's own just because both saw the same period (CC-217).
        if !window.occurredAt.isEmpty, !localWindows.isEmpty, legacyProducerName == nil {
            let occurred = window.occurredAt
            let matchesLocal = localWindows.contains { local in
                local.canonicalProviderKey == window.canonicalProviderKey
                    && local.occurredAt == occurred
                    // Missing cadence tokens do not identify the same payload.
                    // Compare the same normalized IDs used by local adoption.
                    && (localPayloadId(local.id) == localPayloadId(window.id)
                        || (local.window != nil && local.window == window.window))
            }
            if matchesLocal { return true }
        }
        let identity = identity(of: window).lowercased()
        let normId = normalizeMachineString(identity)
        let normLocal = normalizeMachineString(QuotaPublisher.machineName)
        let normHost = normalizeMachineString(ProcessInfo.processInfo.hostName)
        let normHostParam = normalizeMachineString(host)
        // The legacy producer name itself, before it is folded into the
        // identity:  the identity check below already compares the same
        // string, and this keeps the legacy name decisive even when another
        // field would win the identity fallback.
        if let legacyProducerName {
            let normLegacy = normalizeMachineString(legacyProducerName)
            if normLegacy == normHostParam || normLegacy == normLocal || normLegacy == normHost
                || normLegacy == "localmac" || normLegacy == "mac" {
                return true
            }
        }
        if normId == normHostParam || normId == normLocal || normId == normHost || normId == "localmac" {
            return true
        }
        // When a window comes from the app itself (e.g. source: "codecaps" or "agent-bar") without an explicit remote instance,
        // and matches any of this Mac's observed local provider keys, it is this Mac's own push coming back.
        let isCodeCapsSource = ([QuotaPublisher.producerId] + QuotaPublisher.legacyProducerAliases + ["local-mac"]).contains(identity)
            || ([QuotaPublisher.producerId] + QuotaPublisher.legacyProducerAliases + ["local-mac"]).contains((window.source ?? "").lowercased())
            || ([QuotaPublisher.producerId] + QuotaPublisher.legacyProducerAliases + ["local-mac"]).contains((window.sourceApp ?? "").lowercased())
        if isCodeCapsSource && window.producerInstanceId == nil && window.machine == nil {
            if localWindows.contains(where: { $0.canonicalProviderKey == window.canonicalProviderKey }) {
                return true
            }
        }
        return false
    }

    /// Whether the window's producer field carries a legacy machine-name
    /// identity rather than an install UUID (CC-217):  a UUID is another
    /// installation's authoritative identity, while a name is the legacy
    /// collector's machine name and may be this Mac's own.
    public static func isLegacyNameProducer(_ window: QuotaWindow, host: String) -> Bool {
        guard let instance = window.producerInstanceId?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !instance.isEmpty,
            instance.lowercased() != host.lowercased(),
            UUID(uuidString: instance) == nil else { return false }
        return true
    }

    /// The key that names one meter, shared by the split's retention rules
    /// and the widget publisher's duplicate rule, so both ask the same
    /// question about the same meter (CC-217).
    public static func cadenceIdentityKey(of window: QuotaWindow) -> String {
        window.canonicalProviderKey
            + ":" + QuotaWindowVocabulary.standardCadence(windowToken: window.window,
                                                          label: window.label,
                                                          resetAt: window.resetDate,
                                                          periodStart: window.periodStartDate)
            + ":" + (window.modelId ?? "")
            + ":" + (window.accountKey ?? "")
    }

    /// The cadence keys the current collector itself reports:  a legacy-name
    /// copy of one of those meters is a superseded duplicate, never a
    /// reading that may publish or be retained (CC-217).
    public static func authoritativeOwnCadenceKeys(in windows: [QuotaWindow], host: String) -> Set<String> {
        Set(windows
            .filter { $0.producerInstanceId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == host.lowercased() }
            .map { cadenceIdentityKey(of: $0) })
    }

    /// "antigravity-usage" reads as "Antigravity Usage" in a group header.
    public static func title(for identity: String) -> String {
        // A host is a host.  `chatgpt.com` title-cased to `ChATGPT.com`, which
        // is not a hostname, and `api.minimax.io` to `Api.minimax.io`.  The
        // owner asked (2026-10-01) that a URL not be capitalised at all unless
        // every part of it is, so hosts pass through untouched and only a
        // machine name gets its words capitalised.
        if identity.contains(".") && !identity.contains(" ") { return identity }
        return identity
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Splits pulled windows into this Mac's own push and everybody else's,
    /// with the second group keyed by origin and sorted for a stable header
    /// order.
    ///
    /// This is where another machine's window enters a surface's data, so it
    /// is where the shared dead-copy rule is asked.  A copy of a period that
    /// ended before the last refresh is not a reading, so it never reaches a
    /// row.  It is dropped here rather than in a section builder:  this Mac's
    /// own expired reading must survive, so the row can grey it out and wait
    /// for a refresh, and an Antigravity pool whose copies have all expired
    /// must still get its missing window back.
    public static func split(
        _ windows: [QuotaWindow],
        host: String = QuotaPublisher.producerInstanceId,
        localWindows: [QuotaWindow] = [],
        now: Date = Date()
    ) -> (ownPush: [QuotaWindow], groups: [(id: String, title: String, windows: [QuotaWindow])]) {
        var own: [QuotaWindow] = []
        var grouped: [String: [QuotaWindow]] = [:]
        // This Mac's own push is exempt from the dead-copy rule only while
        // this Mac still reads that provider:  the local window is what greys
        // out an ended period, so the copy of it coming back from the fleet is
        // redundant.  A provider this Mac no longer reads has no local window
        // to grey out, and its own copy of an ended period is a copy like any
        // other (owner, 2026-10-23:  the xAI row read two ended windows
        // instead of the live reading).
        let localReaders = QuotaLocalScope.providers(withReadings: localWindows)
        // The dead-copy drop is narrowed per cadence:  a dead copy whose
        // provider still has a live window of the same cadence is redundant
        // and goes, but a dead copy whose cadence has nothing live left is
        // the last known state of that meter.  Dropping the second kind took
        // the whole cadence row off the provider:  the Muse Code collector
        // restates its periods only when new usage arrives, so the finished
        // 5h window vanished from the row while the weekly one survived
        // (CC-211, owner 2026-11-07).  The xAI row keeps the fix from
        // 2026-10-23:  its live weekly reading puts its cadence in this set,
        // so the ended copies still drop.
        // The key names one meter: provider, cadence, and the model and
        // account that split a provider's meters apart.  The cadence
        // classification gets the window's reset and period start, the way
        // every other caller classifies:  an opaque token is dated by its
        // reset, so two opaque periods of one meter stay distinct instead of
        // collapsing into one key (PR review, kody).
        func cadenceKey(of window: QuotaWindow) -> String {
            cadenceIdentityKey(of: window)
        }
        let liveCadences = Set(windows
            .filter { !QuotaFreshnessRule.isDeadCopy(observedAt: $0.occurredDate,
                                                     resetAt: $0.resetDate,
                                                     now: now) }
            .map(cadenceKey))
        // The meters the current collector itself reports:  a legacy-name
        // copy of one of those is a superseded duplicate of a period the
        // install-id copy already covers, not a meter only the old collector
        // ever saw (the widget-snapshot single-xAI pin).
        let authoritativeOwnCadences = Set(windows
            .filter { $0.producerInstanceId?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == host.lowercased() }
            .map(cadenceKey))
        for window in windows {
            let dead = QuotaFreshnessRule.isDeadCopy(observedAt: window.occurredDate,
                                                     resetAt: window.resetDate,
                                                     now: now)
            let cadenceIsLive = liveCadences.contains(cadenceKey(of: window))
            // A legacy-name copy of a meter the current collector reports is
            // a superseded duplicate of this Mac's own reading, so it is
            // neither retained nor shown as somebody else's fleet row
            // (kody, PR #380).
            let legacyDuplicate = isOwnPush(window, host: host, localWindows: localWindows)
                && isLegacyNameProducer(window, host: host)
                && authoritativeOwnCadences.contains(cadenceKey(of: window))
            if legacyDuplicate {
            } else if isOwnPush(window, host: host, localWindows: localWindows) {
                if localReaders.contains(window.canonicalProviderKey)
                    || !dead
                    || !cadenceIsLive {
                    own.append(window)
                }
            } else if !dead {
                // A copy from another machine has no local window to grey it
                // out, and the row it would feed is the fleet fallback for a
                // provider this Mac does not read:  an ended 0% copy becoming
                // that row is the CC-191 failure, so remote dead copies still
                // drop without exception (PR review, kody and sentry).
                grouped[fleetGroupKey(for: window), default: []].append(window)
            }
        }
        let groups = grouped.keys.sorted().map { key in
            let readings = grouped[key] ?? []
            let machine = readings.compactMap { $0.machine?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            let name: String
            if let machine { name = machine }
            else if readings.contains(where: { $0.producerInstanceId != nil }) { name = "Mac (\(key))" }
            else if ([QuotaPublisher.producerId] + QuotaPublisher.legacyProducerAliases).contains(key.lowercased()) {
                name = "Unidentified Mac"
            } else { name = title(for: key) }
            return (id: key, title: name, windows: readings)
        }
        return (own, groups)
    }
}
