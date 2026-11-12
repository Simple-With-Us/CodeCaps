import Foundation

/// Whether an App Group `quota-windows.json` tier should be treated as final
/// or the reader should continue to Application Support and other fallbacks.
public enum AppGroupSnapshotReadDecision: Equatable, Sendable {
    /// The file is missing, unreadable, or not decodable — try the next store.
    case consultNextTier
    /// Decode succeeded; an explicitly empty snapshot is authoritative and must
    /// not resurrect stale rows from a lower tier.
    case stopAuthoritativeEmpty
    /// Decode succeeded with one or more windows.
    case stopAuthoritativeContent
}

public enum AppGroupSnapshotReadPolicy {
    public static func decision(
        filePresent: Bool,
        readSucceeded: Bool,
        decodeSucceeded: Bool,
        decodedExplicitlyEmpty: Bool
    ) -> AppGroupSnapshotReadDecision {
        guard filePresent else { return .consultNextTier }
        guard readSucceeded, decodeSucceeded else { return .consultNextTier }
        if decodedExplicitlyEmpty { return .stopAuthoritativeEmpty }
        return .stopAuthoritativeContent
    }
}
