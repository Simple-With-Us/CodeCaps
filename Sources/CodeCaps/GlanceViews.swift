import AppKit
import QuotaCore
import SwiftUI

/// The status-item popover.  Read-only, one row per platform, plus three
/// affordances in the footer.  Glance never renders a `PlatformCard`; the
/// Console never renders a `GlanceRow`.
struct GlancePopover: View {
    @ObservedObject var model: MonitorModel
    var openConsole: (ConsolePage) -> Void
    /// Settings has its own entry point rather than a fixed page, so the gear
    /// and `⌘,` land in the same place: the Settings page last used.
    var openSettings: () -> Void

    /// Rows the owner has expanded inline.  Lives in the popover so it survives
    /// re-renders while the popover is open, and is cleared when the popover
    /// dismisses — persisting across launches would imply the popover remembers
    /// state about platforms that may not even be installed tomorrow.
    @State private var expandedIds: Set<String> = []

    private var localSections: [DisplaySection] { model.displaySections }
    private var fleetGroups: [FleetGroup] { model.fleetGroups }
    private var showsFleetSetup: Bool { !model.syncEnabled && !model.serverEnabled }
    private var hasAnySource: Bool { model.localEnabled || model.serverEnabled }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if hasAnySource {
                ScrollView { content.padding(.vertical, 8) }
                    .background(Theme.background)
            } else {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            }
            Divider()
            footer
        }
        .frame(width: Metrics.glanceWidth)
        .foregroundStyle(Theme.ink)
        .tint(Theme.accent)
        // The popover's own material is a vibrancy blur; the header and footer
        // need an opaque surface or they read as grey bars.
        .background(Theme.surface)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("CodeCaps").font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Text(headerStatus)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            // Auto-refresh fires every 5 min (see MonitorModel.refreshTimer) and
            // a 30-second clock ticks every time `now` updates, so the manual
            // button used to live in the footer for redundancy.  It now sits
            // top-right next to the time — icon-only, with the spinner replacing
            // it while a refresh is in flight.
            Button { model.refresh() } label: {
                if model.isRefreshing {
                    ProgressView().controlSize(.small).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .frame(width: 16, height: 16)
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(model.isRefreshing)
            .help("Refresh Quotas")
            .accessibilityLabel("Refresh Quotas")
        }
        .padding(.horizontal, Metrics.glanceGutter)
        .frame(height: Metrics.glanceHeaderHeight)
        .accessibilityElement(children: .combine)
    }

    /// Two literal ASCII spaces on either side of the dot — the fleet "two spaces
    /// between sentences" convention reads just as well between phrases inside a
    /// single string, so the header breathes without a heavier separator.
    private var headerStatus: String {
        let counted = "\(model.reportingCount) of \(model.sections.count)"
        guard let checked = model.lastChecked else { return counted }
        return "\(counted)  ·  \(checked.formatted(date: .omitted, time: .shortened))"
    }

    private func toggleExpanded(_ id: String) {
        if expandedIds.contains(id) {
            expandedIds.remove(id)
        } else {
            expandedIds.insert(id)
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            groupHeader("THIS MAC")
            ForEach(localSections) { row in
                GlanceRow(row: row,
                          now: model.now,
                          issue: model.issues[row.providerKey],
                          origin: .local,
                          markStyle: model.glanceMarkStyle(for: row.providerKey),
                          isAlarmArmed: model.isAlarmArmed(for: row.id),
                          isExpanded: expandedIds.contains(row.id),
                          onTap: { toggleExpanded(row.id) },
                          onToggleAlarm: { model.toggleAlarm(for: row.id) })
            }
            if !fleetGroups.isEmpty {
                Spacer().frame(height: 12)
                HStack(alignment: .top, spacing: 0) {
                    Rectangle().fill(Theme.fleet)
                        .frame(width: 2)
                    VStack(alignment: .leading, spacing: 0) {
                        // One header per machine, so a row always says which
                        // machine reported it.
                        ForEach(fleetGroups) { group in
                            groupHeader("FLEET · \(group.title.uppercased())")
                            ForEach(group.rows) { row in
                                GlanceRow(row: row,
                                          now: model.now,
                                          issue: nil,
                                          origin: .fleet,
                                          markStyle: model.glanceMarkStyle(for: row.providerKey),
                                          isAlarmArmed: model.isAlarmArmed(for: row.id),
                                          isExpanded: expandedIds.contains(row.id),
                                          onTap: { toggleExpanded(row.id) },
                                          onToggleAlarm: { model.toggleAlarm(for: row.id) })
                            }
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let consentMessage {
                Spacer().frame(height: 10)
                ConsentRow(message: consentMessage) { openConsole(.settingsSourcesFleet) }
                    .padding(.horizontal, Metrics.glanceGutter)
            }
            if showsFleetSetup {
                Spacer().frame(height: 12)
                FleetSetupRow { openConsole(.settingsSourcesFleet) }
                    .padding(.horizontal, Metrics.glanceGutter)
            }
        }
    }

    /// The short issue text for a reader whose saved login is on this Mac but
    /// unreadable until the owner allows this build once.  Glance is the
    /// surface that actually gets opened, so it has to say so.
    private var consentMessage: String? {
        model.consentNeeded.sorted().compactMap { model.issues[$0] }.first
    }

    private func groupHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(height: Metrics.glanceGroupHeaderHeight, alignment: .leading)
            .padding(.horizontal, Metrics.glanceGutter)
            .accessibilityAddTraits(.isHeader)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
            Text("No quota report yet")
                .font(.system(size: 13, weight: .semibold))
            Text("Turn on local readers or connect a fleet server.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(Metrics.glanceGutter)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Button { openSettings() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help("Settings")
            .accessibilityLabel("Settings")

            Spacer(minLength: 4)

            Button { openConsole(.allPlatforms) } label: {
                HStack(spacing: 5) {
                    Text("Open CodeCaps")
                    Text("⌘1").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.borderedProminent)
            .help("Open CodeCaps")
            .accessibilityLabel("Open CodeCaps")
        }
        .padding(.horizontal, Metrics.glanceGutter)
        .frame(height: Metrics.glanceFooterHeight)
    }
}

/// One platform, one line.  The only compact row type in the app.
struct GlanceRow: View {
    let row: DisplaySection
    let now: Date
    let issue: String?
    let origin: QuotaOrigin
    let markStyle: MarkStyle
    var isAlarmArmed: Bool = false
    /// Whether the inline expansion is shown below this row.  Driven by the
    /// popover's `expandedIds` set, threaded down here so the chevron and the
    /// detail list animate together.
    var isExpanded: Bool = false
    /// Tap handler for the row's body — opening or closing the expansion.
    /// Alarm-arm toggles short-circuit the gesture so a stray tap on the bell
    /// never expands a row.
    var onTap: (() -> Void)? = nil
    var onToggleAlarm: (() -> Void)? = nil

    private var section: QuotaPlatformSection { row.section }

    /// The window the row speaks for: the one closest to its cap, ignoring any
    /// window whose percentage cannot mean anything.
    private var driving: QuotaWindowSnapshot? { row.driving }

    private var percent: Double? {
        issue == nil ? row.remainingPercent : nil
    }

    private var tint: Color {
        guard let driving, issue == nil else { return .secondary }
        return quotaStatusColor(for: driving, sourceFailed: false)
    }

    private var isLive: Bool { issue == nil && section.hasFreshReport }

    /// The trailing column is 64pt wide, or 112pt with no percentage, and one
    /// line tall.  A reader's issue is a sentence or two, so the column carries
    /// a token and the sentence goes to the tooltip and the spoken value.
    private var trailingText: String {
        if percent != nil {
            let countdown = glanceResetCountdown(row.resetAt ?? driving?.resetAt, now: now)
            return countdown.isEmpty ? "no reset time" : countdown
        }
        if let issue {
            if issue == ClaudeLoginState.idle.issue { return "login idle" }
            if issue.localizedCaseInsensitiveContains("permission") { return "needs permission" }
            return issue.localizedCaseInsensitiveContains("sign in") ? "not signed in" : "unavailable"
        }
        return section.windows.isEmpty ? "no report" : "not signed in"
    }

    private var attribution: String? {
        guard origin == .fleet else { return nil }
        let source = driving?.window.source?.trimmingCharacters(in: .whitespacesAndNewlines)
        let observed = driving?.observedAt.map { "reported \($0.formatted(date: .omitted, time: .shortened))" }
        let parts = [source, observed].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                PlatformLogo(providerKey: section.providerKey, size: 16, style: markStyle)
                    .frame(width: 16, height: 16)
                Spacer().frame(width: 6)
                VStack(alignment: .leading, spacing: 1) {
                    // An Antigravity row names its pool, which does not fit beside
                    // the platform in a 136pt column, so the pool takes the second
                    // line rather than being truncated away.
                    Text(row.poolTitle == nil ? row.title : row.platformTitle)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle = [row.poolTitle, attribution].compactMap({ $0 }).first {
                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                            .truncationMode(.tail)
                    }
                }
                .frame(width: 136, alignment: .leading)
                Spacer().frame(width: 8)
                bar
                    .frame(width: 56, height: 3)
                Spacer().frame(width: 8)
                if percent != nil || driving?.remainingPercent != nil {
                    Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(tint)
                        // Hardening: the popover sits 40–48pt above the menu bar,
                        // and an HStack's flexible space can squeeze a fixed-width
                        // frame down a couple of points on a re-layout.  Belt and
                        // braces — lineLimit keeps the text to one row, minScale
                        // shrinks instead of clipping, and fixedSize blocks the
                        // HStack from compressing the column.
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: 48, alignment: .trailing)
                    Spacer().frame(width: 8)
                    trailingColumn
                        .frame(width: 64, alignment: .trailing)
                } else {
                    trailingColumn
                        .frame(width: 112, alignment: .trailing)
                }
                Spacer().frame(width: 6)
                // Chevron on the rightmost edge signals click-to-expand without
                // claiming space from any of the value columns.  Rotates 180°
                // when the row is expanded.
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 10)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Metrics.glanceGutter)
            .frame(height: origin == .fleet ? Metrics.glanceFleetRowHeight : Metrics.glanceLocalRowHeight)
            .contentShape(Rectangle())
            .onTapGesture { onTap?() }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(row.title)
            .accessibilityValue(spokenValue)
            .accessibilityHint(isExpanded ? "Double-tap to collapse." : "Double-tap to expand.")
            .help(issue ?? row.title)
            if isExpanded { expandedSection.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }

    @ViewBuilder
    private var trailingColumn: some View {
        HStack(spacing: 4) {
            if isAlarmArmed {
                Button {
                    onToggleAlarm?()
                } label: {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
                .help("Reset alarm is armed." + sentenceGap + "Click to disarm.")
                .accessibilityLabel("Disarm reset alarm")
            } else if (percent != nil && percent! <= 0) && onToggleAlarm != nil {
                Button {
                    onToggleAlarm?()
                } label: {
                    Image(systemName: "bell")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Arm alarm when quota resets and all caps clear.")
                .accessibilityLabel("Arm reset alarm")
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(trailingText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if origin == .fleet {
                    StatusBadge(kind: .fleet)
                }
            }
        }
    }

    /// Inline expansion: every quota window the local reader (or the fleet pull)
    /// has for this provider, one row each, with label · percent remaining ·
    /// reset countdown.  Mirrors what the Console cards show, minus the chart —
    /// the popover stays readable at 376pt wide.
    @ViewBuilder
    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(row.section.windows.enumerated()), id: \.offset) { _, snapshot in
                HStack(spacing: 8) {
                    Text(AntigravityDisplay.windowLabel(snapshot.window.label))
                        .font(.system(size: 11))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    Text(snapshot.remainingPercent.map { "\(Int(($0).rounded()))%" } ?? "—")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                    Text(glanceResetCountdown(snapshot.resetAt, now: now))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 56, alignment: .trailing)
                }
                .padding(.trailing, 22)
            }
        }
        .padding(.leading, 22 + Metrics.glanceGutter)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.55))
    }

    private var bar: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                if let percent {
                    Capsule().fill(tint)
                        .frame(width: geometry.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
                }
            }
        }
        .clipShape(Capsule())
    }

    private var spokenValue: String {
        var parts: [String] = []
        if let percent { parts.append("\(Int(percent.rounded())) percent remaining") }
        else { parts.append("no reading") }
        if let reset = row.resetAt ?? driving?.resetAt, percent != nil {
            parts.append(resetCountdown(reset, now: now).lowercased())
        }
        switch origin {
        case .fleet: parts.append("from the fleet")
        case .local: parts.append(isLive ? "live" : "last report")
        }
        if let issue { parts.append(issue) }
        return parts.joined(separator: ", ")
    }
}

/// Shown below the platform list when a reader's saved login is present on
/// this Mac but unreadable until the owner allows this build once.  The button
/// deep-links to Sources & Fleet, where the one-time step lives.
struct ConsentRow: View {
    let message: String
    var action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.circle")
                .font(.system(size: 16))
                .foregroundStyle(Theme.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(message)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Settings", action: action)
                    .controlSize(.small)
                    .help("Open Settings")
                    .accessibilityLabel("Open Settings")
            }
            Spacer(minLength: 4)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.warning.opacity(0.35)))
    }
}

/// Shown below the platform list whenever neither push nor pull is configured.
/// Glance is the surface that actually gets opened, so this is where fleet sync
/// has to announce itself.
struct FleetSetupRow: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.up.arrow.down.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(Theme.fleet)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set Up Fleet Sync")
                        .font(.system(size: 13, weight: .medium))
                    Text("Share this Mac's quota, or show your other machines here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(minHeight: Metrics.glanceCTARowHeight)
            .frame(maxWidth: .infinity)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.fleet.opacity(0.4)))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .help("Set Up Fleet Sync")
        .accessibilityLabel("Set Up Fleet Sync")
    }
}

/// Reset countdown without the "Resets in" prefix, for a 58pt column.
func glanceResetCountdown(_ reset: Date?, now: Date) -> String {
    guard let reset else { return "" }
    let seconds = reset.timeIntervalSince(now)
    guard seconds > 0 else { return "due" }
    let minutes = max(1, Int(ceil(seconds / 60)))
    if minutes >= 1440 { return "\(minutes / 1440)d \((minutes % 1440) / 60)h" }
    if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
    return "\(minutes)m"
}
