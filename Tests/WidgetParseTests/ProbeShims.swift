public enum TestNotificationOutcome: Equatable, Sendable {
    case sent
    /// Notifications are off for this app; nothing can be delivered until the
    /// owner grants them in Settings.
    case denied
    /// Delivery failed for a reason worth showing.
    case failed(String)

    public var isFailure: Bool {
        if case .sent = self { return false }
        return true
    }

    public var message: String {
        switch self {
        case .sent:
            return "Test notification accepted." + sentenceGap + "System settings control banners and sound."
        case .denied:
            return "Notifications are turned off for CodeCaps." + sentenceGap
                + "Turn them on in Settings, then try again."
        case .failed(let reason):
            return "Could not send the test notification." + sentenceGap + reason
        }
    }
}
public struct LocalQuotaResult: Equatable, Sendable {
    public let windows: [QuotaWindow]
    public let issues: [String: String]
    /// Provider keys whose credential exists on this Mac but is unreadable
    /// until the owner allows this build once.  Kept apart from `issues`
    /// because it is the difference between "sign in" — which the owner
    /// cannot act on when they already have — and a button they can press.
    public let consentNeeded: Set<String>

    public init(windows: [QuotaWindow] = [],
                issues: [String: String] = [:],
                consentNeeded: Set<String> = []) {
        self.windows = windows
        self.issues = issues
        self.consentNeeded = consentNeeded
    }
}

/// Reads the quota sources that the vendor CLIs already use on this Mac.
