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
/// Two distinct findings live here, because they are two distinct alert
/// kinds at the app level:
///
/// - `BurnAlert` (kind `museCodeBurn`): the combined rule the owner asked
///   for — trailing-90-minute burn above the threshold AND contributor share
///   below 100%.
/// - `ContributorAlert` (kind `museCodeContributorBelow100`): the
///   contributor finding on its own, independent of the burn threshold, so
///   a future channel can subscribe to the finding itself rather than to
///   the burn alert's side effect.
public enum MuseCodeBurnMonitor {
    public static let defaultThresholdTokens = 4_000_000
    public static let alertCooldown: TimeInterval = 3_600
    public static let windowMinutes = 90

    public struct BurnAlert: Equatable, Sendable {
        public let totalTokens: Int
        public let thresholdTokens: Int
        public let contributorShare: Double
        public let standardModels: [MuseCodeModelUsage]
        public let observedAt: Date

        public init(totalTokens: Int, thresholdTokens: Int, contributorShare: Double,
                    standardModels: [MuseCodeModelUsage], observedAt: Date) {
            self.totalTokens = totalTokens
            self.thresholdTokens = thresholdTokens
            self.contributorShare = contributorShare
            self.standardModels = standardModels
            self.observedAt = observedAt
        }

        public var title: String { "Muse Burn Above Threshold" }

        public var body: String {
            "Muse used \(MuseCodeFormatting.grouped(totalTokens)) tokens in the last 90 minutes, above the \(MuseCodeFormatting.grouped(thresholdTokens)) token threshold."
                + sentenceGap
                + "Contributor models handled \(MuseCodeFormatting.percent(contributorShare)) of those tokens."
                + sentenceGap
                + "Standard models: \(Self.modelList(standardModels, total: totalTokens))."
        }

        static func modelList(_ models: [MuseCodeModelUsage], total: Int) -> String {
            models.map {
                "\($0.modelId) — \(MuseCodeFormatting.grouped($0.tokens)) tokens (\(MuseCodeFormatting.percent($0.share(of: total))))"
            }.joined(separator: ", ")
        }
    }

    public struct ContributorAlert: Equatable, Sendable {
        public let totalTokens: Int
        public let contributorShare: Double
        public let standardModels: [MuseCodeModelUsage]
        public let observedAt: Date

        public init(totalTokens: Int, contributorShare: Double,
                    standardModels: [MuseCodeModelUsage], observedAt: Date) {
            self.totalTokens = totalTokens
            self.contributorShare = contributorShare
            self.standardModels = standardModels
            self.observedAt = observedAt
        }

        public var title: String { "Muse Contributor Share Below 100%" }

        public var body: String {
            "Standard models handled \(MuseCodeFormatting.percent(1 - contributorShare)) of Muse tokens in the last 90 minutes."
                + sentenceGap
                + "Standard models: \(BurnAlert.modelList(standardModels, total: totalTokens))."
                + sentenceGap
                + "Contributor models handled \(MuseCodeFormatting.percent(contributorShare)) of \(MuseCodeFormatting.grouped(totalTokens)) tokens."
        }
    }

    /// The monitor state the plugin page shows, derived from the same
    /// evaluation that fires the alerts.
    public enum Status: Equatable, Sendable {
        case storeUnavailable
        case noActivity
        case belowThreshold(totalTokens: Int)
        case allContributor(totalTokens: Int)
        case warning(BurnAlert)

        public var text: String {
            switch self {
            case .storeUnavailable: return "Session store unavailable"
            case .noActivity: return "No Muse activity in the last 90 minutes"
            case .belowThreshold: return "Below the burn threshold"
            case .allContributor: return "All tokens on contributor models"
            case .warning: return "Burn threshold exceeded on standard models"
            }
        }
    }

    /// The combined rule.  "Exceeds" is strict: a window exactly at the
    /// threshold has not exceeded it.
    public static func evaluateBurn(report: MuseCodeSessionReport,
                                    thresholdTokens: Int) -> BurnAlert? {
        guard let window = report.window(minutes: windowMinutes),
              window.totalTokens > thresholdTokens,
              let share = window.contributorShare, share < 1,
              !window.standardModels.isEmpty else { return nil }
        return BurnAlert(totalTokens: window.totalTokens,
                         thresholdTokens: thresholdTokens,
                         contributorShare: share,
                         standardModels: window.standardModels,
                         observedAt: report.generatedAt)
    }

    /// The contributor finding alone: any standard-model tokens at all in
    /// the window, whatever the burn rate.
    public static func evaluateContributor(report: MuseCodeSessionReport) -> ContributorAlert? {
        guard let window = report.window(minutes: windowMinutes),
              window.totalTokens > 0,
              let share = window.contributorShare, share < 1,
              !window.standardModels.isEmpty else { return nil }
        return ContributorAlert(totalTokens: window.totalTokens,
                                contributorShare: share,
                                standardModels: window.standardModels,
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
        if window.contributorShare == 1 {
            return .allContributor(totalTokens: window.totalTokens)
        }
        return .belowThreshold(totalTokens: window.totalTokens)
    }
}
