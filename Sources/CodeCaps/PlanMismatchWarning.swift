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

/// "Don't show this again" for the mismatch popup.  Suppression is sticky,
/// but a mismatch the owner has never seen still interrupts: only a repeat
/// of an already-recorded (provider, detected plan) pair stays silent.
enum PlanMismatchSuppression {
    private static let suppressedKey = "planMismatchWarningsSuppressed"
    private static let knownKey = "planMismatchKnownDetections"

    static var isSuppressed: Bool {
        get { UserDefaults.standard.bool(forKey: suppressedKey) }
        set { UserDefaults.standard.set(newValue, forKey: suppressedKey) }
    }

    /// Detected plans the owner has already been shown, by provider key.
    static var knownDetections: [String: String] {
        get { (UserDefaults.standard.dictionary(forKey: knownKey) as? [String: String]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: knownKey) }
    }

    /// When the popup last appeared.  It fires at most once an hour no matter
    /// how often the app opens, while a never-seen mismatch still breaks
    /// through suppression immediately.
    static var lastPresentedAt: Date? {
        get {
            let epoch = UserDefaults.standard.double(forKey: "planMismatchLastPresentedAt")
            return epoch > 0 ? Date(timeIntervalSince1970: epoch) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: "planMismatchLastPresentedAt") }
    }

    /// Owner-accepted (provider, entered, detected) triples.  Choosing "keep
    /// mine" records the exact pair, so the popup stays silent for it — while
    /// any new entered value or any changed detected plan warns again.
    static var acceptedOverrides: [String: [String]] {
        get { (UserDefaults.standard.dictionary(forKey: "planMismatchAcceptedOverrides") as? [String: [String]]) ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "planMismatchAcceptedOverrides") }
    }

    static func accept(providerKey: String, entered: String, detected: String) {
        var accepted = acceptedOverrides
        accepted[providerKey] = [entered.trimmingCharacters(in: .whitespacesAndNewlines),
                                detected.trimmingCharacters(in: .whitespacesAndNewlines)]
        acceptedOverrides = accepted
    }

    static func isAccepted(providerKey: String, entered: String, detected: String) -> Bool {
        guard let pair = acceptedOverrides[providerKey], pair.count == 2 else { return false }
        return pair[0] == entered.trimmingCharacters(in: .whitespacesAndNewlines)
            && pair[1] == detected.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when every current warning repeats an already-recorded pair.
    static func isRepeat(_ warnings: [PlanMismatchWarning]) -> Bool {
        let known = knownDetections
        return !warnings.isEmpty && warnings.allSatisfy { known[$0.providerKey] == $0.detectedPlan }
    }

    static func record(_ warnings: [PlanMismatchWarning]) {
        var known = knownDetections
        for warning in warnings { known[warning.providerKey] = warning.detectedPlan }
        knownDetections = known
    }
}
