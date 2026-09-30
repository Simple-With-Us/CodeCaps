import AppKit
import QuotaCore
import SwiftUI

/// The status-item popover.  Read-only, one row per platform, plus three
/// affordances in the footer.  Glance never renders a `PlatformCard`; the
/// Console never renders a `GlanceRow`.
///
/// The header carries two switches beside the name: which readings the list
/// shows (This Mac or Fleet Reported, one at a time), and whether every
/// provider's reset alarm is on (All) or the owner picks them per row.
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
        HStack(spacing: 10) {
            Text("CodeCaps")
                .font(.system(size: 13, weight: .semibold))
                .fixedSize()
            GlanceViewToggle(selection: $model.glanceView)
            GlanceAlarmAllToggle(isOn: $model.alarmsAll)
            Spacer(minLength: 8)
            Text(headerStatus)
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
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
    }

    /// Two literal ASCII spaces on either side of the dot — the fleet "two spaces
    /// between sentences" convention reads just as well between phrases inside a
    /// single string, so the header breathes without a heavier separator.
    private var headerStatus: String {
        glanceHeaderStatus(view: model.glanceView,
                           reporting: model.reportingCount,
                           total: model.sections.count,
                           sources: fleetGroups.count,
                           checked: model.glanceView == .fleetReported
                               ? (model.lastPullTime ?? model.lastChecked)
                               : model.lastChecked)
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
        case .thisMac: thisMacContent
        case .fleetReported: fleetContent
        }
    }

    @ViewBuilder
    private var thisMacContent: some View {
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
                        message: "Fleet Reported shows the quotas your other machines push to an endpoint you run."
                            + sentenceGap + "Add the endpoint and its Read Token in Settings to connect it.",
                        actionTitle: "Connect Fleet Endpoint") { openConsole(.settingsSourcesFleet) }
                }
            } else {
                // One header per reporting source, so a row always says who
                // reported it.  The toggle already says these are fleet rows.
                ForEach(Array(fleetGroups.enumerated()), id: \.element.id) { groupIndex, group in
                    if groupIndex > 0 {
                        Spacer().frame(height: Metrics.glanceGroupGap)
                    }
                    groupHeader(fleetGroupTitle(group))
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
                         markStyle: model.glanceMarkStyle(for: row.providerKey),
                         showsAlarmToggle: !model.alarmsAll,
                         isAlarmEnabled: model.isProviderAlarmSelected(row.id),
                         isExpanded: expandedIds.contains(key),
                         onTap: { toggleExpanded(key) },
                         onToggleAlarm: { model.toggleAlarm(for: row.id) })
    }

    /// "MAC MINI  ·  REPORTED 9:12 AM": the reporting source, and its latest reading.
    /// The time lives here rather than under every row, where it truncated.
    private func fleetGroupTitle(_ group: FleetGroup) -> String {
        let latest = group.rows.flatMap(\.section.windows).compactMap(\.observedAt).max()
        guard let latest else { return group.title.uppercased() }
        let time = latest.formatted(date: .omitted, time: .shortened)
        return "\(group.title.uppercased())  ·  REPORTED \(time.uppercased())"
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

/// The count and time on the right of the header.  This Mac counts the
/// providers reporting; Fleet Reported counts the sources that reported them.
/// Two literal spaces either side of the dot, the fleet convention for a
/// phrase break.
///
/// A source, not a machine: the fleet pull groups readings by the collector or
/// app that reported them (`FleetOrigin.identity`), and that is a machine only
/// some of the time.
func glanceHeaderStatus(view: GlanceViewMode, reporting: Int, total: Int, sources: Int, checked: Date?) -> String {
    let counted: String?
    switch view {
    case .thisMac:
        counted = "\(reporting) of \(total)"
    case .fleetReported:
        // With no source to count, the empty list below already says why.
        counted = sources == 0 ? nil : (sources == 1 ? "1 source" : "\(sources) sources")
    }
    let time = checked.map { $0.formatted(date: .omitted, time: .shortened) }
    return [counted, time].compactMap { $0 }.joined(separator: "  ·  ")
}

// MARK: - Header controls

/// The two-box switch between This Mac and Fleet Reported.  It uses the same
/// small caps as the group headings it replaces, so it reads as the heading of
/// the list below it.
struct GlanceViewToggle: View {
    @Binding var selection: GlanceViewMode

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
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.controlBorder))
        .fixedSize()
    }

    private func segment(_ mode: GlanceViewMode) -> some View {
        let selected = selection == mode
        return Button { selection = mode } label: {
            Text(mode.eyebrow)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 8)
                .frame(height: Metrics.glanceHeaderControlHeight)
                .background(selected ? Theme.selection : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(mode.title)
        .accessibilityLabel(mode.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// The header's bell: every provider's reset alarm on (All), or picked one by
/// one with the faint bell at the left of each row.
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
        HStack(spacing: 3) {
            Image(systemName: isOn ? "bell.fill" : "bell")
                .font(.system(size: 10, weight: .semibold))
            Text("All")
                .font(.system(size: 10, weight: .bold))
                .tracking(0.4)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: Metrics.glanceHeaderControlHeight)
        .background(isOn ? Theme.selection : Color.clear, in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.controlBorder))
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
    let trustworthy = row.section.windows.filter {
        !$0.window.isSupplementaryVideoQuota && !row.isMasked($0)
    }
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
    // Both fallbacks exclude the window the first slot already took.  A
    // single-window provider that classifies as long — which every weekly
    // meter does — would otherwise resolve `longest` to the same snapshot and
    // render one meter twice, hiding the second cadence entirely.
    let long = nearestToCap(longest.filter { $0.window.id != short.window.id })
        ?? nearestToCap(candidates.filter { $0.window.id != short.window.id })
    return GlanceMeterPair(short: short, long: long)
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
        HStack(spacing: 4) {
            Text(glanceMeterCaption(snapshot))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: Metrics.glanceMeterCaptionWidth, alignment: .trailing)
            // Red for the share used, green for the share left, and a marker
            // for how far through the period we are.  The percentage beside it
            // keeps its own status colour.
            QuotaUsageBar(metrics: metrics, height: 4,
                          dimmed: quotaBarIsDimmed(for: snapshot, sourceFailed: false))
                .frame(width: Metrics.glanceMeterBarWidth, height: 4)
            Text(percent.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: true, vertical: false)
                .frame(width: Metrics.glanceMeterPercentWidth, alignment: .leading)
            if !countdown.isEmpty {
                // The same type as the caption on the left, so the row reads
                // as one line of labels rather than a label and a footnote.
                Text(countdown)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: Metrics.glanceMeterCountdownWidth, alignment: .leading)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(glanceMeterCaption(snapshot))
        .accessibilityValue(spokenValue)
    }

    private var spokenValue: String {
        let reading = metrics.spokenSummary
        if !countdown.isEmpty {
            return "\(reading), resets in \(countdown)"
        }
        return reading
    }
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
    /// Whether the inline expansion is shown below this row.  Driven by the
    /// popover's `expandedIds` set, threaded down here so the chevron and the
    /// detail list animate together.
    var isExpanded: Bool = false
    /// Tap handler for the row's body — opening or closing the expansion.
    /// The bell is a sibling of the tappable body, so a tap on the bell never
    /// expands a row.
    var onTap: (() -> Void)? = nil
    var onToggleAlarm: (() -> Void)? = nil

    private var section: QuotaPlatformSection { row.section }

    private var canExpand: Bool {
        row.section.windows.count > 2
    }

    /// The window the row speaks for: the one closest to its cap, ignoring any
    /// window whose percentage cannot mean anything.
    private var driving: QuotaWindowSnapshot? { row.driving }

    private var percent: Double? {
        issue == nil ? row.remainingPercent : nil
    }

    private var isLive: Bool { issue == nil && section.hasFreshReport }

    /// The two meters this row shows.  Nil only when the row has no window at
    /// all, in which case the row already shows "no report" in its trailing
    /// column.
    private var meters: GlanceMeterPair {
        issue == nil ? glanceMeterPair(for: row, now: now) : GlanceMeterPair()
    }

    @ViewBuilder
    private var meterArea: some View {
        // The gap belongs in here, not between `meterArea` and its
        // neighbours: this view is a single child of the row's HStack, so a
        // spacer outside it leaves the two meters touching and the first
        // meter's percentage runs into the second meter's caption.
        HStack(spacing: 0) {
            if let short = meters.short {
                GlanceMeter(snapshot: short, now: now)
                    .frame(width: Metrics.glanceMeterWidth, alignment: .leading)
            }
            if let long = meters.long {
                Spacer().frame(width: Metrics.glanceMeterGroupGap)
                GlanceMeter(snapshot: long, now: now)
                    .frame(width: Metrics.glanceMeterWidth, alignment: .leading)
            }
        }
    }

    private var statusText: String {
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

    /// The logo, the name, the two meters and the chevron: the part a tap
    /// expands, and the part VoiceOver reads as one element.
    private var rowBody: some View {
        HStack(spacing: 0) {
            // Keyed by the row, not the platform, so each Antigravity pool
            // wears its own mark: the colour Gemini star, or the one-colour
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
            Spacer().frame(width: Metrics.glanceColumnGap)
            if percent != nil {
                // Both cadences, always.  The 4-5hr window and the
                // weekly/monthly window are the two numbers an owner
                // actually routes on, and hiding the second one behind a
                // click made the compact row say half the truth.
                meterArea
            }
            Spacer(minLength: Metrics.glanceColumnGap)
            if percent == nil {
                Text(statusText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: Metrics.glanceRowTrailingWideWidth, alignment: .trailing)
                Spacer().frame(width: Metrics.glanceLogoGap)
            }
            // Chevron signals click-to-expand only when the row has more than
            // two windows to inspect.  When false, an invisible spacer preserves
            // trailing margin so rows stay perfectly left-aligned.
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
        .help(helpText)
    }

    /// The row's tooltip: the issue when there is one, and for a fleet row
    /// the source and time it was reported, which the row itself leaves to
    /// the machine's heading.
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

    /// Inline expansion: every quota window the local reader (or the fleet pull)
    /// has for this provider, one row each, with label · percent remaining ·
    /// reset countdown.  Mirrors what the Console cards show, minus the chart.
    ///
    /// This is the detail the collapsed row no longer needs for its two
    /// meters, so it earns its keep on the windows the meters leave out — a
    /// third cadence, or a per-model split inside a pool.
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
                    // The row's own countdown type and column, so "6d 23h 59m"
                    // and "29d 23h 59m" fit on one line instead of wrapping.
                    Text(glanceResetCountdown(snapshot.resetAt, now: now))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(width: Metrics.glanceMeterCountdownWidth, alignment: .trailing)
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

    /// Speaks both cadences, not just the row's headline number, because that
    /// is what the row now shows on the line.  A screen reader user gets the
    /// same two numbers an owner reads at a glance.
    private var spokenValue: String {
        var parts: [String] = []
        let meterSpeech = [meters.short, meters.long].compactMap { $0 }.map { glanceMeterSpeech($0, now: now) }
        if meterSpeech.isEmpty {
            parts.append(QuotaBarMetrics(remainingPercent: percent, elapsedFraction: nil).spokenSummary)
        } else {
            // Each meter already carries commas of its own, so the meters are
            // set apart with semicolons.
            parts.append(meterSpeech.joined(separator: "; "))
        }
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

/// Reset countdown without the "Resets in" prefix.  Formats in hours/min for
/// short windows, and days/hours/min for weekly/monthly windows.
func glanceResetCountdown(_ reset: Date?, now: Date) -> String {
    guard let reset else { return "" }
    let seconds = reset.timeIntervalSince(now)
    guard seconds > 0 else { return "due" }
    let minutes = max(1, Int(ceil(seconds / 60)))
    if minutes >= 1440 {
        let days = minutes / 1440
        let hours = (minutes % 1440) / 60
        let mins = (minutes % 1440) % 60
        if mins > 0 {
            return "\(days)d \(hours)h \(mins)m"
        } else {
            return "\(days)d \(hours)h"
        }
    }
    if minutes >= 60 { return "\(minutes / 60)h \(minutes % 60)m" }
    return "\(minutes)m"
}
