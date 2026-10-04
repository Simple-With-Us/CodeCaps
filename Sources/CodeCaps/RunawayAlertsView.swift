import AppKit
import QuotaCore
import SwiftUI

extension AnomalyDetector.Anomaly: Identifiable {
    public var id: String {
        "\(providerKey):\(windowId):\(kind.rawValue)"
    }
}

/// Dedicated in-app inspector for runaway usage anomaly alerts.
///
/// Gives the owner a permanent forensic record of every runaway alert
/// detected on this Mac: which provider, which quota window, the consumption
/// rate (% points/hr), the historical comparison (vs average or peak), and a
/// direct shortcut to inspect the live usage chart.
struct RunawayAlertsPage: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: ConsoleState
    @State private var showingClearConfirm = false

    private var summary: (sampleCount: Int, days: Double) {
        BurnRateMonitor.historySummary(now: model.now)
    }

    private var calibrationDescription: String {
        if summary.days >= 7.0 {
            return "Fully calibrated.  Evaluates current burn against your 7-day rolling average and worst peak hour."
        } else if summary.days >= 0.2 {
            return "Calibrated for peak alerts.  Collecting additional readings to calibrate your full 7-day average baseline."
        } else {
            return "Collecting baseline history.  CodeCaps records usage samples every refresh to establish your normal burn pattern."
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            headerSection
            calibrationCard

            if !model.activeRunawayAnomalies.isEmpty {
                activeAnomaliesSection
            }

            historySection
        }
        .confirmationDialog(
            "Clear Runaway Alert History?",
            isPresented: $showingClearConfirm,
            titleVisibility: .visible
        ) {
            Button("Clear All Alerts", role: .destructive) {
                model.clearRunawayAlertHistory()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all recorded runaway alert events from this Mac.  Sample history used for baseline calculations is preserved.")
        }
    }

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "flame.fill")
                .font(.system(size: 26))
                .foregroundStyle(model.activeRunawayAnomalies.isEmpty ? Theme.ink.opacity(0.8) : Theme.warning)
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Runaway Usage Alerts")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    if !model.activeRunawayAnomalies.isEmpty {
                        Text("ACTIVE SPIKE")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Theme.warning, in: Capsule())
                    }
                }
                Text("Autonomous monitoring that catches stuck loops and runaway token burn across all signed-in providers.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: - Calibration & Status

    private var calibrationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Anomaly Detector Status", systemImage: "speedometer")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("Configure Sensitivity") {
                    state.page = .settingsNotifications
                }
                .font(.system(size: 11))
                .controlSize(.small)
            }

            Divider()

            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Baseline Threshold")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f× average", model.anomalyBaselineMultiplier))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Peak Threshold")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f× peak hour", model.anomalyPeakMultiplier))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Sample Coverage")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("\(summary.sampleCount) samples · \(String(format: "%.1f", summary.days)) days")
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                }

                Spacer()
            }

            Text(calibrationDescription)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline, lineWidth: 1))
    }

    // MARK: - Active Anomalies

    private var activeAnomaliesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Currently Triggering Anomalies", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.warning)
                Spacer()
            }

            ForEach(model.activeRunawayAnomalies, id: \.id) { anomaly in
                activeAnomalyRow(anomaly)
            }
        }
    }

    private func activeAnomalyRow(_ anomaly: AnomalyDetector.Anomaly) -> some View {
        let matchingDisplayRow = model.displaySections.first { row in
            row.section.windows.contains { $0.window.id == anomaly.windowId }
        }
        let matchingSnapshot = model.displaySections.flatMap { $0.section.windows }
            .first { $0.window.id == anomaly.windowId }
            ?? model.sections.flatMap(\.windows).first { $0.window.id == anomaly.windowId }

        let providerTitle = matchingDisplayRow?.title
            ?? model.sections.first { $0.providerKey == anomaly.providerKey }?.providerLabel
            ?? anomaly.providerKey.capitalized

        let windowTitle: String
        if let matchingSnapshot {
            let raw = matchingSnapshot.window.label.trimmingCharacters(in: .whitespacesAndNewlines)
            windowTitle = raw.isEmpty ? glanceMeterCaption(matchingSnapshot) : raw
        } else {
            windowTitle = anomaly.windowId
        }

        let comparison = anomaly.kind == .vsPeak ? "measured peak" : "7-day average"
        let mult = anomaly.multiplier.formatted(.number.precision(.fractionLength(1)))

        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "flame.circle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Theme.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(providerTitle) · \(windowTitle)")
                    .font(.system(size: 13, weight: .semibold))
                HStack(spacing: 6) {
                    Text("\(mult)× \(comparison)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.warning)
                    if let rate = anomaly.ratePercentPerHour {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text("\(rate.formatted(.number.precision(.fractionLength(1)))) %/hr")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button("Inspect Live Chart") {
                state.select(providerKey: anomaly.providerKey,
                             windowId: anomaly.windowId,
                             at: anomaly.observedAt,
                             in: model.displaySections)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(Theme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.warning.opacity(0.3), lineWidth: 1))
    }

    // MARK: - History Section

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Alert Forensic History (\(model.runawayAlertHistory.count))", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                if !model.runawayAlertHistory.isEmpty {
                    Button("Clear History") {
                        showingClearConfirm = true
                    }
                    .font(.system(size: 11))
                    .controlSize(.small)
                }
            }

            if model.runawayAlertHistory.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 28))
                        .foregroundStyle(Theme.accent)
                    Text("No Runaway Alerts Recorded")
                        .font(.system(size: 13, weight: .semibold))
                    Text("When an AI CLI or provider begins consuming tokens significantly faster than your baseline, the full forensic record will appear here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 360)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline, lineWidth: 1))
            } else {
                ForEach(model.runawayAlertHistory) { alert in
                    alertRecordCard(alert)
                }
            }
        }
    }

    private func alertRecordCard(_ alert: RunawayAlertRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("\(alert.providerLabel) · \(alert.windowLabel)")
                            .font(.system(size: 13, weight: .semibold))
                        Text(String(format: "%.1f×", alert.multiplier))
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.warning)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Theme.warning.opacity(0.18), in: RoundedRectangle(cornerRadius: 4))
                    }
                    Text(alert.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text(alert.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)

                    Button("Inspect Chart") {
                        state.select(providerKey: alert.providerKey,
                                     windowId: alert.windowId,
                                     at: alert.timestamp,
                                     in: model.displaySections)
                    }
                    .font(.system(size: 11))
                    .controlSize(.mini)
                }
            }

            if let rate = alert.ratePercentPerHour,
               let comparisonRate = alert.comparisonRatePercentPerHour {
                HStack(spacing: 16) {
                    HStack(spacing: 4) {
                        Text("Burn Rate:")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("\(rate.formatted(.number.precision(.fractionLength(1)))) %/hr")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                    }

                    HStack(spacing: 4) {
                        Text("Comparison (\(alert.comparison)):")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text("\(comparisonRate.formatted(.number.precision(.fractionLength(1)))) %/hr")
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                    }

                    if let coverage = alert.historyCoverageHours {
                        HStack(spacing: 4) {
                            Text("Coverage:")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                            Text("\(coverage.formatted(.number.precision(.fractionLength(1)))) hrs")
                                .font(.system(size: 10, weight: .medium).monospacedDigit())
                        }
                    }

                    Spacer()
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}
