import Foundation

/// Number formatting shared by the monitor's alert text and the plugin page,
/// so the words in a notification and the figures on screen cannot drift.
public enum MuseCodeFormatting {
    public static func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func percent(_ share: Double) -> String {
        String(format: "%.1f%%", share * 100)
    }
}

/// The Muse plugin's deterministic rule set.  Pure code: a report in,
/// an alert (or not) out — no I/O, no clock of its own, no model anywhere.
///
/// Two distinct findings live here and in
/// `MuseCodeStandardSessionDetector`, because they are two distinct alert
/// kinds at the app level:
///
/// - `BurnAlert` (kind `museCodeBurn`): the combined rule the owner asked
///   for — trailing-90-minute burn above the threshold AND at least one
///   session currently on a standard model.
/// - Standard-session events (kind `museCodeStandardSession`): the
///   contributor finding on its own, fired by the detector the moment a
///   session starts on, or switches to, a standard model, independent of
///   the burn threshold, so a future channel can subscribe to the finding
///   itself rather than to the burn alert's side effect.
///
/// Neither rule uses the contributor token share.  A share computed from
/// rotating session snapshots moves for reasons unrelated to either
/// question — stale sessions inside the window, token weight, last-segment
/// attribution — and reads below 100% even when every live session is on a
/// contributor model.  Presence is the signal: which sessions are on
/// standard models right now.
public enum MuseCodeBurnMonitor {
    public static let defaultThresholdTokens = 4_000_000
    public static let alertCooldown: TimeInterval = 3_600
    public static let windowMinutes = 90

    public struct BurnAlert: Equatable, Sendable {
        public let totalTokens: Int
        public let thresholdTokens: Int
        public let standardSessions: [MuseCodeStandardSessionEvent]
        public let observedAt: Date

        public init(totalTokens: Int, thresholdTokens: Int,
                    standardSessions: [MuseCodeStandardSessionEvent], observedAt: Date) {
            self.totalTokens = totalTokens
            self.thresholdTokens = thresholdTokens
            self.standardSessions = standardSessions
            self.observedAt = observedAt
        }

        public var title: String { "Muse Burn Above Threshold" }

        public var body: String {
            "Muse used \(MuseCodeFormatting.grouped(totalTokens)) tokens in the last 90 minutes, above the \(MuseCodeFormatting.grouped(thresholdTokens)) token threshold."
                + sentenceGap
                + "Standard-model sessions: \(Self.sessionList(standardSessions))."
        }

        static func sessionList(_ sessions: [MuseCodeStandardSessionEvent]) -> String {
            sessions.map { "\($0.sessionId) on \($0.modelId)" }.joined(separator: ", ")
        }
    }

    /// The monitor state the plugin page shows, derived from the same
    /// evaluation that fires the alerts.
    public enum Status: Equatable, Sendable {
        case storeUnavailable
        case noActivity
        case belowThreshold(totalTokens: Int)
        case allContributor(totalTokens: Int)
        case currentModelsUnknown(totalTokens: Int)
        case warning(BurnAlert)

        public var text: String {
            switch self {
            case .storeUnavailable: return "Session store unavailable"
            case .noActivity: return "No Muse activity in the last 90 minutes"
            case .belowThreshold: return "Below the burn threshold"
            case .allContributor: return "All sessions on contributor models"
            case .currentModelsUnknown: return "Current session models unavailable"
            case .warning: return "Burn threshold exceeded on standard models"
            }
        }
    }

    /// The standard-model sessions in one reading: the detector's presence
    /// test over the reading's latest per-session observations.
    public static func standardSessions(in report: MuseCodeSessionReport) -> [MuseCodeStandardSessionEvent] {
        MuseCodeStandardSessionDetector.standardSessions(
            in: report.currentModelObservations)
    }

    /// The combined rule.  "Exceeds" is strict: a window exactly at the
    /// threshold has not exceeded it.  The standard-model condition is
    /// presence — at least one session in the reading is on a standard
    /// model — never the contributor token share.
    public static func evaluateBurn(report: MuseCodeSessionReport,
                                    thresholdTokens: Int) -> BurnAlert? {
        guard let window = report.window(minutes: windowMinutes),
              window.totalTokens > thresholdTokens else { return nil }
        let standard = standardSessions(in: report)
        guard !standard.isEmpty else { return nil }
        return BurnAlert(totalTokens: window.totalTokens,
                         thresholdTokens: thresholdTokens,
                         standardSessions: standard,
                         observedAt: report.generatedAt)
    }

    public static func status(report: MuseCodeSessionReport?, issue: String?,
                              thresholdTokens: Int) -> Status {
        guard let report else { return .storeUnavailable }
        guard let window = report.window(minutes: windowMinutes),
              window.totalTokens > 0 else { return .noActivity }
        if let alert = evaluateBurn(report: report, thresholdTokens: thresholdTokens) {
            return .warning(alert)
        }
        if standardSessions(in: report).isEmpty {
            guard !report.currentModelObservations.isEmpty,
                  report.currentModelObservations.allSatisfy({ observation in
                      guard let model = observation.modelId, !model.isEmpty else { return false }
                      return MuseCodeStandardSessionDetector.isContributor(modelId: model)
                  }) else { return .currentModelsUnknown(totalTokens: window.totalTokens) }
            return .allContributor(totalTokens: window.totalTokens)
        }
        return .belowThreshold(totalTokens: window.totalTokens)
    }
}
