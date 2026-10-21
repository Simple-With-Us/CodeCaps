import Foundation
import QuotaCore

struct PlanMismatchWarning: Equatable, Identifiable {
    let providerKey: String
    let providerLabel: String
    let detectedPlan: String
    let enteredPlan: String
    var id: String { providerKey + "|" + detectedPlan + "|" + enteredPlan }
}

/// Acknowledgement lasts only for one open, never for the next app open.
struct PlanWarningCycle {
    private var hasOpened = false
    private var shown: Set<String> = []
    private var enteredAtOpen: [String: String]?
    private(set) var isPresenting = false

    mutating func beginOpen(customInfo: [String: PlatformCustomInfo]? = nil) {
        guard !isPresenting else { return }
        hasOpened = true
        enteredAtOpen = customInfo?.mapValues(\.planName)
        shown.removeAll()
    }

    mutating func warnings(windows: [QuotaWindow], customInfo: [String: PlatformCustomInfo], now: Date) -> [PlanMismatchWarning] {
        guard hasOpened, !isPresenting else { return [] }
        var warnings: [PlanMismatchWarning] = []
        for window in windows {
            let key = window.canonicalProviderKey
            guard !shown.contains(key), let observed = window.occurredDate,
                  (-300..<1_800).contains(now.timeIntervalSince(observed)),
                  let detected = window.planName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let entered = customInfo[key]?.planName.trimmingCharacters(in: .whitespacesAndNewlines),
                  PlanComparison.disagrees(detected: detected, entered: entered, providerKey: key) else { continue }
            // Do not interrupt an edit with a warning about a partial value.
            // The next explicit open compares the completed entered value.
            if let enteredAtOpen, enteredAtOpen[key] != customInfo[key]?.planName { continue }
            shown.insert(key)
            warnings.append(.init(providerKey: key, providerLabel: window.providerLabel ?? window.provider,
                                  detectedPlan: detected, enteredPlan: entered))
        }
        if !warnings.isEmpty { isPresenting = true }
        return warnings.sorted { $0.providerLabel < $1.providerLabel }
    }

    mutating func finishPresentation() { isPresenting = false }
}
