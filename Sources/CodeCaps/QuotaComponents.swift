import AppKit
import QuotaCore
import SwiftUI

/// The accent colours the owner can choose from, each with a light and a dark
/// value chosen for contrast against `Theme.background` rather than converted
/// from one another.
///
/// These are stored as raw values and read through `Theme.accent`, so changing
/// the choice is a re-render rather than a re-layout.  Every one of these
/// pairs clears 4.5:1 for its percentage text on its own background, because
/// that number is the one the owner reads at a glance.
enum AccentChoice: String, CaseIterable, Identifiable {
    case teal, blue, violet, orange, green, magenta

    var id: String { rawValue }

    var title: String {
        switch self {
        case .teal: return "Teal"
        case .blue: return "Blue"
        case .violet: return "Violet"
        case .orange: return "Orange"
        case .green: return "Green"
        case .magenta: return "Magenta"
        }
    }

    /// Light / dark values, as 0xRRGGBB.
    var lightHex: UInt32 {
        switch self {
        case .teal: return 0x087370
        case .blue: return 0x1F5FBF
        case .violet: return 0x5B3FBF
        case .orange: return 0xA85C05
        case .green: return 0x2E6B2E
        case .magenta: return 0xA3225E
        }
    }

    var darkHex: UInt32 {
        switch self {
        case .teal: return 0x4FD1C5
        case .blue: return 0x74AEF7
        case .violet: return 0xB49BF5
        case .orange: return 0xF0B45A
        case .green: return 0x7FD07F
        case .magenta: return 0xF07AAF
        }
    }

    /// The stored choice, defaulting to the teal the app shipped with.
    static var current: AccentChoice {
        get {
            AccentChoice(rawValue: UserDefaults.standard.string(forKey: "accentChoice") ?? "") ?? .teal
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "accentChoice") }
    }
}

/// The whole colour vocabulary, in one place, with a dark value for every
/// token.  A dynamic `NSColor` resolves per appearance, so the SPM target needs
/// no asset catalog and nothing has to be re-rendered when the theme changes.
enum Theme {
    /// The owner's high-contrast choice, read on every resolve so a change
    /// takes effect without relaunching.
    static var highContrast: Bool {
        UserDefaults.standard.bool(forKey: "highContrast")
    }

    static let ink = dyn(hex(0x1F2B3A), hex(0xE8ECF1))
    /// The accent the owner picked.  A computed property rather than a `let`
    /// because it is a preference, and the dynamic `NSColor` it returns still
    /// resolves per appearance, so both the accent and the theme stay live.
    static var accent: Color { accentColor }

    static let warning = dyn(hex(0xA85C05), hex(0xF0B45A))
    static let danger = dyn(hex(0xBF3339), hex(0xFF6B6B))
    static let background: Color = highContrastBackground
    static let surface: Color = highContrastSurface
    static let hairline: Color = highContrast
        ? dyn(NSColor.black.withAlphaComponent(0.45), NSColor.white.withAlphaComponent(0.55))
        : dyn(NSColor.black.withAlphaComponent(0.06), NSColor.white.withAlphaComponent(0.10))
    /// The elapsed-time marker on a quota bar.  Black on the light surface and
    /// white on the dark one, so it reads against both the red and green segments.
    static let pacingMarker = dyn(NSColor.black, NSColor.white)
    /// A thin outline around the marker in the opposite tone, so a black marker
    /// stays visible on the dark teal segment and a white one on the red.
    static let pacingMarkerHalo = dyn(NSColor.white.withAlphaComponent(0.7),
                                      NSColor.black.withAlphaComponent(0.7))
    /// The share of a quota window already used: the left segment of the bar.
    static let barUsed = danger
    /// The share still available: the right segment of the bar.  This is the
    /// same teal as the "% remaining" text, which the owner reads as green.
    static let barRemaining = accent
    static let fleet = dyn(hex(0x4B4FA8), hex(0x8A8EE0))

    /// Unfilled portion of any progress bar.  A black 6% track disappears on a
    /// dark surface, so this is a token rather than a literal at each call site.
    static let track: Color = highContrast
        ? dyn(NSColor.black.withAlphaComponent(0.35), NSColor.white.withAlphaComponent(0.40))
        : dyn(NSColor.black.withAlphaComponent(0.08), NSColor.white.withAlphaComponent(0.14))

    /// Fill behind a selected or highlighted row.
    static let selection = dyn(hex(0x087370).withAlphaComponent(0.12),
                               hex(0x4FD1C5).withAlphaComponent(0.18))

    /// The outline of a small header control: the From Mac / From Fleet switch.
    static let controlBorder: Color = highContrast
        ? dyn(NSColor.black.withAlphaComponent(0.75), NSColor.white.withAlphaComponent(0.80))
        : dyn(NSColor.black.withAlphaComponent(0.16), NSColor.white.withAlphaComponent(0.22))

    /// A control that is present but off, such as an unchecked row bell:
    /// visible enough to find, quiet enough not to read as a setting.
    static let faint: Color = highContrast
        ? dyn(NSColor.black.withAlphaComponent(0.72), NSColor.white.withAlphaComponent(0.78))
        : dyn(NSColor.black.withAlphaComponent(0.26), NSColor.white.withAlphaComponent(0.30))

    /// The band behind a source's heading in From Fleet: darker than the list
    /// background in both appearances, so each source reads as a section.
    static let groupBand = dyn(hex(0xE1E6E7), hex(0x111214))

    /// Text on that band: the source's name and its "reported" time.  The
    /// system secondary and tertiary greys are tuned for the list background
    /// and fall under 3:1 on the darker band, so the band carries its own
    /// label colour (at least 4.5:1 in both appearances; a test measures it).
    static let groupBandLabel = dyn(hex(0x4A5663), hex(0xB7BEC7))

    /// A one-colour brand mark that has to read as solid, not as body text:
    /// pure black on Light and pure white on Dark, never the ink's grey.
    static let solidMark = dyn(NSColor.black, NSColor.white)

    /// The accent the owner chose, resolved against the current appearance.
    private static var accentColor: Color {
        let choice = AccentChoice.current
        return dyn(hex(choice.lightHex), hex(choice.darkHex))
    }

    /// High contrast pushes the surfaces apart and flattens the greys.  The
    /// default palette already carries its own contrast; this is the escape
    /// hatch for a display where the soft greys of the popover band, the
    /// hairlines and the secondary text all fall together.
    private static var highContrastBackground: Color {
        highContrast ? dyn(NSColor.white, hex(0x000000)) : dyn(hex(0xF5F7F7), hex(0x1C1E20))
    }

    private static var highContrastSurface: Color {
        highContrast ? dyn(NSColor.white, hex(0x000000)) : dyn(hex(0xFFFFFF), hex(0x26292C))
    }

    private static func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) {
            $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
    }
}

/// Every surface dimension the design fixes, declared once so the AppKit call
/// site and the SwiftUI root cannot disagree the way the old 580x510 window and
/// its 620x560 content did.
enum Metrics {
    /// 570pt carries TWO quota meters per row — the short 4-5hr window and the
    /// long weekly/monthly window — beside the platform name, with the
    /// per-provider alarm bell in front of the logo and real gaps between the
    /// percentage, its countdown and the second meter.
    ///
    /// It went 400 → 560 → 624 → 570.  The 624pt version answered the owner
    /// calling the row "a bit too cramped" (2026-09-30) by doubling the gap
    /// between the two meters to 48pt; he then read the result as too wide
    /// (2026-09-30 evening).  Most of that 48pt was buying slack the row did
    /// not need: a countdown is left-aligned in its frame, so a 48pt column
    /// showing "1h 7m" was really a 72pt gap.  Narrowing the countdown column
    /// to its measured widest value and setting the group gap to 28pt gives
    /// the same separation between the two windows for 20pt less width.
    ///
    /// See `glanceRowIntrinsicWidth` for the arithmetic this width has to
    /// satisfy, which the tests pin, together with the measured widths of the
    /// longest realistic values.
    static let glanceWidth: CGFloat = 570
    static let glanceMinHeight: CGFloat = 200
    static let glanceGutter: CGFloat = 12
    /// Tall enough that the 22pt controls have 9pt of air above and below.
    static let glanceHeaderHeight: CGFloat = 40
    /// Height of every control on the header's one line: the From Mac / From
    /// Fleet switch, the All bell and the refresh button.  They share one
    /// height so they share one centre line.
    static let glanceHeaderControlHeight: CGFloat = 22
    /// The space between "CodeCaps" and the From Mac / From Fleet switch.  It
    /// was the 10pt every header gap used, which read as cramped (owner delta,
    /// 2026-09-30); twice that sets the title apart from the controls.
    static let glanceHeaderTitleGap: CGFloat = 20
    /// The least space between the switch and the right-hand cluster.  The
    /// popover is wide, so the two only get this close if the cluster grows.
    static let glanceHeaderClusterGap: CGFloat = 16
    /// The space between neighbours inside the right-hand cluster: the All
    /// bell, a dot, the count, a dot, the time, and the refresh button.
    static let glanceHeaderItemGap: CGFloat = 10
    /// The side padding inside one segment of the switch.
    static let glanceHeaderSegmentPadding: CGFloat = 11
    /// The dots between the cluster's phrases.
    static let glanceHeaderDotSize: CGFloat = 3
    static let glanceFooterHeight: CGFloat = 38
    /// A source's heading band in From Fleet.
    static let glanceGroupHeaderHeight: CGFloat = 22
    /// The list's own padding above the first row and below the last.
    static let glanceListPadding: CGFloat = 8
    /// The hairline between two rows, and the `Divider` under the header and
    /// above the footer.
    static let glanceDividerHeight: CGFloat = 1
    /// The gap above the Set Up Fleet Sync card (and the gap between two
    /// sources' groups in From Fleet).
    static let glanceSetupGap: CGFloat = 12
    static let glanceGroupGap: CGFloat = 6
    /// Every row, From Mac or From Fleet: a fleet row's "reported at"
    /// moved to its source's heading, so it no longer needs a taller row.
    static let glanceLocalRowHeight: CGFloat = 38
    static let glanceCTARowHeight: CGFloat = 52
    /// One extra line of meters under an expanded row: the windows the row's
    /// own two meters leave out, in the same columns.
    static let glanceExpandedLineHeight: CGFloat = 28
    /// What an empty list's explanation needs: icon, title, two lines, button.
    static let glanceEmptyStateHeight: CGFloat = 170

    // Per-row column widths.  The two-meter row used to be laid out from
    // whatever space was left over, which is how a percentage ends up
    // truncated after a long platform name; these are fixed instead.
    /// The per-provider reset-alarm bell at the very left, shown while All is off.
    static let glanceAlarmBellWidth: CGFloat = 16
    static let glanceLogoWidth: CGFloat = 16
    /// Fits "Claude Code" (79.5pt at 13pt medium), the longest platform name.
    static let glanceRowTitleWidth: CGFloat = 80
    /// Fits "Plan" and "24h" at 11pt medium; "Quota" fits at its 0.8 scale.
    static let glanceMeterCaptionWidth: CGFloat = 26
    /// The gap between the parts inside one meter: caption, bar, percentage
    /// and countdown.
    static let glanceMeterGap: CGFloat = 4
    static let glanceMeterBarWidth: CGFloat = 50
    /// The bar's thickness: 1.5x the 4pt it was before the 2026-09-30 delta.
    static let glanceMeterBarHeight: CGFloat = 6
    /// The elapsed marker's full height, twice the 8pt it was, so the black
    /// tick reads at a glance against the thicker bar.  Same 2pt width.
    static let glanceMeterMarkerHeight: CGFloat = 16
    /// "100%" is 32.2pt at 11pt medium with monospaced digits.  The rest of
    /// the column is the gap before the countdown, so the two never touch.
    static let glanceMeterPercentWidth: CGFloat = 44
    /// A countdown carries at most its two largest units ("17d 4h", "2h 42m"),
    /// so the widest realistic value is "31d 23h" or "29d 59m", measured at
    /// 49pt by `testTheLongestCountdownsFitTheirColumn`.  The full value lives
    /// in the countdown's tooltip.
    static let glanceMeterCountdownWidth: CGFloat = 50
    static let glanceChevronWidth: CGFloat = 10
    /// The fixed gap between the row's columns, used by every spacer so one
    /// change re-tunes the whole row.
    static let glanceColumnGap: CGFloat = 8
    /// The gap between the two meters: from the end of the first countdown to
    /// the second meter's caption.  It was doubled to 48pt on 2026-09-30 and
    /// the owner then read the row as too sparse, so it came back down to 28pt
    /// (owner delta, 2026-09-30 evening).  Still three and a half times the
    /// 8pt column gap, so the two windows still read as two columns — the
    /// countdown is left-aligned in its frame, which put a further ~18pt of
    /// visual slack on the end of every 54pt column, and that is most of what
    /// 48pt was actually buying.
    static let glanceMeterGroupGap: CGFloat = 28
    /// The gap right after the logo, which is tighter than the rest.
    static let glanceLogoGap: CGFloat = 6

    /// How wide one meter is: caption, gap, bar, gap, percent, gap, countdown.
    static let glanceMeterWidth: CGFloat = glanceMeterCaptionWidth + glanceMeterGap + glanceMeterBarWidth
        + glanceMeterGap + glanceMeterPercentWidth + glanceMeterGap + glanceMeterCountdownWidth

    /// Both meters and the gap between them, which is the width a row's meter
    /// area occupies whether it holds two meters, one meter (in the first
    /// column, never centred), or none.  Reserving it unconditionally is what
    /// stops a row with a single reading from shifting in the popover.
    static let glanceMetersWidth: CGFloat = glanceMeterWidth * 2 + glanceMeterGroupGap

    /// Where a meter's bar starts, measured from the start of its column.  A
    /// row with no reading puts its status text here, so "not signed in" sits
    /// exactly where the first bar of every row, single-meter rows included
    /// (Cursor's), begins.
    static let glanceMeterBarInset: CGFloat = glanceMeterCaptionWidth + glanceMeterGap

    /// The width a two-meter row actually occupies: the alarm bell, logo,
    /// title, two meters, the chevron, their gaps, and the popover's own
    /// horizontal gutter on both sides.
    ///
    /// This is the contract `glanceWidth` has to honour.  It is computed rather
    /// than restated so a column change cannot silently overflow the popover —
    /// a wider row inside a fixed frame is what truncated "Open CodeCaps ⌘1"
    /// in the footer once already.
    static let glanceRowIntrinsicWidth: CGFloat = glanceAlarmBellWidth + glanceLogoGap
        + glanceLogoWidth + glanceLogoGap
        + glanceRowTitleWidth + glanceColumnGap
        + glanceMeterWidth + glanceMeterGroupGap
        + glanceMeterWidth + glanceColumnGap
        + glanceChevronWidth
        + glanceGutter * 2

    static let consoleDefault = NSSize(width: 960, height: 640)
    static let consoleMin = NSSize(width: 820, height: 560)
    /// Default sidebar width, 40pt wider than the old fixed 200pt column.
    /// Was raised because the user found the original column too narrow
    /// for "Antigravity · Third-Party" rows with their subtitle pool line,
    /// and a trailing percent that had no breathing room.  See F-01 of
    /// `docs/design/2026-09-22-app-audit.md` for the audit this came from.
    static let sidebarWidthDefault: CGFloat = 240
    static let sidebarWidthMin: CGFloat = 200
    static let sidebarWidthMax: CGFloat = 400
    /// Kept for callers that want the previously-fixed value (none today,
    /// but the symbol documents the migration to a resizable column).
    static let sidebarWidth: CGFloat = sidebarWidthDefault
    static let toolbarHeight: CGFloat = 52
    static let pagePadding: CGFloat = 20

    /// The screen is the one the status item was clicked on, not `NSScreen.main`
    /// — that is the key window's screen, and nil when no window is key.
    static func glanceMaxHeight(on screen: NSScreen?) -> CGFloat {
        ((screen ?? NSScreen.main)?.visibleFrame.height ?? 720) - 24
    }
}

// MARK: - Shared status rules

/// The 20% threshold lives here and nowhere else.
func quotaStatusColor(for snapshot: QuotaWindowSnapshot, sourceFailed: Bool) -> Color {
    if !snapshot.isFresh || sourceFailed || snapshot.remainingPercent == nil { return .secondary }
    if snapshot.status == .exhausted { return Theme.danger }
    if (snapshot.remainingPercent ?? 100) <= 20 { return Theme.warning }
    return Theme.accent
}

/// Whether a bar should be drawn dimmed: the reading is old, or its source
/// failed.  These are the same cases that turn the "% remaining" text grey, so a
/// last-reported bar never looks as live as a fresh one.
func quotaBarIsDimmed(for snapshot: QuotaWindowSnapshot, sourceFailed: Bool) -> Bool {
    !snapshot.isFresh || sourceFailed
}

/// The one quota bar every surface draws: a full-width track that starts with a
/// red segment for the share used and ends with a green segment for the share
/// left, so 0% remaining is all red and 100% is all green.  A black marker sits
/// at the fraction of the period that has elapsed; red reaching past it means
/// the window is being burned faster than time passes.
///
/// An unknown reading keeps the neutral empty track and no segments.
struct QuotaUsageBar: View {
    let metrics: QuotaBarMetrics
    var height: CGFloat = 4
    var dimmed = false
    /// When set, the bar is its own accessibility element and speaks both shares
    /// and the elapsed fraction.  Left nil where the parent already speaks for
    /// the bar, so it is not read twice.
    var accessibilityLabel: String? = nil
    /// Extra words spoken after the metrics, such as the pace verdict.
    var accessibilitySuffix: String? = nil

    /// The marker's full height, when a surface wants it taller than the
    /// bar plus `markerOverhang` above and below.  Glance's thicker bar sets
    /// it; the Console keeps the default.
    var markerHeight: CGFloat? = nil

    /// How far the marker stands proud of the bar above and below.
    static let markerOverhang: CGFloat = 2
    static let markerWidth: CGFloat = 2
    /// How far the pale halo stands proud of the marker on each side.
    static let haloPadding: CGFloat = 1

    var body: some View {
        GeometryReader { geometry in
            let width = Double(geometry.size.width)
            let layout = metrics.markerLayout(in: width, barHeight: Double(geometry.size.height),
                                              markerWidth: Double(Self.markerWidth),
                                              haloPadding: Double(Self.haloPadding))
            ZStack(alignment: .leading) {
                bar(width: width)
                if let layout {
                    let markerHeight = self.markerHeight ?? geometry.size.height + Self.markerOverhang * 2
                    Rectangle().fill(Theme.pacingMarkerHalo)
                        .frame(width: CGFloat(layout.haloWidth), height: markerHeight + Self.haloPadding * 2)
                        .position(x: CGFloat(layout.haloCenter), y: geometry.size.height / 2)
                    Rectangle().fill(Theme.pacingMarker)
                        .frame(width: Self.markerWidth, height: markerHeight)
                        .position(x: CGFloat(layout.center), y: geometry.size.height / 2)
                }
            }
        }
        .frame(height: height)
        .modifier(QuotaUsageBarAccessibility(
            label: accessibilityLabel,
            value: ([metrics.spokenSummary] + [accessibilitySuffix].compactMap { $0 }).joined(separator: ", ")))
    }
}

extension QuotaUsageBar {
    /// The bar itself: red for the share used and green for the share left, or
    /// the neutral track when there is no reading.  A share that is not drawn
    /// (0% used, 0% left) is not in the view at all.
    @ViewBuilder
    fileprivate func bar(width: Double) -> some View {
        if let widths = metrics.segmentWidths(in: width) {
            HStack(spacing: 0) {
                if widths.used > 0 {
                    Rectangle().fill(Theme.barUsed).frame(width: CGFloat(widths.used))
                }
                if widths.remaining > 0 {
                    Rectangle().fill(Theme.barRemaining).frame(width: CGFloat(widths.remaining))
                }
            }
            .clipShape(Capsule())
            .opacity(dimmed ? 0.45 : 1)
        } else {
            Capsule().fill(Theme.track)
        }
    }
}

private struct QuotaUsageBarAccessibility: ViewModifier {
    let label: String?
    let value: String

    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(value)
        } else {
            content.accessibilityHidden(true)
        }
    }
}

func compactWindowName(_ label: String) -> String {
    let display = AntigravityDisplay.windowLabel(label)
    // An Antigravity window says which pool it belongs to.  A compact row
    // shortens the cadence and keeps the pool, because "5h" alone is what made
    // two different pools look like one number.
    if let pool = AntigravityDisplay.poolName(in: display), let separator = display.range(of: " · ") {
        let cadence = String(display[separator.upperBound...])
        let shortCadence = cadence.lowercased().contains("5") ? "5h" : cadence
        return "\(pool) · \(shortCadence)"
    }
    let lower = display.lowercased()
    // A month is "1m" on every compact surface, Glance's captions included.
    if lower.contains("month") || lower.contains("billing") || lower == "included plan" { return "1m" }
    if lower.contains("5-hour") || lower.contains("5 hour") { return "5h" }
    if lower.contains("7-day") || lower.contains("7 day") { return "7d" }
    if lower.contains("weekly") { return "Weekly" }
    if lower.contains("daily") { return "Daily" }
    if lower.contains("fast request") { return "Fast" }
    if lower.contains("slow request") { return "Slow" }
    if lower.contains("session") { return "Session" }
    if lower.contains("claude 3.5") || lower.contains("sonnet") { return "Sonnet" }
    if lower.contains("gemini pro") || lower.contains("pro") { return "Pro" }
    if lower.contains("flash") { return "Flash" }
    if lower.contains("opus") { return "Opus" }
    return display.components(separatedBy: " ").first ?? display
}

func compactResetCountdown(_ reset: Date?, now: Date) -> String {
    guard let reset else { return "" }
    let seconds = reset.timeIntervalSince(now)
    guard seconds > 0 else { return "⟳" }
    let minutes = max(1, Int(ceil(seconds / 60)))
    if minutes >= 1440 { return "\(minutes / 1440)d" }
    if minutes >= 60 { return "\(minutes / 60)h" }
    return "\(minutes)m"
}

/// The one badge slot: `LIVE`, `LAST REPORT` or `FLEET`.  A pulled window is by
/// definition somebody else's observation, so it never claims to be live.
struct StatusBadge: View {
    enum Kind { case live, lastReport, fleet }
    let kind: Kind

    private var text: String {
        switch kind {
        case .live: return "LIVE"
        case .lastReport: return "LAST REPORT"
        case .fleet: return "FLEET"
        }
    }

    private var color: Color {
        switch kind {
        case .live: return Theme.accent
        case .lastReport: return Theme.warning
        case .fleet: return Theme.fleet
        }
    }

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
            .accessibilityHidden(true)
    }
}

/// The group eyebrow: `QUOTAS`, `THIS MAC`, `SHARE THIS MAC`, `DISPLAY`.
struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
            .accessibilityAddTraits(.isHeader)
    }
}

extension QuotaPlatformSection {
    /// The single subtitle rule, replacing three near-identical copies that
    /// disagreed about the Antigravity fallback.
    func displaySubtitle(customInfo: PlatformCustomInfo?) -> String? {
        if let custom = customInfo, !custom.customSubtitle.isEmpty {
            return custom.customSubtitle
        }
        if let custom = customInfo, custom.showCostAndRenewal {
            let renewal = custom.renewalDateText.isEmpty
                ? (BillingRenewal.text(for: windows.map(\.window)) ?? "")
                : custom.renewalDateText
            let parts = [custom.planName,
                         custom.costUsd,
                         renewal.isEmpty ? "" : "Renews \(renewal)"]
                .filter { !$0.isEmpty }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
        }
        if via == "antigravity" { return "Antigravity subscription" }
        if let plan = windows.compactMap(\.window.planName).first, !plan.isEmpty { return plan }
        return nil
    }

    /// The window a one-line row speaks for: whichever is closest to its cap.
    var drivingWindow: QuotaWindowSnapshot? {
        let primary = windows.filter { !$0.window.isSupplementaryVideoQuota }
        return primary.filter { $0.remainingPercent != nil }
            .min { ($0.remainingPercent ?? 100) < ($1.remainingPercent ?? 100) }
            ?? primary.first
    }

    /// The lowest remaining percentage across the windows a sidebar row summarises.
    var minimumRemainingPercent: Double? {
        windows.filter { $0.isFresh && !$0.window.isSupplementaryVideoQuota }
            .compactMap(\.remainingPercent)
            .min()
    }
}

/// Glance's height is computed from the EXPECTED provider count rather than the
/// reporting count, so the popover cannot resize under the pointer when a
/// platform appears or disappears between refreshes.  It is the taller of the
/// two views, so flipping between From Mac and From Fleet while the
/// popover is open never resizes it either.
enum QuotaGlanceMetrics {
    /// The height of the From Mac list: its rows, the hairline between each
    /// pair, and the Set Up Fleet Sync card with its gap when it is shown.
    static func localListHeight(rows: Int, showsSetupCard: Bool, isEmpty: Bool) -> CGFloat {
        let body = isEmpty
            ? Metrics.glanceEmptyStateHeight
            : CGFloat(rows) * Metrics.glanceLocalRowHeight + CGFloat(max(0, rows - 1)) * Metrics.glanceDividerHeight
        let card = showsSetupCard ? Metrics.glanceSetupGap + Metrics.glanceCTARowHeight : 0
        return body + card
    }

    /// The height of the From Fleet list: a heading band per source, its rows and
    /// the hairlines between them, and a gap between one group and the next.
    static func fleetListHeight(rowsPerGroup: [Int]) -> CGFloat {
        guard !rowsPerGroup.isEmpty else { return Metrics.glanceEmptyStateHeight }
        let rows = rowsPerGroup.reduce(0, +)
        let hairlines = rowsPerGroup.reduce(0) { $0 + max(0, $1 - 1) }
        return CGFloat(rowsPerGroup.count) * Metrics.glanceGroupHeaderHeight
            + CGFloat(rowsPerGroup.count - 1) * Metrics.glanceGroupGap
            + CGFloat(rows) * Metrics.glanceLocalRowHeight
            + CGFloat(hairlines) * Metrics.glanceDividerHeight
    }

    /// The popover around a list: header, footer, the two dividers beside
    /// them, and the list's padding above and below.
    static func popoverHeight(forListHeight list: CGFloat) -> CGFloat {
        Metrics.glanceHeaderHeight + Metrics.glanceFooterHeight
            + 2 * Metrics.glanceDividerHeight
            + 2 * Metrics.glanceListPadding
            + list
    }

    @MainActor
    static func expectedLocalRows(for model: MonitorModel) -> Int {
        let reported = Set(model.sections.map(\.providerKey))
        let expectedKeys = Set(expectedQuotaProviderKeys).union(reported)
        // Antigravity draws one row per model pool, so it counts twice.
        return expectedKeys.count + (expectedKeys.contains(AntigravityDisplay.providerKey) ? 1 : 0)
    }

    @MainActor
    static func popoverHeight(for model: MonitorModel, on screen: NSScreen? = nil) -> CGFloat {
        let local = localListHeight(
            rows: expectedLocalRows(for: model),
            showsSetupCard: !model.syncEnabled && !model.serverEnabled,
            isEmpty: !(model.localEnabled || !model.displaySections.isEmpty))
        let fleet = fleetListHeight(rowsPerGroup: model.fleetGroups.map { $0.rows.count })
        let total = popoverHeight(forListHeight: max(local, fleet))
        return min(Metrics.glanceMaxHeight(on: screen), max(Metrics.glanceMinHeight, total))
    }
}

// MARK: - Console detail components

struct SummaryTile: View {
    let label: String
    let value: String
    let symbol: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(label, systemImage: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
        .padding(16)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        .accessibilityElement(children: .combine)
    }
}

/// A bordered container with a header and one or more `QuotaRow`s.  Cards exist
/// only in the Console detail pane; rows exist only in Glance and the sidebar.
struct PlatformCard: View {
    let row: DisplaySection
    let now: Date
    let issue: String?
    let compact: Bool
    var wide = false
    var origin: QuotaOrigin = .local
    var customInfo: PlatformCustomInfo? = nil
    var markStyle: MarkStyle = .template
    /// Whether this provider's reset alarm is on.  The bell shows only while
    /// alarms are picked per provider; under All there is nothing to pick.
    var isAlarmArmed: Bool = false
    var onToggleAlarm: (() -> Void)? = nil
    /// Set only when the issue is one the owner can actually fix in Settings —
    /// today, the one-time Allow Access To Claude Code step.  The card then
    /// carries the same deep link the fleet banner uses.
    var onOpenSettings: (() -> Void)? = nil
    @State private var expanded = false
    @State private var videoExpanded = false

    private var section: QuotaPlatformSection { row.section }

    private var primaryWindows: [QuotaWindowSnapshot] {
        section.windows.filter { !$0.window.isSupplementaryVideoQuota }
    }
    private var videoWindows: [QuotaWindowSnapshot] {
        section.windows.filter { $0.window.isSupplementaryVideoQuota }
    }
    private var displayedWindows: [QuotaWindowSnapshot] {
        expanded ? primaryWindows : Array(primaryWindows.prefix(4))
    }
    private var subtitleText: String? {
        if origin == .fleet {
            return section.drivingWindow?.window.source
        }
        return section.displaySubtitle(customInfo: customInfo)
    }
    private var badge: StatusBadge.Kind {
        if origin == .fleet { return .fleet }
        return issue == nil && section.hasFreshReport ? .live : .lastReport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 12 : 16) {
            header
            if section.windows.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quota unavailable")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(issue ?? "no quota source connected")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    openSettingsButton
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                windowsBody
            }
        }
        .padding(compact ? 12 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.hairline))
        .opacity(issue == nil ? 1 : 0.72)
    }

    private var header: some View {
        HStack(spacing: 10) {
            PlatformLogo(providerKey: row.id, size: compact ? 22 : 28, style: markStyle)
                .frame(width: compact ? 24 : 30, height: compact ? 24 : 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(section.providerLabel)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if let subtitleText {
                    Text(subtitleText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        // Subtitle strings like "Google AI Ultra (5x) · $100/mo
                        // · Renews on 5th, but ↓ $50/mo plan then (1x ..." run
                        // past 60+ chars; clipping at one line turns the price
                        // and renewal hint into "..." before the owner can read
                        // them.  Two lines plus tail truncation keeps the lead
                        // visible and shortens the tail cleanly.
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 6)
            if let onToggleAlarm {
                Button {
                    onToggleAlarm()
                } label: {
                    Image(systemName: isAlarmArmed ? "bell.fill" : "bell")
                        .font(.system(size: compact ? 12 : 14))
                        .foregroundStyle(isAlarmArmed ? Theme.accent : .secondary)
                }
                .buttonStyle(.plain)
                .help(isAlarmArmed
                      ? "Reset alarm is on for this provider." + sentenceGap + "Click to turn it off."
                      : "Reset alarm is off for this provider." + sentenceGap + "Click to turn it on.")
                .accessibilityLabel("Reset Alarm")
                .accessibilityValue(isAlarmArmed ? "on" : "off")
            }
            if !section.windows.isEmpty { StatusBadge(kind: badge) }
        }
    }

    @ViewBuilder
    private var windowsBody: some View {
        if wide && displayedWindows.count > 1 {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                      alignment: .leading, spacing: 16) {
                ForEach(displayedWindows, id: \.window.id) { snapshot in
                    QuotaRow(snapshot: snapshot, now: now, sourceFailed: issue != nil, compact: compact,
                             masked: row.isMasked(snapshot))
                        .padding(12)
                        .background(Theme.background, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        } else {
            ForEach(Array(displayedWindows.enumerated()), id: \.offset) { index, snapshot in
                if index > 0 { Divider() }
                QuotaRow(snapshot: snapshot, now: now, sourceFailed: issue != nil, compact: compact,
                         masked: row.isMasked(snapshot))
            }
        }
        if primaryWindows.count > 4 {
            Button(expanded ? "Show Less" : "Show All \(primaryWindows.count) Windows") {
                expanded.toggle()
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Theme.accent)
        }
        if !videoWindows.isEmpty {
            Divider()
            DisclosureGroup(isExpanded: $videoExpanded) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(videoWindows, id: \.window.id) { snapshot in
                        QuotaRow(snapshot: snapshot, now: now, sourceFailed: issue != nil, compact: true)
                    }
                }
                .padding(.top, 8)
            } label: {
                Label("Video · \(videoWindows.count) Windows", systemImage: "video")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        if let issue {
            Label(issue, systemImage: "exclamationmark.circle")
                .font(.system(size: 11))
                .foregroundStyle(Theme.warning)
                .fixedSize(horizontal: false, vertical: true)
            openSettingsButton
        }
    }

    @ViewBuilder
    private var openSettingsButton: some View {
        if let onOpenSettings {
            Button("Open Settings", action: onOpenSettings)
                .controlSize(.small)
                .help("Open Settings")
                .accessibilityLabel("Open Settings")
                .padding(.top, 2)
        }
    }
}

struct QuotaRow: View {
    let snapshot: QuotaWindowSnapshot
    let now: Date
    let sourceFailed: Bool
    let compact: Bool
    /// True for a five-hour Antigravity window whose pool's weekly cap is spent.
    /// Its percentage is real and meaningless, so it is never shown as a number.
    var masked = false

    private var tint: Color {
        masked ? .secondary : quotaStatusColor(for: snapshot, sourceFailed: sourceFailed)
    }
    private var percentText: String {
        if masked { return AntigravityDisplay.maskedValue }
        return snapshot.remainingPercent.map { "\(Int($0.rounded()))%" } ?? "—"
    }
    private var barMetrics: QuotaBarMetrics { QuotaBarMetrics(snapshot: snapshot, now: now) }
    private var barDimmed: Bool { quotaBarIsDimmed(for: snapshot, sourceFailed: sourceFailed) }
    private var stateText: String {
        if masked { return "not applicable" }
        if snapshot.remainingPercent == nil { return "unavailable" }
        return snapshot.isFresh && !sourceFailed ? "remaining" : "last reported"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(compact ? compactWindowName(snapshot.window.label)
                             : AntigravityDisplay.windowLabel(snapshot.window.label))
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 10)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(percentText)
                        .font(.system(size: compact ? 18 : 22, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(tint)
                    Text(stateText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            if masked {
                Text(AntigravityDisplay.maskedCaption)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let pacing = snapshot.pacing(now: now), !compact {
                pacingBar(pacing)
            } else if barMetrics.hasReading {
                QuotaUsageBar(metrics: barMetrics, height: 5, dimmed: barDimmed,
                              accessibilityLabel: "Quota Usage")
            }

            if let remaining = snapshot.window.absoluteRemaining,
               let limit = snapshot.window.absoluteLimit,
               remaining.isFinite, limit.isFinite, remaining >= 0, limit > 0,
               let unit = snapshot.window.quotaUnit {
                Text("\(remaining.formatted(.number.precision(.fractionLength(0...1)))) of \(limit.formatted(.number.precision(.fractionLength(0...1)))) \(unit) left")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath").accessibilityHidden(true)
                Text(resetCountdown(snapshot.resetAt, now: now))
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)

            if let reset = snapshot.resetAt, !compact {
                Text(reset.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            if !compact {
                HStack(spacing: 6) {
                    Text(snapshot.observedAt.map { "Updated \($0.formatted(date: .omitted, time: .shortened))" }
                         ?? "update time unavailable")
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 6)
                    if snapshot.observedAt == nil { Text("not reported") }
                    else if snapshot.isStale { Text("stale").foregroundStyle(Theme.warning) }
                    else if let source = snapshot.window.source {
                        Text(source)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .foregroundStyle(.tertiary)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func pacingBar(_ pacing: WindowPacing) -> some View {
        let paceLabel = pacing.isUnderCapPace ? "Under cap pace" : "Over cap pace"
        return VStack(alignment: .leading, spacing: 5) {
            // The same red-used, green-remaining bar Glance draws, with the
            // marker at how far through the period we are.  The frame leaves
            // room for the marker to stand proud of the bar.
            QuotaUsageBar(metrics: barMetrics, height: 5, dimmed: barDimmed,
                          accessibilityLabel: "Quota Pacing",
                          accessibilitySuffix: paceLabel.lowercased())
                .frame(height: 10)

            HStack(spacing: 6) {
                HStack(spacing: 4) {
                    Rectangle().fill(Theme.pacingMarker)
                        .frame(width: QuotaUsageBar.markerWidth, height: 9)
                        .accessibilityHidden(true)
                    Text("time elapsed · \(pacing.timeElapsedLabel.lowercased())")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                HStack(spacing: 3) {
                    Image(systemName: pacing.isUnderCapPace ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                    Text(paceLabel)
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(pacing.isUnderCapPace ? Theme.accent : Theme.warning)
            }
        }
        .padding(.vertical, 2)
    }
}
