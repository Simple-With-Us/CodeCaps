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
        let isPlanChange = !isVendorReset && events.contains { $0.isPlanChange }
        let provider = events.first?.providerTitle ?? "Quota"
        let title = isVendorReset
            ? "Vendor Reset: \(provider)"
            : (isPlanChange ? "Likely Plan Change: \(provider)" : "Quota Reset: \(provider)")
        var labels: [String] = []
        for event in events {
            let label = normalizedWindowLabel(for: event)
            if !labels.contains(label) {
                labels.append(label)
            }
        }
        let joined: String
        switch labels.count {
        case 0, 1: joined = labels.first ?? "quota"
        case 2: joined = "\(labels[0]) and \(labels[1])"
        default: joined = labels.dropLast().joined(separator: ", ") + " and " + (labels.last ?? "")
        }

        if isPlanChange {
            // The level it came back to is the whole point, so it is in the
            // sentence: a plan change and a vendor reset look the same until
            // you see how much of the allowance is back.
            let level = events.first(where: { $0.isPlanChange })?.remainingPercent
            let rose = level.map { " to \(Int($0.rounded()))%" } ?? ""
            let change = labels.count > 1
                ? "The \(joined) windows' quota rose\(rose) mid-cycle."
                : "The \(joined) window's quota rose\(rose) mid-cycle."
            return (title, change + sentenceGap + "More likely a plan change than a vendor reset.", labels)
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

    /// The label the owner reads for one event's window, with the one
    /// provider-specific correction the fleet applies.
    ///
    /// MiniMax reports a four-hour window that it calls five hours, so the
    /// label is corrected once and everywhere: in the notification, in the
    /// window list and in the Usage History card.
    public static func normalizedWindowLabel(for event: ResetAlarmEvent) -> String {
        let label = event.windowLabel
        if (label == "4h" || label == "4-hour") && event.providerTitle.lowercased().contains("minimax") {
            return "5h"
        }
        return label
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
