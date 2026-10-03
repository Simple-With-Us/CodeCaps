import AppKit
import QuotaCore
import SwiftUI

/// The status-item popover.  Read-only, one row per platform, plus three
/// affordances in the footer.  Glance never renders a `PlatformCard`; the
/// Console never renders a `GlanceRow`.
///
/// The header is one line on one centre line: the name, then the From Mac /
/// From Fleet switch, and on the right the All reset-alarm bell, the count, the
/// time and the refresh button — "All • 6 of 7 • 4:27 PM".  `GlanceHeaderBar`
/// lays it out.
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
    @State private var expandedIds: Set<String>

    /// `initiallyExpanded` exists for the PNG render test, which has no pointer
    /// to click a row with.
    init(model: MonitorModel,
         openConsole: @escaping (ConsolePage) -> Void,
         openSettings: @escaping () -> Void,
         initiallyExpanded: Set<String> = []) {
        self.model = model
        self.openConsole = openConsole
        self.openSettings = openSettings
        _expandedIds = State(initialValue: initiallyExpanded)
    }

    private var localSections: [DisplaySection] { model.displaySections }
    private var fleetGroups: [FleetGroup] { model.fleetGroups }
    private var showsFleetSetup: Bool { !model.syncEnabled && !model.serverEnabled }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { content.padding(.vertical, Metrics.glanceListPadding) }
                .background(Theme.background)
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
        GlanceHeaderBar(view: $model.glanceView,
                        alarmsAll: $model.alarmsAll,
                        parts: headerParts,
                        isRefreshing: model.isRefreshing,
                        refresh: { model.refresh() })
    }

    /// "6 of 7" and "4:27 PM", live: the count and the time of the last read.
    private var headerParts: [String] {
        glanceHeaderParts(view: model.glanceView,
                          reporting: model.reportingCount,
                          total: model.sections.count,
                          sources: fleetGroups.count,
                          checked: headerChecked)
    }

    private var headerChecked: Date? {
        model.glanceView == .fromFleet ? (model.lastPullTime ?? model.lastChecked) : model.lastChecked
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
        switch model.glanceView {
        case .fromMac: fromMacContent
        case .fromFleet: fleetContent
        }
    }

    @ViewBuilder
    private var fromMacContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if localSections.isEmpty && !model.localEnabled {
                GlanceEmptyState(
                    symbol: "laptopcomputer",
                    title: "Local readers are off",
                    message: "This Mac is not reading any AI plan right now." + sentenceGap
                        + "Turn local readers on in Settings to see them here.",
                    actionTitle: "Open Settings") { openConsole(.settingsSourcesFleet) }
            } else {
                ForEach(Array(localSections.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        rowDivider
                    }
                    glanceRow(row, issue: model.issues[row.providerKey], origin: .local)
                }
            }
            if let consentMessage {
                Spacer().frame(height: 10)
                ConsentRow(message: consentMessage) { openConsole(.settingsSourcesFleet) }
                    .padding(.horizontal, Metrics.glanceGutter)
            }
            if showsFleetSetup {
                Spacer().frame(height: Metrics.glanceSetupGap)
                FleetSetupRow { openConsole(.settingsSourcesFleet) }
                    .padding(.horizontal, Metrics.glanceGutter)
            }
        }
    }

    @ViewBuilder
    private var fleetContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            if fleetGroups.isEmpty {
                if model.serverEnabled {
                    GlanceEmptyState(
                        symbol: "arrow.down.circle",
                        title: "No fleet readings yet",
                        message: model.serverError
                            ?? ("Your fleet endpoint has not reported any readings yet." + sentenceGap
                                + "Readings appear here after the next pull."),
                        actionTitle: "Open Fleet Settings") { openConsole(.settingsSourcesFleet) }
                } else {
                    GlanceEmptyState(
                        symbol: "arrow.up.arrow.down.circle",
                        title: "No fleet endpoint connected",
                        message: "From Fleet shows the quotas your other machines push to an endpoint you run."
                            + sentenceGap + "Add the endpoint and its Read Token in Settings to connect it.",
                        actionTitle: "Connect Fleet Endpoint") { openConsole(.settingsSourcesFleet) }
                }
            } else {
                // One heading band per reporting source, so a row always says
                // who reported it without a per-row badge.  The toggle already
                // says these are fleet rows, so "FLEET" is never repeated.
                ForEach(Array(fleetGroups.enumerated()), id: \.element.id) { groupIndex, group in
                    if groupIndex > 0 {
                        Spacer().frame(height: Metrics.glanceGroupGap)
                    }
                    groupHeader(group)
                    ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 {
                            rowDivider
                        }
                        glanceRow(row, issue: nil, origin: .fleet, expansionKey: "\(group.id)|\(row.id)")
                    }
                }
            }
        }
    }

    private func glanceRow(_ row: DisplaySection, issue: String?, origin: QuotaOrigin,
                           expansionKey: String? = nil) -> some View {
        let key = expansionKey ?? row.id
        return GlanceRow(row: row,
                         now: model.now,
                         issue: issue,
                         origin: origin,
                         markStyle: model.glanceMarkStyle(for: row.id),
                         showsAlarmToggle: !model.alarmsAll,
                         isAlarmEnabled: model.isProviderAlarmSelected(row.id),
                         allowsExpansion: origin == .fleet && glanceRowAllowsExpansion(row, origin: origin),
                         isExpanded: expandedIds.contains(key),
                         onTap: { toggleExpanded(key) },
                         onToggleAlarm: { model.toggleAlarm(for: row.id) })
    }

    /// "REPORTED 9:12 AM": the source's latest reading, on the right of its
    /// heading band.  The time lives here rather than under every row, where
    /// it truncated.
    private func fleetGroupReported(_ group: FleetGroup) -> String? {
        let latest = group.rows.flatMap(\.section.windows).compactMap(\.observedAt).max()
        return latest.map { "REPORTED \($0.formatted(date: .omitted, time: .shortened).uppercased())" }
    }

    /// The short issue text for a reader whose saved login is on this Mac but
    /// unreadable until the owner allows this build once.  Glance is the
    /// surface that actually gets opened, so it has to say so.
    private var consentMessage: String? {
        model.consentNeeded.sorted().compactMap { model.issues[$0] }.first
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: Metrics.glanceDividerHeight)
            .padding(.horizontal, Metrics.glanceGutter)
    }

    /// A source's heading: its name in small caps on a band darker than the
    /// list, full width, with the time of its latest reading on the right.
    private func groupHeader(_ group: FleetGroup) -> some View {
        HStack(spacing: 8) {
            Text(glanceFleetGroupHeading(group.title))
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.groupBandLabel)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let reported = fleetGroupReported(group) {
                // Italic, per the owner: the reported time is provenance for
                // the band above it, not a second heading.  Italic separates
                // it from the source name at a glance without dropping the
                // semibold weight it needs to stay legible at 9pt on a band.
                Text(reported)
                    .font(.system(size: 9, weight: .semibold).monospacedDigit())
                    .italic()
                    .tracking(0.6)
                    .foregroundStyle(Theme.groupBandLabel)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, Metrics.glanceGutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Metrics.glanceGroupHeaderHeight)
        .background(Theme.groupBand)
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

/// The count and time on the right of the header.  From Mac counts the
/// providers reporting; From Fleet counts the sources that reported them.
///
/// A source, not a machine: the fleet pull groups readings by the collector or
/// app that reported them (`FleetOrigin.identity`), and that is a machine only
/// some of the time.
///
/// The phrases are returned apart: the header sets a dot between them at a fixed
/// gap, and VoiceOver reads them with commas.  Either is left out when there is
/// nothing to say.
func glanceHeaderParts(view: GlanceViewMode, reporting: Int, total: Int, sources: Int, checked: Date?) -> [String] {
    let counted: String?
    switch view {
    case .fromMac:
        counted = "\(reporting) of \(total)"
    case .fromFleet:
        // With no source to count, the empty list below already says why.
        counted = sources == 0 ? nil : (sources == 1 ? "1 source" : "\(sources) sources")
    }
    let time = checked.map { $0.formatted(date: .omitted, time: .shortened) }
    return [counted, time].compactMap { $0 }
}

/// A source's heading in From Fleet: its name as reported, in capitals —
/// "CHATGPT.COM", "MAC MINI".  A source that names nothing (no `source`, no
/// `sourceApp`, or a name of only dashes and spaces) gets a plain label rather
/// than a blank band or a bare "FLEET", which the switch above already says.
func glanceFleetGroupHeading(_ title: String) -> String {
    let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty || name.lowercased() == "fleet" { return "UNNAMED SOURCE" }
    return name.uppercased()
}

// MARK: - Header controls

/// The header's one line.
///
///     CodeCaps   [ From Mac | From Fleet ]  . . .  [bell] All • 6 of 7 • 4:27 PM  [reload]
///
/// Every control is `Metrics.glanceHeaderControlHeight` tall and centred on the
/// header's own centre line, so the title, the switch, the bell, the text and
/// the refresh button all sit on one line.  The horizontal rhythm is three
/// fixed gaps and one flexible one: `glanceHeaderTitleGap` between the title
/// and the switch, `glanceHeaderItemGap` between neighbours in the right-hand
/// cluster, and a spring between the two groups that is never narrower than
/// `glanceHeaderClusterGap`.  A wider count or time ("12 of 12", "12:59 PM",
/// "2 sources") only takes space from the spring.
struct GlanceHeaderBar: View {
    @Binding var view: GlanceViewMode
    @Binding var alarmsAll: Bool
    /// The count and the time ("6 of 7", "4:27 PM"); either may be missing.
    let parts: [String]
    let isRefreshing: Bool
    var refresh: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Text("CodeCaps")
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(1)
                .fixedSize()
            Spacer().frame(width: Metrics.glanceHeaderTitleGap)
            GlanceViewToggle(selection: $view)
            Spacer(minLength: Metrics.glanceHeaderClusterGap)
            HStack(spacing: Metrics.glanceHeaderItemGap) {
                GlanceAlarmAllToggle(isOn: $alarmsAll)
                if !parts.isEmpty { status }
                refreshButton
            }
        }
        .padding(.horizontal, Metrics.glanceGutter)
        .frame(height: Metrics.glanceHeaderHeight)
    }

    /// The count and the time, each after a dot.  The dots are for the eye;
    /// VoiceOver would say "bullet", so it gets the phrases with commas.
    private var status: some View {
        HStack(spacing: Metrics.glanceHeaderItemGap) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                Circle()
                    .fill(Theme.faint)
                    .frame(width: Metrics.glanceHeaderDotSize, height: Metrics.glanceHeaderDotSize)
                Text(part)
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .frame(height: Metrics.glanceHeaderControlHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(parts.joined(separator: ", "))
    }

    /// Auto-refresh fires every 5 min (see MonitorModel.refreshTimer) and a
    /// 30-second clock ticks every time `now` updates, so the manual button
    /// used to live in the footer for redundancy.  It sits top-right next to
    /// the time — icon-only, with the spinner replacing it while a refresh is
    /// in flight.
    private var refreshButton: some View {
        Button(action: refresh) {
            Group {
                if isRefreshing {
                    ProgressView().controlSize(.small).frame(width: 14, height: 14)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .frame(width: 16, height: Metrics.glanceHeaderControlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .disabled(isRefreshing)
        .help("Refresh Quotas")
        .accessibilityLabel("Refresh Quotas")
    }
}

/// The two-box switch between From Mac and From Fleet, in Title Case.  The two
/// boxes are the same width, so the switch does not change shape as it flips.
struct GlanceViewToggle: View {
    @Binding var selection: GlanceViewMode

    /// The label that sets both boxes' width.
    private static let widest = GlanceViewMode.allCases.map(\.title).max { $0.count < $1.count } ?? ""

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(GlanceViewMode.allCases.enumerated()), id: \.element) { index, mode in
                if index > 0 {
                    Rectangle()
                        .fill(Theme.controlBorder)
                        .frame(width: 1, height: Metrics.glanceHeaderControlHeight)
                }
                segment(mode)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.controlBorder))
        .fixedSize()
    }

    private func segment(_ mode: GlanceViewMode) -> some View {
        let selected = selection == mode
        return Button { selection = mode } label: {
            ZStack {
                // Invisible, and not read by VoiceOver: it only holds the box
                // open to the width of the longer label.
                Text(Self.widest).hidden()
                Text(mode.title)
            }
            .font(.system(size: 11, weight: .semibold))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, Metrics.glanceHeaderSegmentPadding)
            .frame(height: Metrics.glanceHeaderControlHeight)
            .background(selected ? Theme.selection : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode.detail)
        .accessibilityLabel(mode.title)
        .accessibilityHint(mode.detail)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The header's bell and "All": every provider's reset alarm on, or picked one
/// by one with the faint bell at the left of each row.  It sits inline with
/// the count and the time, so it is drawn as text rather than a boxed control.
///
/// "All" is Title Case, like the switch beside it; it used to be "ALL", which
/// shouted next to two Title Case labels.
struct GlanceAlarmAllToggle: View {
    @Binding var isOn: Bool

    private var helpText: String {
        if isOn {
            return "Reset alarms are on for every provider." + sentenceGap + "Click to choose providers one by one."
        }
        return "Reset alarms are chosen per provider." + sentenceGap + "Click to turn them on for every provider."
    }

    private var tint: AnyShapeStyle {
        isOn ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary)
    }

    private var label: some View {
        HStack(spacing: 4) {
            Image(systemName: isOn ? "bell.fill" : "bell")
                .font(.system(size: 11, weight: .semibold))
            Text("All")
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(tint)
        .frame(height: Metrics.glanceHeaderControlHeight)
        .contentShape(Rectangle())
        .fixedSize()
    }

    var body: some View {
        Button { isOn.toggle() } label: { label }
            .buttonStyle(.plain)
            .help(helpText)
            .accessibilityLabel("All Reset Alarms")
            .accessibilityValue(isOn ? "on" : "off")
            .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

/// A short explanation and one button, in place of an empty list.
struct GlanceEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    let actionTitle: String
    var action: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            Button(actionTitle, action: action)
                .controlSize(.small)
                .padding(.top, 2)
                .help(actionTitle)
                .accessibilityLabel(actionTitle)
        }
        .padding(.horizontal, Metrics.glanceGutter)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - The two meters a compact row carries

/// The pair of quota windows a one-line Glance row shows side by side: the
/// short cadence that reopens sooner, and the long cadence that caps the
/// subscription.  The owner reads both from the popover without expanding.
struct GlanceMeterPair: Equatable {
    var short: QuotaWindowSnapshot?
    var long: QuotaWindowSnapshot?
}

/// Which side of the pair a window belongs to.  Named after cadence length
/// rather than a provider, because every provider that publishes two meters
/// splits the same way: Claude's 5h/7d, Antigravity's 5h/weekly, MiniMax's
/// interval/weekly.
enum GlanceCadence: Equatable {
    case short
    case long
}

/// The two windows a one-line row meters, chosen the way the rest of the app
/// picks the window a row "speaks for": the one closest to its cap within its
/// own cadence.
///
/// The pairing is deliberately not "first and second window in the array".
/// Antigravity hands back a 5h and a weekly per pool, MiniMax hands back a
/// per-model interval and weekly pair, and a row scoped to one pool still has
/// to end up with one of each.
///
/// Windows Antigravity masks — a 5h percentage reported under an exhausted
/// weekly cap — are excluded, because the whole point of a second meter is
/// that you can trust it.  If that leaves nothing, the row's own driving
/// window is used so the row never renders blank.
func glanceMeterPair(for row: DisplaySection, now: Date) -> GlanceMeterPair {
    let trustworthy = glanceDrawableWindows(row.section.windows.filter {
        !$0.window.isSupplementaryVideoQuota && !row.isMasked($0)
    })
    let candidates = trustworthy.isEmpty
        ? [row.driving].compactMap { $0 }
        : trustworthy
    guard let anchor = candidates.first else { return GlanceMeterPair() }

    let shortest = candidates.filter { glanceCadence($0, now: now) == .short }
    let longest = candidates.filter { glanceCadence($0, now: now) == .long }

    // A provider that publishes only one cadence — Grok Bot's weekly meter, or
    // a plan-only subscription — still fills the first slot.  The second slot
    // then falls back to the next window closest to its cap, so a provider
    // with two unnamed windows still gets two meters.
    let short = nearestToCap(shortest) ?? nearestToCap(candidates) ?? anchor
    // Both fallbacks exclude the window the first slot already took, and any
    // copy of it.  A single-window provider that classifies as long — which
    // every weekly meter does — would otherwise resolve `longest` to the same
    // snapshot and render one meter twice, hiding the second cadence entirely;
    // and a second source's copy of the same meter (Grok Bot's weekly, read
    // by both Cursor's DashboardService and `gbu`) would render it twice more.
    func distinct(_ snapshot: QuotaWindowSnapshot) -> Bool {
        snapshot.window.id != short.window.id && !glanceIsCopy(snapshot, of: short)
    }
    let long = nearestToCap(longest.filter(distinct))
        ?? nearestToCap(candidates.filter(distinct))
    return GlanceMeterPair(short: short, long: long)
}

/// The meter a window is: what it measures and how often it resets, the same
/// for a window and for another source's report of it.
private func glanceMeterKey(_ snapshot: QuotaWindowSnapshot) -> String {
    glanceLineLabel(snapshot) + "|" + glanceMeterCaption(snapshot)
}

/// Whether `snapshot` is another source's report of the meter `other` already
/// shows.  Only a different source counts: two windows from one source that
/// share a label and a cadence are two windows.
///
/// And only a report of the same allowance counts (`glanceSameAllowance`): two
/// accounts of one provider read by two sources, both labelled "Grok Bot
/// weekly", are two meters.
private func glanceIsCopy(_ snapshot: QuotaWindowSnapshot, of other: QuotaWindowSnapshot) -> Bool {
    glanceMeterKey(snapshot) == glanceMeterKey(other)
        && (snapshot.window.source ?? "") != (other.window.source ?? "")
        && glanceSameAllowance(snapshot, other)
}

/// Whether two readings of one meter could be the same allowance read twice,
/// rather than two accounts' allowances.  Readers of one allowance agree on
/// when it resets, to within the seconds between their reads, and on how much
/// is left, to within a point of drift between them.  A fact one side leaves
/// out cannot tell them apart, so it does not.
private func glanceSameAllowance(_ lhs: QuotaWindowSnapshot, _ rhs: QuotaWindowSnapshot) -> Bool {
    if let left = lhs.window.accountKey, let right = rhs.window.accountKey, left != right { return false }
    if let left = lhs.resetAt, let right = rhs.resetAt, abs(left.timeIntervalSince(right)) > 120 { return false }
    if let left = lhs.remainingPercent, let right = rhs.remainingPercent, abs(left - right) > 2 { return false }
    return true
}

/// The windows a row may draw as a bar.  A window with no reading is a bar with
/// nothing in it, so it is only drawn when it is the only word on its meter:
///
/// - it is dropped when another window of the same meter (what it measures and
///   its cadence: `glanceMeterKey`) has a reading, because the reading already
///   speaks for that meter; and
/// - when none has, one stands for them all, so an empty bar is never drawn
///   twice.
///
/// A provider-wide window (one that names no model) that also names no cadence
/// of its own ("Quota", "Plan") is dropped when any window has a reading.
/// Everything with a reading is kept, in order.
///
/// The meter is the model and cadence, not the cadence alone: a model that
/// returned no weekly reading stays visible beside another model's weekly one.
///
/// This is what removed Grok Bot's stray empty "7d" bar: its `gbu` reader
/// emits a no-reading "Grok Bot weekly" window whenever the CLI cannot read,
/// beside DashboardService's real reading of the same weekly allowance.
func glanceDrawableWindows(_ windows: [QuotaWindowSnapshot]) -> [QuotaWindowSnapshot] {
    let readingKeys = Set(windows.filter { $0.remainingPercent != nil }.map(glanceMeterKey))
    var emptyKeys: Set<String> = []
    return windows.filter { snapshot in
        guard snapshot.remainingPercent == nil else { return true }
        let key = glanceMeterKey(snapshot)
        let caption = glanceMeterCaption(snapshot)
        let namesNoCadence = (caption == "Quota" || caption == "Plan")
            && (snapshot.window.modelId ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if readingKeys.contains(key) || (namesNoCadence && !readingKeys.isEmpty) { return false }
        return emptyKeys.insert(key).inserted
    }
}

/// The window closest to its cap, preferring one that reports a percentage.
/// Same rule as `QuotaPlatformSection.drivingWindow`, so the second meter and
/// the row's headline always agree on which window is closest to trouble.
private func nearestToCap(_ pool: [QuotaWindowSnapshot]) -> QuotaWindowSnapshot? {
    pool.filter { $0.remainingPercent != nil }
        .min { ($0.remainingPercent ?? 100) < ($1.remainingPercent ?? 100) }
        ?? pool.first
}

/// A window's cadence, from its own token where the reader set one, and from
/// how long until it resets otherwise.  A window with neither — an unknown
/// bucket, a plan meter with no end date — is `.long`: a subscription-wide
/// allowance is the long side of the pair far more often than the short one.
func glanceCadence(_ snapshot: QuotaWindowSnapshot, now: Date) -> GlanceCadence {
    let token = (snapshot.window.window ?? "")
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let seconds = glanceDurationSeconds(token) {
        return seconds < 86_400 ? .short : .long
    }
    switch token {
    case "session", "fast": return .short
    case "weekly", "week", "monthly", "month", "plan", "included plan": return .long
    default: break
    }
    if let reset = snapshot.resetAt, reset > now {
        return reset.timeIntervalSince(now) < 86_400 ? .short : .long
    }
    return .long
}

/// The unit tag beside a meter: "5h", "7d", "1m".  Kept to five characters so
/// the caption column never has to truncate, and derived from the window's own
/// cadence token rather than its label alone, because a label is allowed to be
/// "Third-Party · Weekly" while its caption has to be "7d".
///
/// Every monthly or billing-cycle window reads "1m" — Cursor's included plan
/// among them — so a month is spelled one way on every row (owner ruling
/// 2026-09-30, replacing "Plan" and "30d").
func glanceMeterCaption(_ snapshot: QuotaWindowSnapshot) -> String {
    let token = (snapshot.window.window ?? "")
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let seconds = glanceDurationSeconds(token) {
        return glanceDurationTag(seconds)
    }
    if glanceIsMonthly(snapshot) { return "1m" }
    let named = token + " " + snapshot.window.label.lowercased()
    if named.contains("weekly") || named.contains("7-day") { return "7d" }
    if named.contains("5-hour") || named.contains("5 hour") { return "5h" }
    if named.contains("daily") { return "24h" }
    if named.contains("plan") || named.contains("quota") { return "Plan" }
    return "Quota"
}

/// Whether a window resets once a month: a monthly token or label, a billing
/// cycle, a 28-31 day duration, or Cursor's included plan, which resets with
/// Cursor's monthly billing cycle and carries no cadence of its own.
func glanceIsMonthly(_ snapshot: QuotaWindowSnapshot) -> Bool {
    let token = (snapshot.window.window ?? "")
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let seconds = glanceDurationSeconds(token) {
        return (27 * 86_400...31 * 86_400).contains(seconds)
    }
    let named = token + " " + snapshot.window.label.lowercased()
    if named.contains("month") || named.contains("billing") || named.contains("cycle") { return true }
    return snapshot.window.canonicalProviderKey == "cursor" && named.contains("plan")
}

/// Reads a duration token such as "5h", "300m", "168h" or "1w" into seconds.
/// Returns nil for anything that is not a number followed by a time unit, so
/// a free-text label falls through to the caption's other rules.
func glanceDurationSeconds(_ token: String) -> TimeInterval? {
    let digits = token.prefix { $0.isNumber || $0 == "." }
    guard !digits.isEmpty, let value = Double(digits), value > 0 else { return nil }
    let unit = String(token.dropFirst(digits.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    switch unit {
    case "s", "sec", "secs", "second", "seconds": return value
    case "m", "min", "mins", "minute", "minutes": return value * 60
    case "h", "hr", "hrs", "hour", "hours": return value * 3_600
    case "d", "day", "days": return value * 86_400
    case "w", "week", "weeks": return value * 604_800
    default: return nil
    }
}

/// What VoiceOver says for one meter on a row: its caption, then both shares and
/// how far through the period we are, for example "5h 85 percent remaining, 15
/// percent used, 40 percent of period elapsed".
func glanceMeterSpeech(_ snapshot: QuotaWindowSnapshot, now: Date) -> String {
    "\(glanceMeterCaption(snapshot)) \(QuotaBarMetrics(snapshot: snapshot, now: now).spokenSummary)"
}

/// A line of meters, spoken whole: each meter's caption and reading, then how
/// long until it resets, with semicolons between the meters because each one
/// already carries commas of its own.  The row and every extra line under it
/// use this, so the captions ("1d", "7d") are never lost and a reset is said
/// once, at the precision the tooltip shows.
func glanceMetersSpeech(_ snapshots: [QuotaWindowSnapshot?], now: Date) -> String {
    snapshots.compactMap { $0 }.map { snapshot -> String in
        let reading = glanceMeterSpeech(snapshot, now: now)
        let reset = glanceResetFullCountdown(snapshot.resetAt, now: now)
        return reset.isEmpty ? reading : "\(reading), resets in \(reset)"
    }.joined(separator: "; ")
}

/// Rounds a duration to the largest whole unit that divides it, days first so
/// a weekly window reads "7d" rather than "1w" — the fleet copy already
/// shortens a 7-day window to "7d", and "1w" next to a "5h" was the
/// inconsistency worth avoiding.
private func glanceDurationTag(_ seconds: TimeInterval) -> String {
    let whole = max(1, Int(seconds.rounded()))
    if whole % 86_400 == 0 {
        let days = whole / 86_400
        return (28...31).contains(days) ? "1m" : "\(days)d"
    }
    if whole % 3_600 == 0 { return "\(whole / 3_600)h" }
    if whole % 60 == 0 { return "\(whole / 60)m" }
    return "\(whole)s"
}

/// One caption, one bar, one percentage, and one reset countdown.
struct GlanceMeter: View {
    let snapshot: QuotaWindowSnapshot
    let now: Date

    private var percent: Double? { snapshot.remainingPercent }
    private var tint: Color { quotaStatusColor(for: snapshot, sourceFailed: false) }
    private var countdown: String { glanceResetCountdown(snapshot.resetAt, now: now) }
    private var metrics: QuotaBarMetrics { QuotaBarMetrics(snapshot: snapshot, now: now) }

    var body: some View {
        HStack(spacing: Metrics.glanceMeterGap) {
            Text(glanceMeterCaption(snapshot))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: Metrics.glanceMeterCaptionWidth, alignment: .trailing)
            // Red for the share used, green for the share left, and a black
            // marker for how far through the period we are.  The percentage
            // beside it keeps its own status colour.
            QuotaUsageBar(metrics: metrics, height: Metrics.glanceMeterBarHeight,
                          dimmed: quotaBarIsDimmed(for: snapshot, sourceFailed: false),
                          markerHeight: Metrics.glanceMeterMarkerHeight)
                .frame(width: Metrics.glanceMeterBarWidth, height: Metrics.glanceMeterBarHeight)
            HStack(spacing: 3) {
                Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 11, weight: .medium).monospacedDigit())
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: true, vertical: false)
                if !countdown.isEmpty {
                    Text(countdown)
                        .font(.system(size: 10, weight: .regular).italic())
                        .foregroundStyle(Color.secondary.opacity(0.85))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .help(glanceResetHelp(snapshot.resetAt, now: now) ?? "")
                }
            }
            .frame(width: Metrics.glanceMeterPercentWidth + Metrics.glanceMeterGap + Metrics.glanceMeterCountdownWidth, alignment: .leading)
        }
        .frame(width: Metrics.glanceMeterWidth, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(glanceMeterCaption(snapshot))
        .accessibilityValue(spokenValue)
    }

    private var spokenValue: String {
        let reading = metrics.spokenSummary
        if !countdown.isEmpty {
            return "\(reading), resets in \(glanceResetFullCountdown(snapshot.resetAt, now: now))"
        }
        return reading
    }
}

/// The two meter columns every Glance line shares: the row itself, and each
/// extra line under an expanded row.
///
/// Two columns, always.  A meter sits in the column its cadence names and is
/// never centred between them:
///
/// - A row with one meter puts it in the FIRST column, where a two-meter row's
///   first meter is, and leaves the second column empty.  (The row's single
///   meter is always its `short` slot; see `glanceMeterPair`.)  Owner ruling,
///   restated 2026-10-01: single bars start in the first column, the same x as
///   the "5h" bars of the rows above and below, so the bars, captions and
///   percentages form one grid down the whole popover.  PR #88 centred them
///   across the two columns; that is what this replaces.
/// - A line with only a long window, which an expanded row uses for a lone
///   weekly, keeps the first column reserved and puts the window under the
///   second, so it sits under the row's weekly meter.
struct GlanceMeterColumns: View {
    let short: QuotaWindowSnapshot?
    let long: QuotaWindowSnapshot?
    let now: Date

    var body: some View {
        columns
            // The meter area is always the full two-meter width, whatever it
            // holds, so the columns land at the same x on every row.  Without
            // this the area competes with the row's own trailing spacer for the
            // leftover space and a column's position depends on how that
            // division happens to fall.
            .frame(width: Metrics.glanceMetersWidth, alignment: .leading)
    }

    @ViewBuilder
    private var columns: some View {
        if short != nil || long != nil {
            HStack(spacing: 0) {
                column(short)
                Spacer().frame(width: Metrics.glanceMeterGroupGap)
                column(long)
            }
        } else {
            // No window at all.  The width is still reserved so a row with no
            // reading does not re-centre itself in the popover.
            Color.clear.frame(height: 1)
        }
    }

    /// One column: a meter, or the same width left empty.  The fixed width is
    /// what puts a meter at exactly the same x on every line: without it the
    /// slot is as wide as its text, "1m" narrower than "31d 23h".
    @ViewBuilder
    private func column(_ snapshot: QuotaWindowSnapshot?) -> some View {
        if let snapshot {
            GlanceMeter(snapshot: snapshot, now: now)
                .frame(width: Metrics.glanceMeterWidth, alignment: .leading)
        } else {
            Spacer().frame(width: Metrics.glanceMeterWidth)
        }
    }
}

/// One extra line of meters under an expanded row: a model's or a pool's
/// windows that the row's own two meters leave out, in the same two columns.
struct GlanceMeterLine: Identifiable, Equatable {
    /// "Video", "Sonnet", "Overall": what these windows measure.
    let label: String
    let short: QuotaWindowSnapshot?
    let long: QuotaWindowSnapshot?

    var id: String {
        [label, short?.window.id ?? "-", long?.window.id ?? "-"].joined(separator: "|")
    }
}

/// The lines an expanded row shows: every window the row's own two meters do
/// not, and nothing the row already shows.  Windows are grouped by what they
/// measure (MiniMax's "video" model, Claude's Sonnet family), shortest cadence
/// first, two to a line.  A group with one window puts it in the column that
/// matches its cadence, so a lone weekly sits under the row's weekly meter, and
/// a group of three or more keeps each cadence in its own column
/// (`glanceMeterLines`).
///
/// A masked Antigravity window is left out: its number cannot mean anything,
/// and the row already skips it for the same reason.
func glanceExpandedLines(for row: DisplaySection, now: Date) -> [GlanceMeterLine] {
    let pair = glanceMeterPair(for: row, now: now)
    let shownWindows = [pair.short, pair.long].compactMap { $0 }
    let shown = Set(shownWindows.map(\.window.id))

    // The same reading from a second source (two readers both reporting a 5h
    // and a weekly window) is the row's own number again, not another window.
    // Only a different source is treated as a duplicate, and only when it
    // reads the same allowance: two windows from one source that share a label
    // and cadence are two windows, and so are two accounts'.
    var holders: [String: [QuotaWindowSnapshot]] = [:]
    func key(_ snapshot: QuotaWindowSnapshot) -> String { glanceMeterKey(snapshot) }
    func source(_ snapshot: QuotaWindowSnapshot) -> String { snapshot.window.source ?? "" }
    for snapshot in shownWindows { holders[key(snapshot), default: []].append(snapshot) }
    var rest: [QuotaWindowSnapshot] = []
    // An empty duplicate is no more an extra line than it is a second meter.
    let drawable = glanceDrawableWindows(row.section.windows.filter { !row.isMasked($0) })
    for snapshot in drawable where !shown.contains(snapshot.window.id) {
        if let known = holders[key(snapshot)],
           !known.contains(where: { source($0) == source(snapshot) }),
           known.contains(where: { glanceSameAllowance($0, snapshot) }) { continue }
        holders[key(snapshot), default: []].append(snapshot)
        rest.append(snapshot)
    }

    var order: [String] = []
    var grouped: [String: [QuotaWindowSnapshot]] = [:]
    for snapshot in rest {
        let label = glanceLineLabel(snapshot)
        if grouped[label] == nil { order.append(label) }
        grouped[label, default: []].append(snapshot)
    }

    return order.flatMap { label -> [GlanceMeterLine] in
        let windows = (grouped[label] ?? []).enumerated().sorted { lhs, rhs in
            let left = glanceWindowLength(lhs.element, now: now)
            let right = glanceWindowLength(rhs.element, now: now)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
        return glanceMeterLines(label: label, windows: windows, now: now)
    }
}

/// One group's windows, shortest first, as lines of two meters.
///
/// - One window sits in the column its cadence names, so a lone weekly is
///   under the row's weekly meter.
/// - Two windows share one line, the shorter first, whatever their cadence:
///   MiniMax's video 1d and 1w are both "long" by the row's rule and still
///   read as a pair.
/// - Three or more are split by cadence, short windows down the first column
///   and long ones down the second, so a third window is never put under the
///   wrong meter.  A group of a single cadence is paired in order, with a
///   lone leftover in the column its cadence names.
private func glanceMeterLines(label: String, windows: [QuotaWindowSnapshot], now: Date) -> [GlanceMeterLine] {
    func alone(_ snapshot: QuotaWindowSnapshot) -> GlanceMeterLine {
        glanceCadence(snapshot, now: now) == .short
            ? GlanceMeterLine(label: label, short: snapshot, long: nil)
            : GlanceMeterLine(label: label, short: nil, long: snapshot)
    }
    switch windows.count {
    case 0:
        return []
    case 1:
        return [alone(windows[0])]
    case 2:
        return [GlanceMeterLine(label: label, short: windows[0], long: windows[1])]
    default:
        let shorts = windows.filter { glanceCadence($0, now: now) == .short }
        let longs = windows.filter { glanceCadence($0, now: now) == .long }
        if !shorts.isEmpty && !longs.isEmpty {
            return (0..<max(shorts.count, longs.count)).map { index in
                GlanceMeterLine(label: label,
                                short: index < shorts.count ? shorts[index] : nil,
                                long: index < longs.count ? longs[index] : nil)
            }
        }
        return stride(from: 0, to: windows.count, by: 2).map { index in
            index + 1 < windows.count
                ? GlanceMeterLine(label: label, short: windows[index], long: windows[index + 1])
                : alone(windows[index])
        }
    }
}

/// What a window measures, for the label at the start of an extra line: its
/// model ("video" reads "Video"), the name in its label's parentheses
/// ("7d window (Sonnet)" reads "Sonnet"), or its pool.  A window that names
/// only its cadence covers the whole subscription, so it reads "Overall".
func glanceLineLabel(_ snapshot: QuotaWindowSnapshot) -> String {
    let window = snapshot.window
    if let model = window.modelId?.trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty {
        return glanceModelName(model)
    }
    let label = AntigravityDisplay.windowLabel(window.label).trimmingCharacters(in: .whitespacesAndNewlines)
    if let open = label.firstIndex(of: "("), let close = label.lastIndex(of: ")"), open < close {
        let inner = label[label.index(after: open)..<close].trimmingCharacters(in: .whitespacesAndNewlines)
        let head = label[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        let innerIsCadence = inner.lowercased().contains("window") || glanceDurationSeconds(inner.lowercased()) != nil
        if !inner.isEmpty, !innerIsCadence { return glanceModelName(inner) }
        if !head.isEmpty, !head.lowercased().hasSuffix("window") { return glanceModelName(head) }
    }
    if let separator = label.range(of: " · ") {
        return String(label[..<separator.lowerBound])
    }
    return label.isEmpty || label.lowercased().hasSuffix("window") ? "Overall" : label
}

/// A model or family name as a person reads it: a single lower-case word
/// gains a capital ("video" reads "Video"), and anything else — "gpt-5-codex",
/// "Gemini 3 Pro" — is left exactly as the provider wrote it.
private func glanceModelName(_ name: String) -> String {
    guard !name.isEmpty, name.allSatisfy({ $0.isLetter && $0.isLowercase }) else { return name }
    return name.prefix(1).uppercased() + name.dropFirst()
}

/// How long a window's period is, for putting a group's shorter cadence in the
/// first column.  Unknown lengths sort last.
private func glanceWindowLength(_ snapshot: QuotaWindowSnapshot, now: Date) -> TimeInterval {
    let token = (snapshot.window.window ?? "")
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if let seconds = glanceDurationSeconds(token) { return seconds }
    if glanceIsMonthly(snapshot) { return 30 * 86_400 }
    switch glanceMeterCaption(snapshot) {
    case "5h": return 5 * 3_600
    case "24h": return 86_400
    case "7d": return 7 * 86_400
    default: break
    }
    if let reset = snapshot.resetAt, reset > now { return reset.timeIntervalSince(now) }
    return .greatestFiniteMagnitude
}

/// Whether a row may open inline.  A MiniMax row pulled from the fleet never
/// does: the fleet copy of its per-model windows is what used to list
/// "general" and "video" windows as a wall of text (owner delta, 2026-09-30).
func glanceRowAllowsExpansion(_ row: DisplaySection, origin: QuotaOrigin) -> Bool {
    !(origin == .fleet && row.providerKey == "minimax")
}

/// The short status a row shows in place of its meters when it has no reading.
func glanceRowStatusText(issue: String?, hasWindows: Bool) -> String {
    if let issue {
        if issue == ClaudeLoginState.idle.issue { return "login idle" }
        if issue.localizedCaseInsensitiveContains("permission") { return "needs permission" }
        return issue.localizedCaseInsensitiveContains("sign in") ? "not signed in" : "unavailable"
    }
    return hasWindows ? "not signed in" : "no report"
}

/// One platform, one line.  The only compact row type in the app.
struct GlanceRow: View {
    let row: DisplaySection
    let now: Date
    let issue: String?
    let origin: QuotaOrigin
    let markStyle: MarkStyle
    /// Whether the per-provider reset-alarm bell sits at the very left of the
    /// row.  Shown only while the header's All is off; with All on, every
    /// provider alarms and a per-row bell would have nothing to choose.
    var showsAlarmToggle: Bool = false
    /// This provider's own pick: a solid bell when on, a faint outline when off.
    var isAlarmEnabled: Bool = false
    /// Whether this row may open at all.  See `glanceRowAllowsExpansion`.
    var allowsExpansion: Bool = true
    /// Whether the inline expansion is shown below this row.  Driven by the
    /// popover's `expandedIds` set, threaded down here so the chevron and the
    /// detail lines animate together.
    var isExpanded: Bool = false
    /// Tap handler for the row's body — opening or closing the expansion.
    /// The bell is a sibling of the tappable body, so a tap on the bell never
    /// expands a row.
    var onTap: (() -> Void)? = nil
    var onToggleAlarm: (() -> Void)? = nil

    private var section: QuotaPlatformSection { row.section }

    /// The windows the row's own meters leave out, as extra lines of meters.
    /// A row showing an issue instead of meters has nothing to open.
    private var extraLines: [GlanceMeterLine] {
        issue == nil ? glanceExpandedLines(for: row, now: now) : []
    }

    private var canExpand: Bool {
        allowsExpansion && !extraLines.isEmpty
    }

    /// The window the row speaks for: the one closest to its cap, ignoring any
    /// window whose percentage cannot mean anything.
    private var driving: QuotaWindowSnapshot? { row.driving }

    private var percent: Double? {
        issue == nil ? row.remainingPercent : nil
    }

    private var isLive: Bool { issue == nil && section.hasFreshReport }

    /// The two meters this row shows.  Empty only when the row has no window
    /// at all, in which case the row shows its status where the meters go.
    private var meters: GlanceMeterPair {
        issue == nil ? glanceMeterPair(for: row, now: now) : GlanceMeterPair()
    }

    private var statusText: String {
        glanceRowStatusText(issue: issue, hasWindows: !section.windows.isEmpty)
    }

    private var attribution: String? {
        guard origin == .fleet else { return nil }
        let source = driving?.window.source?.trimmingCharacters(in: .whitespacesAndNewlines)
        let observed = driving?.observedAt.map { "reported \($0.formatted(date: .omitted, time: .shortened))" }
        let parts = [source, observed].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                if showsAlarmToggle {
                    alarmToggle
                    Spacer().frame(width: Metrics.glanceLogoGap)
                }
                rowBody
            }
            .padding(.horizontal, Metrics.glanceGutter)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: Metrics.glanceLocalRowHeight)
            if isExpanded && canExpand {
                expandedSection
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }

    /// The logo and the name.  The row's tooltip belongs here (and to the
    /// status text), not to the whole row: a countdown carries a tooltip of
    /// its own, and two nested tooltips leave it to AppKit which one shows.
    private var nameBlock: some View {
        HStack(spacing: 0) {
            // Keyed by the row, not the platform, so each Antigravity pool
            // wears its own mark: the colour Gemini star, or the solid
            // Third-Party star.
            PlatformLogo(providerKey: row.id, size: 16, style: markStyle)
                .frame(width: Metrics.glanceLogoWidth, height: Metrics.glanceLogoWidth)
            Spacer().frame(width: Metrics.glanceLogoGap)
            VStack(alignment: .leading, spacing: 1) {
                // An Antigravity row names its pool, which does not fit beside
                // the platform in the title column, so the pool takes the second
                // line rather than being truncated away.
                Text(row.poolTitle == nil ? row.title : row.platformTitle)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = row.poolTitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .truncationMode(.tail)
                }
            }
            .frame(width: Metrics.glanceRowTitleWidth, alignment: .leading)
        }
        .help(helpText)
    }

    /// The logo, the name, the two meters and the chevron: the part a tap
    /// expands, and the part VoiceOver reads as one element.
    private var rowBody: some View {
        HStack(spacing: 0) {
            nameBlock
            Spacer().frame(width: Metrics.glanceColumnGap)
            if percent != nil {
                // Both cadences, always.  The 4-5hr window and the
                // weekly/monthly window are the two numbers an owner
                // actually routes on, and hiding the second one behind a
                // click made the compact row say half the truth.
                GlanceMeterColumns(short: meters.short, long: meters.long, now: now)
            } else {
                // Where a single meter's bar would start (Cursor's, say),
                // left-aligned, so a row without a reading still lines up
                // with the bars in the rows above and below it.
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.leading, Metrics.glanceMeterBarInset)
                    .help(helpText)
            }
            Spacer(minLength: Metrics.glanceColumnGap)
            // Chevron signals click-to-expand only when the row has windows
            // its two meters leave out.  When false, an invisible spacer
            // preserves trailing margin so rows stay perfectly left-aligned.
            if canExpand {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: Metrics.glanceChevronWidth)
                    .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    .accessibilityHidden(true)
            } else {
                Spacer().frame(width: Metrics.glanceChevronWidth)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if canExpand {
                onTap?()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.title)
        .accessibilityValue(spokenValue)
        .accessibilityHint(canExpand ? (isExpanded ? "Double-tap to collapse." : "Double-tap to expand.") : "")
    }

    /// The row's tooltip: the issue when there is one, and for a fleet row
    /// the source and time it was reported, which the row itself leaves to
    /// the source's heading.
    private var helpText: String {
        if let issue { return issue }
        return [row.title, attribution].compactMap { $0 }.joined(separator: " · ")
    }

    /// The per-provider reset-alarm switch: solid when this provider alarms,
    /// faint when it does not.
    private var alarmToggle: some View {
        Button { onToggleAlarm?() } label: {
            Image(systemName: isAlarmEnabled ? "bell.fill" : "bell")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isAlarmEnabled ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.faint))
                .frame(width: Metrics.glanceAlarmBellWidth, height: Metrics.glanceAlarmBellWidth)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isAlarmEnabled
              ? "Reset alarm is on for \(row.title)." + sentenceGap + "Click to turn it off."
              : "Reset alarm is off for \(row.title)." + sentenceGap + "Click to turn it on.")
        .accessibilityLabel("Reset Alarm For \(row.title)")
        .accessibilityValue(isAlarmEnabled ? "on" : "off")
        .accessibilityAddTraits(isAlarmEnabled ? [.isSelected] : [])
    }

    /// Inline expansion: the windows the row's two meters leave out, as more
    /// lines of meters in exactly the row's format and columns — a label where
    /// the name sits, then caption, bar, percentage and countdown under each
    /// of the row's two meters.  Nothing the row already shows is repeated.
    @ViewBuilder
    private var expandedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(extraLines) { line in
                HStack(spacing: 0) {
                    if showsAlarmToggle {
                        Spacer().frame(width: Metrics.glanceAlarmBellWidth + Metrics.glanceLogoGap)
                    }
                    Spacer().frame(width: Metrics.glanceLogoWidth + Metrics.glanceLogoGap)
                    Text(line.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: Metrics.glanceRowTitleWidth, alignment: .leading)
                    Spacer().frame(width: Metrics.glanceColumnGap)
                    GlanceMeterColumns(short: line.short, long: line.long, now: now)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Metrics.glanceGutter)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: Metrics.glanceExpandedLineHeight)
                // An explicit value, as the row has: a label alone replaces
                // the combined children's, which would drop the "1d" and "7d".
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(line.label)
                .accessibilityValue(glanceMetersSpeech([line.short, line.long], now: now))
            }
        }
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface.opacity(0.55))
    }

    /// Speaks both cadences, not just the row's headline number, because that
    /// is what the row now shows on the line.  A screen reader user gets the
    /// same two numbers an owner reads at a glance.
    private var spokenValue: String {
        var parts: [String] = []
        let meterSpeech = glanceMetersSpeech([meters.short, meters.long], now: now)
        if meterSpeech.isEmpty {
            parts.append(percent == nil
                         ? statusText
                         : QuotaBarMetrics(remainingPercent: percent, elapsedFraction: nil).spokenSummary)
        } else {
            // Each meter says its own reset, so the row does not say it again.
            parts.append(meterSpeech)
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

/// A countdown's non-zero units, largest first, for a time left of one minute
/// or more: 4d 0h 59m is ["4d", "59m"].  Whole minutes left, so a countdown
/// never claims more time than there is.
private func glanceCountdownUnits(seconds: Int) -> [String] {
    let minutes = seconds / 60
    let days = minutes / 1_440
    let hours = (minutes % 1_440) / 60
    let mins = minutes % 60
    return [(days, "d"), (hours, "h"), (mins, "m")].filter { $0.0 > 0 }.map { "\($0.0)\($0.1)" }
}

/// Reset countdown without the "Resets in" prefix, in at most its two largest
/// non-zero units: "4d 2h", "17d 4h", "2h 42m", "45m", "<1m".  A unit that is
/// zero is skipped rather than shown, so a countdown never reads "1d 0h" or
/// "0h", and 4d 0h 59m reads "4d 59m".  The full value is
/// `glanceResetFullCountdown`, one hover away.
func glanceResetCountdown(_ reset: Date?, now: Date) -> String {
    guard let reset else { return "" }
    let seconds = Int(reset.timeIntervalSince(now).rounded())
    guard seconds > 0 else { return "due" }
    guard seconds >= 60 else { return "<1m" }
    return glanceCountdownUnits(seconds: seconds).prefix(2).joined(separator: " ")
}

/// The whole countdown, down to the minute, with zero units skipped the same
/// way: "4d 2h 42m", "2h 42m", "2h", "45m".
func glanceResetFullCountdown(_ reset: Date?, now: Date) -> String {
    guard let reset else { return "" }
    let seconds = Int(reset.timeIntervalSince(now).rounded())
    guard seconds > 0 else { return "due" }
    guard seconds >= 60 else { return "less than a minute" }
    return glanceCountdownUnits(seconds: seconds).joined(separator: " ")
}

/// The countdown's tooltip: the full value and the reset's own date and time,
/// "Resets in 4d 2h 42m, on Fri, Oct 3, 7:09 PM".  Nil when there is no reset.
func glanceResetHelp(_ reset: Date?, now: Date) -> String? {
    guard let reset else { return nil }
    let when = reset.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
    guard reset > now else { return "Reset was due \(when)" }
    return "Resets in \(glanceResetFullCountdown(reset, now: now)), on \(when)"
}
