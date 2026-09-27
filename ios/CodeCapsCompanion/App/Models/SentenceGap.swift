import Foundation

/// No-break space plus a space, so two sentences in a user-visible string read
/// as two sentences rather than running together.
///
/// This mirrors `sentenceGap` in `Sources/QuotaCore/TokenHygiene.swift`.  It is
/// duplicated for the same reason `ResetAlarmSound` is: the iOS target cannot
/// import QuotaCore, which is declared macOS-only in `Package.swift`.
let sentenceGap = "\u{00A0} "

/// What happened when the owner pressed "Send Test Notification".
///
/// Mirrors `TestNotificationOutcome` in
/// `Sources/CodeCaps/ResetAlarmManager.swift` so the two sheets read the same
/// way.  The macOS copy of this type started because `UNUserNotificationCenter.add`
/// was called with no completion handler: a refused send produced no banner, no
/// sound, and no explanation, which is indistinguishable from a broken button.
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
            return "Test notification sent." + sentenceGap + "Banner and sound delivered."
        case .denied:
            return "Notifications are turned off for CodeCaps." + sentenceGap
                + "Turn them on in Settings, then try again."
        case .failed(let reason):
            return "Could not send the test notification." + sentenceGap + reason
        }
    }
}
