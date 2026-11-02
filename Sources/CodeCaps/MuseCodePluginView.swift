import QuotaCore
import SwiftUI

/// Routes a Plugins-section page to the plugin that owns it.
struct MuseCodePluginPage: View {
    @ObservedObject var model: MonitorModel
    let pluginId: String

    var body: some View {
        if let plugin = CodeCapsPlugin.named(pluginId), plugin == .museCode {
            MuseCodeMonitorPage(model: model)
        } else {
            Text("Plugin unavailable")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

/// The Muse monitor plugin: current burn, contributor share, the
/// per-model split, and the deterministic monitor's state and controls.
struct MuseCodeMonitorPage: View {
    @ObservedObject var model: MonitorModel

    private var window90: MuseCodeWindowUsage? { model.museCodeReport?.window(minutes: 90) }
    private var window60: MuseCodeWindowUsage? { model.museCodeReport?.window(minutes: 60) }

    private var status: MuseCodeBurnMonitor.Status {
        MuseCodeBurnMonitor.status(report: model.museCodeReport, issue: model.museCodeIssue,
                                     thresholdTokens: model.museCodeBurnThresholdTokens)
    }

    private var isWarning: Bool {
        if case .warning = status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerSection
            if let issue = model.museCodeIssue {
                Text(issue)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            monitorSection
            burnSection
            contributorSection
            modelsSection
            alertsSection
            bridgeSection
            Text("Session stores rotate snapshots aggressively, so every total on this page is a floor rather than an exact count.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 26))
                .foregroundStyle(isWarning ? Theme.warning : Theme.ink.opacity(0.8))
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Muse Monitor")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    if isWarning {
                        Text("WARNING")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.warning, in: Capsule())
                    }
                }
                Text("Deterministic monitoring of Muse token burn and contributor model share on this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: - Sections

    private var monitorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("MONITOR")
            VStack(alignment: .leading, spacing: 8) {
                row("Status", status.text)
                if let report = model.museCodeReport {
                    row("Last Read", report.generatedAt.formatted(date: .omitted, time: .standard))
                }
                if let alert = model.museCodeBurnAlert {
                    row("Burn Alert", alert.body)
                } else if let alert = model.museCodeContributorAlert {
                    row("Contributor Alert", alert.body)
                }
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        }
    }

    private var burnSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("BURN")
            VStack(alignment: .leading, spacing: 8) {
                if let window = window90 {
                    row("Last 90 Minutes", "\(MuseCodeFormatting.grouped(window.totalTokens)) tokens")
                    row("Burn Rate", "\(MuseCodeFormatting.grouped(Int(window.tokensPerHour.rounded()))) tokens per hour")
                    row("Active Sessions", "\(window.activeSessions)")
                }
                if let window = window60 {
                    row("Last 60 Minutes", "\(MuseCodeFormatting.grouped(window.totalTokens)) tokens")
                }
                if window90 == nil {
                    row("Burn", "No reading yet")
                }
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        }
    }

    private var contributorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("CONTRIBUTOR SHARE")
            VStack(alignment: .leading, spacing: 8) {
                if let window = window90, let share = window.contributorShare {
                    row("Contributor Share (90 minutes)", MuseCodeFormatting.percent(share))
                    row("Contributor Tokens", MuseCodeFormatting.grouped(window.contributorTokens))
                    if share < 1 {
                        row("Standard Tokens", MuseCodeFormatting.grouped(window.totalTokens - window.contributorTokens))
                    }
                } else {
                    row("Contributor Share (90 minutes)", "No tokens in window")
                }
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        }
    }

    private var modelsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("MODELS")
            VStack(alignment: .leading, spacing: 8) {
                if let window = window90, !window.models.isEmpty {
                    ForEach(window.models) { usage in
                        HStack(spacing: 10) {
                            Text(usage.modelId)
                                .font(.system(size: 12).monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Text(usage.isContributor ? "Contributor" : "Standard")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(usage.isContributor ? Theme.accent : Theme.warning)
                            Text("\(MuseCodeFormatting.grouped(usage.tokens)) tokens")
                                .font(.system(size: 12).monospacedDigit())
                            Text(MuseCodeFormatting.percent(usage.share(of: window.totalTokens)))
                                .font(.system(size: 12).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                    }
                } else {
                    row("Models", "No model activity in window")
                }
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        }
    }

    private var alertsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("ALERTS")
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Muse Alerts", isOn: $model.museCodeBurnAlertsEnabled)
                HStack(spacing: 12) {
                    Text("Burn Threshold")
                        .font(.system(size: 13, weight: .medium))
                        .frame(width: 150, alignment: .leading)
                    Text("\(MuseCodeFormatting.grouped(model.museCodeBurnThresholdTokens)) tokens in 90 minutes")
                        .font(.system(size: 13).monospacedDigit())
                    Stepper("", value: $model.museCodeBurnThresholdTokens,
                            in: 100_000...50_000_000, step: 100_000)
                        .labelsHidden()
                }
                Text("Two alert kinds: museCodeBurn fires when burn passes the threshold on standard models."
                    + sentenceGap
                    + "museCodeContributorBelow100 fires on its own when a standard model handles any tokens, whatever the burn rate.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        }
    }

    private var bridgeSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Eyebrow("USAGE MONITOR BRIDGE")
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Post Token Events To Usage Monitor", isOn: $model.museCodeUsageBridgeEnabled)
                row("Bridge Status", model.museCodeBridgeStatus ?? "Not posted yet")
                Text("Posts each session's new tokens since the last reading to Usage Monitor, as muse-code token events."
                    + sentenceGap
                    + "Replays dedupe server-side, so a failed post is safe to retry.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 170, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
