import Foundation

/// The words of a reset notification, shared by the Mac app and the iOS
/// companion so both say the same thing about the same reset.
///
/// Plain Foundation and nothing from the rest of QuotaCore except
/// `ResetAlarmEvent` and `sentenceGap`, so the iOS targets compile this file
/// directly (see `ios/CodeCapsCompanion/project.yml`).
public enum ResetAlarmMessage {
    /// The title, body and window labels for one provider's notification.  Every
    /// event in `events` belongs to the same provider; the largest window comes
    /// first.
    public static func content(for events: [ResetAlarmEvent]) -> (title: String, body: String, windowLabels: [String]) {
        let isVendorReset = events.contains { $0.isVendorReset }
        let title = isVendorReset
            ? "Vendor Reset: \(events.first?.providerTitle ?? "Quota")"
            : "Quota Reset: \(events.first?.providerTitle ?? "Quota")"
        var labels: [String] = []
        for event in events where !labels.contains(event.windowLabel) {
            labels.append(event.windowLabel)
        }
        let joined: String
        switch labels.count {
        case 0, 1: joined = labels.first ?? "quota"
        case 2: joined = "\(labels[0]) and \(labels[1])"
        default: joined = labels.dropLast().joined(separator: ", ") + " and " + (labels.last ?? "")
        }

        if isVendorReset {
            let reset = labels.count > 1 ? "The \(joined) windows received a vendor reset." : "The \(joined) window received a vendor reset."
            return (title, reset + sentenceGap + "Quota restored mid-cycle, ready to use again.", labels)
        }

        if let largest = events.first(where: { $0.reason == .newPeriod }) {
            let reset = labels.count > 1 ? "The \(joined) windows reset." : "The \(joined) window reset."
            return (title, reset + sentenceGap + newPeriodSentence(largest.periodSeconds), labels)
        }
        if events.count == 1, case .nearCap(let minimum) = events[0].reason {
            let reached = minimum <= 0
                ? "after hitting its cap"
                : "after reaching \(Int(minimum.rounded()))% remaining"
            return (title, "The \(joined) window reset \(reached)." + sentenceGap + "Ready to use again.", labels)
        }
        return (title, "The \(joined) windows reset." + sentenceGap + "Ready to use again.", labels)
    }

    /// "A new week of quota is available." and friends, by period length.
    static func newPeriodSentence(_ period: TimeInterval?) -> String {
        guard let period else { return "A new period of quota is available." }
        if period >= 27 * 86_400 { return "A new month of quota is available." }
        if period >= 6 * 86_400 { return "A new week of quota is available." }
        if period >= 20 * 3_600 { return "A new day of quota is available." }
        return "A new period of quota is available."
    }
}
