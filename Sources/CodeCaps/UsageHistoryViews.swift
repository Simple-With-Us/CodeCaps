import Charts
import QuotaCore
import SwiftUI

private enum HistorySpan: String, CaseIterable, Identifiable {
    case day = "24h"
    case week = "7d"

    var id: String { rawValue }
    var interval: TimeInterval { self == .day ? 86_400 : 7 * 86_400 }
}

private struct HistoryPoint: Identifiable {
    let id: String
    let series: String
    let windowLabel: String
    let observedAt: Date
    let remainingPercent: Double
    let reset: Bool
    let isVendorReset: Bool
}

/// Only persisted local samples are plotted.  Every quota window is a separate
/// series; a reset, account switch, or observation gap starts a new line.
struct UsageHistoryView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var state: ConsoleState
    let row: DisplaySection
    @State private var span: HistorySpan = .day
    @State private var samples: [AnomalyDetector.Sample] = []

    init(model: MonitorModel, state: ConsoleState, row: DisplaySection) {
        self.model = model
        self.state = state
        self.row = row
    }

    private var now: Date { model.now }
    private var start: Date { now.addingTimeInterval(-span.interval) }
    private var primaryWindows: [QuotaWindowSnapshot] {
        row.section.windows.filter { !$0.window.isSupplementaryVideoQuota }
    }
    private var windowIds: Set<String> { Set(primaryWindows.map { $0.window.id }) }
    private var focusedWindowId: String? {
        guard let id = state.selectedWindowId, windowIds.contains(id) else { return nil }
        return id
    }
    private var inspectedSnapshot: QuotaWindowSnapshot? {
        if let focusedWindowId {
            return primaryWindows.first { $0.window.id == focusedWindowId }
        }
        return row.driving
    }
    private var relevantSamples: [AnomalyDetector.Sample] {
        guard model.hasLocalHistorySource(for: row) else { return [] }
        return samples.filter { $0.providerKey == row.providerKey && windowIds.contains($0.windowId)
            && $0.observedAt >= start && $0.observedAt <= now
            && (focusedWindowId == nil || $0.windowId == focusedWindowId) }
    }
    private var points: [HistoryPoint] {
        let labelCounts = Dictionary(grouping: primaryWindows, by: { $0.window.label })
            .mapValues(\.count)
        let labels = primaryWindows.enumerated().reduce(into: [String: String]()) { labels, item in
            let (index, snapshot) = item
            let label = snapshot.window.label
            labels[snapshot.window.id] = (labelCounts[label] ?? 0) > 1
                ? "\(label) · \(snapshot.window.source ?? "Window") \(index + 1)" : label
        }
        let byWindow = Dictionary(grouping: relevantSamples, by: \.windowId)
        return byWindow.keys.sorted().flatMap { windowId in
            let segments = AnomalyDetector.historySegments(samples: byWindow[windowId] ?? [], now: now,
                                                           maxGap: 45 * 60)
            return segments.enumerated().flatMap { segmentIndex, segment in
                let sorted = segment.sorted { $0.observedAt < $1.observedAt }
                let earlier = segmentIndex == 0 ? nil : segments[segmentIndex - 1].last
                return sorted.enumerated().compactMap { index, sample -> HistoryPoint? in
                    guard let percent = sample.remainingPercent else { return nil }
                    let prevSample = index > 0 ? sorted[index - 1] : earlier
                    let reset = index == 0 && (earlier.map { previous in
                        (previous.resetAt.map { $0 > previous.observedAt && $0 <= sample.observedAt } ?? false)
                            || (previous.periodStart != nil && sample.periodStart != nil && previous.periodStart != sample.periodStart)
                    } ?? false)
                    let lastPercent = prevSample?.remainingPercent ?? 100.0
                    let midWindow = sample.resetAt.map { sample.observedAt < $0.addingTimeInterval(-60) } ?? true
                    let jumpedToFull = percent >= 99.5 && lastPercent < 98.0
                    let surgedMidWindow = lastPercent < 80.0 && percent >= 95.0
                    let quotaHandedBack = percent >= lastPercent + 30.0
                    let isVendorReset = midWindow && (jumpedToFull || surgedMidWindow || quotaHandedBack)
                    return HistoryPoint(id: "\(windowId):\(segmentIndex):\(index)",
                                        series: "\(windowId):\(segmentIndex)",
                                        windowLabel: labels[windowId] ?? "Quota Window",
                                        observedAt: sample.observedAt,
                                        remainingPercent: percent,
                                        reset: reset,
                                        isVendorReset: isVendorReset)
                }
            }
        }
    }
    private var alerts: [RunawayAlertRecord] {
        let rowCanonical = quotaProviderKey(row.providerKey, providerKey: row.providerKey)
        return model.runawayAlertHistory.filter { alert in
            let alertCanonical = quotaProviderKey(alert.providerKey, providerKey: alert.providerKey)
            let matchesProvider = alert.providerKey == row.providerKey || alertCanonical == rowCanonical
            return matchesProvider
                && windowIds.contains(alert.windowId)
                && (focusedWindowId == nil || alert.windowId == focusedWindowId)
                && alert.timestamp >= start && alert.timestamp <= now
        }
    }
    private var selectedAlert: RunawayAlertRecord? {
        guard let selected = state.selectedTimestamp else { return nil }
        let rowCanonical = quotaProviderKey(row.providerKey, providerKey: row.providerKey)
        return model.runawayAlertHistory.first { alert in
            let alertCanonical = quotaProviderKey(alert.providerKey, providerKey: alert.providerKey)
            let matchesProvider = alert.providerKey == row.providerKey || alertCanonical == rowCanonical
            return matchesProvider
                && (focusedWindowId == nil || alert.windowId == focusedWindowId)
                && abs(alert.timestamp.timeIntervalSince(selected)) < 2
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Usage History")
                        .font(.system(size: 16, weight: .semibold))
                    Text("\(row.title) · Quota remaining · local readings")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if primaryWindows.count > 1 {
                    Picker("Window", selection: Binding(
                        get: { focusedWindowId ?? "all" },
                        set: { (val: String) in
                            if val == "all" {
                                state.clearHistoryFocus()
                            } else {
                                state.selectWindow(val)
                            }
                        }
                    )) {
                        Text("All Windows").tag("all")
                        ForEach(primaryWindows, id: \.window.id) { snapshot in
                            Text(snapshot.window.label).tag(snapshot.window.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .font(.system(size: 11))
                    .frame(maxWidth: 160)
                    .accessibilityLabel("Filter Window")
                }
                Picker("History Range", selection: $span) {
                    ForEach(HistorySpan.allCases) { span in Text(span.rawValue).tag(span) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel("History Range")
                .frame(width: 118)
            }
            if let focusedWindowId {
                HStack {
                    Text("Filtered to: \(primaryWindows.first { $0.window.id == focusedWindowId }?.window.label ?? focusedWindowId)")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Button("Show All Windows") { state.clearHistoryFocus() }
                        .font(.system(size: 11))
                }
            }
            if !model.hasLocalHistorySource(for: row) {
                ContentUnavailableView {
                    Label("Local History Unavailable", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("The selected source has no matching local history." + sentenceGap
                         + "CodeCaps records usage history only for readings made on this Mac.")
                }
                .frame(minHeight: 190)
            } else if points.isEmpty {
                ContentUnavailableView {
                    Label("Collecting Usage History", systemImage: "chart.xyaxis.line")
                } description: {
                    Text("A line appears after CodeCaps records quota readings for this platform." + sentenceGap
                         + "Keep the app running to collect more readings.")
                }
                .frame(minHeight: 190)
            } else {
                Chart {
                    ForEach(points) { point in
                        LineMark(x: .value("Time", point.observedAt),
                                 y: .value("Remaining", point.remainingPercent),
                                 series: .value("Segment", point.series))
                            .foregroundStyle(by: .value("Window", point.windowLabel))
                            .interpolationMethod(.linear)
                            .accessibilityLabel("\(point.windowLabel), \(Int(point.remainingPercent.rounded())) percent remaining at \(point.observedAt.formatted())")
                        if point.isVendorReset {
                            PointMark(x: .value("Time", point.observedAt),
                                      y: .value("Remaining", point.remainingPercent))
                                .symbol(.square)
                                .symbolSize(45)
                                .foregroundStyle(Color.green)
                                .accessibilityLabel("\(point.windowLabel) vendor reset to \(Int(point.remainingPercent.rounded())) percent at \(point.observedAt.formatted())")
                        } else {
                            PointMark(x: .value("Time", point.observedAt),
                                      y: .value("Remaining", point.remainingPercent))
                                .symbol(point.reset ? .diamond : .circle)
                                .symbolSize(point.reset ? 40 : 10)
                                .foregroundStyle(by: .value("Window", point.windowLabel))
                                .accessibilityLabel(point.reset
                                    ? "\(point.windowLabel) reset at \(point.observedAt.formatted())"
                                    : "\(point.windowLabel), \(Int(point.remainingPercent.rounded())) percent at \(point.observedAt.formatted())")
                        }
                    }
                    ForEach(alerts) { alert in
                        RuleMark(x: .value("Alert", alert.timestamp))
                            .foregroundStyle(Theme.warning)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .accessibilityLabel("Runaway usage alert for \(alert.windowLabel) at \(alert.timestamp.formatted())")
                    }
                }
                .chartYScale(domain: 0...100)
                .chartXScale(domain: start...now)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { value in
                        AxisGridLine()
                        AxisValueLabel { if let percent = value.as(Int.self) { Text("\(percent)%") } }
                    }
                }
                .frame(height: 210)
                .accessibilityLabel("\(row.title) quota remaining over \(span.rawValue)")
                if points.count == 1 {
                    Text("One reading so far.  The trend will appear after another reading.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text("Each line is one quota window.  Gaps separate unobserved time, account changes, and new quota periods.  Diamonds mark scheduled resets; green squares mark mid-cycle vendor resets; orange lines mark runaway alerts.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Text("Burn stats are based on % of quota over time, unless absolute token data is available for the platform — in which case the detector prefers the absolute figures.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .multilineTextAlignment(.trailing)
            }
            if let inspectedSnapshot, !inspectedSnapshot.isFresh {
                Text(inspectedSnapshot.observedAt.map {
                    "This window last reported \($0.formatted(date: .abbreviated, time: .shortened))." + sentenceGap
                        + "The chart shows recorded history only."
                } ?? "This window's last report time is unavailable." + sentenceGap
                    + "The chart shows recorded history only.")
                    .font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
            if let selected = state.selectedTimestamp {
                if let alert = selectedAlert {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Runaway Alert · \(alert.timestamp.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: 12, weight: .semibold))
                        Text(alert.summary).font(.system(size: 11))
                        if let rate = alert.ratePercentPerHour,
                           let comparison = alert.comparisonRatePercentPerHour {
                            Text("Measured \(rate.formatted(.number.precision(.fractionLength(1)))) percentage points/hour; \(alert.comparison): \(comparison.formatted(.number.precision(.fractionLength(1)))) points/hour.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        if let coverage = alert.historyCoverageHours {
                            Text("Compared with \(coverage.formatted(.number.precision(.fractionLength(1)))) measured hours.")
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                } else {
                    Text("Selected alert: \(selected.formatted(date: .abbreviated, time: .shortened)).  Its saved detail is unavailable.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if selected < now.addingTimeInterval(-7 * 86_400) {
                    Text("This alert is older than the available 7-day history range.")
                        .font(.system(size: 11)).foregroundStyle(Theme.warning)
                }
            }
            if !alerts.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recent Alerts").font(.system(size: 11, weight: .semibold))
                    ForEach(alerts.prefix(3)) { alert in
                        Button("\(alert.windowLabel) · \(alert.timestamp.formatted(date: .abbreviated, time: .shortened)) · \(alert.multiplier.formatted(.number.precision(.fractionLength(1))))×") {
                            state.select(providerKey: row.id, windowId: alert.windowId,
                                         at: alert.timestamp, in: model.displaySections)
                        }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                    }
                }
            }
        }
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        .onAppear(perform: reload)
        .onChange(of: model.lastChecked) { _, _ in reload() }
        .onChange(of: row.id) { _, _ in reload() }
        .onChange(of: state.selectedTimestamp) { _, time in
            if let time, now.timeIntervalSince(time) > 86_400 { span = .week }
        }
    }

    private func reload() {
        samples = model.historySamples()
        if let time = state.selectedTimestamp, now.timeIntervalSince(time) > 86_400 { span = .week }
    }
}
