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

    /// Whether a pulled window is this Mac's own push coming back.  Such a
    /// window belongs under This Mac and must never be duplicated under Fleet.
    public static func isOwnPush(_ window: QuotaWindow, host: String = QuotaPublisher.producerInstanceId) -> Bool {
        if let instance = window.producerInstanceId?.trimmingCharacters(in: .whitespacesAndNewlines), !instance.isEmpty {
            return instance == host
        }
        // A legacy producer label such as codecaps or agent-bar is shared by
        // every installation.  Only an actual host match can identify its owner.
        let identity = identity(of: window).lowercased()
        let mine = host.lowercased()
        return identity == mine || identity == mine.replacingOccurrences(of: ".local", with: "")
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
    public static func split(
        _ windows: [QuotaWindow],
        host: String = QuotaPublisher.producerInstanceId
    ) -> (ownPush: [QuotaWindow], groups: [(id: String, title: String, windows: [QuotaWindow])]) {
        var own: [QuotaWindow] = []
        var grouped: [String: [QuotaWindow]] = [:]
        for window in windows {
            if isOwnPush(window, host: host) {
                own.append(window)
            } else {
                grouped[identity(of: window), default: []].append(window)
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
