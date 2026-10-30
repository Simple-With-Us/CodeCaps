import AppKit
import QuotaCore
import SwiftUI

/// Every dimension and every responsive decision the PiP HUD makes, in one
/// place, so the AppKit panel that sizes the window and the SwiftUI view that
/// draws inside it cannot disagree.
///
/// The numbers are declared once and the thresholds are *derived* from them.
/// A breakpoint hand-tuned to match a drawing is a breakpoint that silently
/// rots the next time a constant moves; these are computed, so they cannot.
enum PipMetrics {
    // MARK: Structure

    static let padding: CGFloat = 8
    static let cornerRadius: CGFloat = 12
    static let rowHeight: CGFloat = 20
    static let bodyVerticalPadding: CGFloat = 4
    static let topDragAreaHeight: CGFloat = 8

    // MARK: Row parts

    static let rowSpacing: CGFloat = 4
    static let meterSpacing: CGFloat = 3
    static let providerLogoSize: CGFloat = 14
    static let titleFontSize: CGFloat = 11
    static let titleWidth: CGFloat = 150
    static let cadenceWidth: CGFloat = 18
    static let cadenceExpandedWidth: CGFloat = 40
    /// Wide enough for "100%" in bold monospaced digits at 10pt, left-aligned so
    /// a long number never clips: the owner saw "100%" lose a couple of points
    /// at the narrow end when it was right-aligned into a tight frame.
    ///
    /// 32, not 30: the rendered "100%" measures 31 points at 10pt bold
    /// monospaced, and the percentage is a fixed-size text, so a 30 point
    /// column clipped its last digit.
    static let percentWidth: CGFloat = 32
    static let countdownWidth: CGFloat = 42
    static let countdownCompactWidth: CGFloat = 28
    static let barMinWidth: CGFloat = 20
    static let barHeight: CGFloat = 4

    /// The gap between a percentage and its reset countdown.
    ///
    /// Its own constant because it is a gap *inside* the meter's trailing
    /// column, while `meterSpacing` is the gap between the meter's own parts.
    static let countdownGap: CGFloat = 6

    /// Reserve only the width the pinned names use, up to the existing title
    /// limit.  The same column drives both rendering and the responsive ladder.
    @MainActor
    static func titleColumnWidth(for titles: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: titleFontSize, weight: .medium)
        guard let widest = titles.map({ ($0 as NSString).size(withAttributes: [.font: font]).width }).max() else {
            return titleWidth
        }
        return min(titleWidth, ceil(widest))
    }

    // MARK: Floating controls

    /// The close/back control floats over the rows rather than living in a band
    /// of its own (owner, 2026-10-08), so it is inset from the corner rather
    /// than laid out beside a title.
    static let controlInset: CGFloat = 4
    static let controlHitSize: CGFloat = 18

    // MARK: Expanded platform detail

    /// One line per window in the expanded platform detail.
    static let detailRowHeight: CGFloat = 16
    /// How far apart the expanded rows sit when the panel is tight.
    static let detailRowSpacingMin: CGFloat = 3
    /// How far apart the expanded rows sit when the panel has room to spare.
    static let detailRowSpacingMax: CGFloat = 40
    /// The bar in the expanded detail does not stretch across the whole panel.
    static let detailBarMaxWidth: CGFloat = 220

    // MARK: Panel bounds

    static let minWidth: CGFloat = 110
    static let maxWidth: CGFloat = 520
    /// One row plus body padding and top drag area.
    static let minHeight: CGFloat = rowHeight + bodyVerticalPadding * 2 + topDragAreaHeight
    static let maxHeight: CGFloat = 460

    /// A window with no dual-meter row opens comfortably wide without being
    /// wider than it needs to look.
    static let singleMeterDefaultWidth: CGFloat = 430

    // MARK: Derived widths

    /// The narrowest one meter can be and still show caption, bar and percent.
    static let meterMinWidth: CGFloat =
        cadenceWidth + meterSpacing + barMinWidth + meterSpacing + percentWidth

    /// The same meter plus its reset countdown.
    ///
    /// The countdown is a separate trailing column inside the meter, so the
    /// gap that separates it from the percentage is the inner one.
    static let meterMinWidthWithCountdown: CGFloat =
        meterMinWidth + countdownGap + countdownWidth

    /// The same meter plus its compact reset countdown.
    static let meterMinWidthWithCompactCountdown: CGFloat =
        meterMinWidth + countdownGap + countdownCompactWidth

    /// Caption-less meter: bar and percent only.
    ///
    /// No leading gap, because there is no caption to gap from: the bar sits
    /// directly against the meter.  That is what lets the smallest HUD carry a
    /// provider logo and two meters in a narrow window (owner, 2026-10-28).
    static let bareMeterMinWidth: CGFloat =
        barMinWidth + meterSpacing + percentWidth

    /// Provider logo, title, and two fully-labelled meters.
    static let fullMinWidth: CGFloat =
        providerLogoSize + rowSpacing + titleWidth + rowSpacing
        + meterMinWidthWithCountdown + rowSpacing + meterMinWidthWithCountdown

    /// Provider logo and two meters with 2-unit countdowns; platform name dropped first.
    static let logoWithCountdownMinWidth: CGFloat =
        providerLogoSize + rowSpacing
        + meterMinWidthWithCountdown + rowSpacing + meterMinWidthWithCountdown

    /// Provider logo and two meters with 1-unit rounded countdowns; platform name dropped.
    static let logoWithCompactCountdownMinWidth: CGFloat =
        providerLogoSize + rowSpacing
        + meterMinWidthWithCompactCountdown + rowSpacing + meterMinWidthWithCompactCountdown

    /// Provider logo and two meters, countdowns and title dropped (platform name dropped first).
    static let logoOnlyMinWidth: CGFloat =
        providerLogoSize + rowSpacing + meterMinWidth + rowSpacing + meterMinWidth

    /// Legacy alias so any existing reference compiles cleanly.
    static let noCountdownMinWidth: CGFloat = logoOnlyMinWidth

    /// Provider logo and two bare meters: no caption, no countdown.
    static let logoBareMetersMinWidth: CGFloat =
        providerLogoSize + rowSpacing + bareMeterMinWidth + rowSpacing + bareMeterMinWidth

    /// Provider logo and one bare meter.  The floor: the logo survives to the
    /// very smallest window the owner can drag the panel to.
    static let logoSingleMeterMinWidth: CGFloat =
        providerLogoSize + rowSpacing + bareMeterMinWidth

    /// The narrowest one line of the expanded platform detail can be and still
    /// show the cadence caption, the percentage and the bar.
    static let detailRowMinWidth: CGFloat =
        cadenceWidth + meterSpacing + percentWidth + meterSpacing + barMinWidth

    /// The same line plus its reset countdown.
    static let detailRowMinWidthWithCountdown: CGFloat =
        detailRowMinWidth + meterSpacing + countdownWidth

    /// The least room a window label needs before it is worth showing.
    static let detailLabelMinWidth: CGFloat = 24

    /// The most a window label may take.  The bar needs the room more.
    static let detailLabelMaxWidth: CGFloat = 120

    /// The narrowest the words beside a capped row's extra balance can be.
    ///
    /// "extra" measures about 29 points at 10pt semibold and is allowed to
    /// shrink to 70% of that, so 22 points is the least room in which the
    /// word still reads.
    static let extraBalanceTextMinWidth: CGFloat = 22

    // MARK: Responsive detail

    /// How much of a row survives at a given panel width, richest first.
    ///
    /// The platform name is dropped before the countdown disappears:
    /// `full > logoWithFullCountdown > logoWithCompactCountdown > logoOnly > logoBareMeters > logoSingleMeter`.
    ///
    /// Every level keeps the provider logo.  The logo is 14 points wide; the
    /// name is up to 150.  When the window narrows the meters need that room
    /// more than the name does, but a row with no logo is a row nobody can
    /// identify (owner, 2026-10-28).
    enum Detail: Int, CaseIterable, Comparable {
        /// Bar, percent, 2-unit reset countdown; provider logo and title.
        case full
        /// Two meters with 2-unit countdowns; provider logo kept, platform name dropped.
        case logoWithFullCountdown
        /// Two meters with 1-unit rounded-up countdowns; provider logo kept, platform name dropped.
        case logoWithCompactCountdown
        /// Two meters, countdowns and platform name dropped; provider logo kept.
        case logoOnly
        /// Two bare meters -- bar and percent each -- with the provider logo kept.
        case logoBareMeters
        /// One bare meter with the provider logo kept.  The floor.
        case logoSingleMeter

        /// Legacy alias for tests.
        static let noCountdown = Detail.logoOnly

        static func < (lhs: Detail, rhs: Detail) -> Bool { lhs.rawValue > rhs.rawValue }

        /// The most meters this level can draw.
        var maxMeters: Int {
            switch self {
            case .full, .logoWithFullCountdown, .logoWithCompactCountdown, .logoOnly, .logoBareMeters: return 2
            case .logoSingleMeter: return 1
            }
        }

        /// The fewest meters this level makes sense with.
        ///
        /// A level that needs two meters is skipped for a row that publishes
        /// one, so the ladder never carries a rung that renders exactly like
        /// the rung below it.
        var minMeters: Int {
            switch self {
            case .logoBareMeters: return 2
            default: return 1
            }
        }

        var showsCountdown: Bool {
            self == .full || self == .logoWithFullCountdown || self == .logoWithCompactCountdown
        }

        var usesCompactCountdown: Bool {
            self == .logoWithCompactCountdown
        }

        var showsCadence: Bool {
            self != .logoBareMeters && self != .logoSingleMeter
        }

        /// Every level keeps the logo: it is the cheapest way to say which
        /// platform a row is, and it survives to the floor.
        var showsProviderLogo: Bool { true }

        /// The platform name drops before the countdown: only `.full` keeps the title.
        var showsTitle: Bool {
            self == .full
        }
    }

    /// The richest level whose content fits `width`, content width being what
    /// survives the panel's own padding.
    static func detail(forWidth width: CGFloat, titleWidth: CGFloat = PipMetrics.titleWidth,
                       hasFlame: Bool = false, meterCount: Int = 2, expandedCadence: Bool = false,
                       allowsTitle: Bool = true) -> Detail {
        let available = width - padding * 2
        for detail in Detail.allCases {
            // The name is the richest thing on the row and the first thing
            // the owner is willing to lose, so a row that is not allowed to
            // print it never selects the level that carries it.
            if detail == .full && !allowsTitle { continue }
            // A level that needs two meters is skipped when the row has one:
            // otherwise it would render exactly like the level below it.
            if detail.minMeters > max(1, meterCount) { continue }
            if available >= rowWidth(for: detail, hasFlame: hasFlame, titleWidth: titleWidth,
                                     meterCount: meterCount, expandedCadence: expandedCadence) {
                return detail
            }
        }
        return .logoSingleMeter
    }

    // MARK: Horizontal rows

    /// How much of the NEXT row must be visible for a horizontal strip to be
    /// worth switching to.  Less than this and the owner sees a full row and a
    /// sliver, which reads as a clipped row rather than as "there is more".
    static let horizontalPeek: CGFloat = 64

    /// The width one row needs at a given detail level.
    ///
    /// `hasFlame` widens the row when a usage spike puts the flame beside the
    /// logo.  It has to be part of this and not just an extra padding on the
    /// row.  Responsive selection and the horizontal frame use the same
    /// budget, so the icon cannot consume width the layout did not reserve.
    static func rowWidth(for detail: Detail, hasFlame: Bool = false,
                         titleWidth: CGFloat = PipMetrics.titleWidth,
                         meterCount: Int = 2, expandedCadence: Bool = false) -> CGFloat {
        let count = max(1, min(meterCount, detail.maxMeters))
        let identityWidth: CGFloat
        let meterWidth: CGFloat
        switch detail {
        case .full:
            identityWidth = providerLogoSize + rowSpacing + titleWidth + rowSpacing
            meterWidth = meterMinWidthWithCountdown
                + (expandedCadence ? cadenceExpandedWidth - cadenceWidth : 0)
        case .logoWithFullCountdown:
            identityWidth = providerLogoSize + rowSpacing
            meterWidth = meterMinWidthWithCountdown
        case .logoWithCompactCountdown:
            identityWidth = providerLogoSize + rowSpacing
            meterWidth = meterMinWidthWithCompactCountdown
        case .logoOnly:
            identityWidth = providerLogoSize + rowSpacing
            meterWidth = meterMinWidth
        case .logoBareMeters, .logoSingleMeter:
            identityWidth = providerLogoSize + rowSpacing
            meterWidth = bareMeterMinWidth
        }
        let base = identityWidth + CGFloat(count) * meterWidth + CGFloat(count - 1) * rowSpacing
        return hasFlame && detail.showsProviderLogo ? base + flameWidth : base
    }

    /// Shorten cadence words before sacrificing the provider name.
    static func expandedCadenceFits(forWidth width: CGFloat, titleWidth: CGFloat,
                                    hasFlame: Bool, meterCount: Int, allowsTitle: Bool = true) -> Bool {
        width >= padding * 2 + rowWidth(for: allowsTitle ? .full : .logoWithFullCountdown,
                                        hasFlame: hasFlame, titleWidth: titleWidth,
                                        meterCount: meterCount, expandedCadence: true)
    }

    /// The flame's own width plus its gap from the logo.  Fixed so the row
    /// arithmetic above can be exact rather than approximate.
    static let flameIconWidth: CGFloat = 10
    static let flameWidth: CGFloat = rowSpacing + flameIconWidth

    /// Whether the panel is wide enough to scroll its rows sideways.
    ///
    /// Owner 2026-10-10: "once it gets to where it is in the screenshot or
    /// actually 80-100 pixels wider than that so that it could still have
    /// platform logos at the left … we could make it scroll left to right like
    /// it now does up and down."
    ///
    /// Derived rather than hardcoded to his 80-100 figure, because the number
    /// that matters is the row's own width at the detail level in force, which
    /// moves when names, meter count or caption style change.
    static func rowsScrollHorizontally(forWidth width: CGFloat, titleWidth: CGFloat = PipMetrics.titleWidth,
                                      hasFlame: Bool = false, meterCount: Int = 2,
                                      expandedCadence: Bool = false, allowsTitle: Bool = true) -> Bool {
        // The threshold uses the richest row width so it is monotonic in panel
        // width: deriving it from the detail level in force flipped the strip
        // on and off as a resize crossed the detail ladder (owner 2026-10-16:
        // "as you stretch it out it alternates between showing correctly or
        // not").
        width >= padding * 2 + rowWidth(for: allowsTitle ? .full : .logoWithFullCountdown,
                                        hasFlame: hasFlame, titleWidth: titleWidth,
                                        meterCount: meterCount, expandedCadence: expandedCadence)
               + horizontalPeek
    }

    /// The "N more pinned — scroll" line under the rows: a 9pt line plus its
    /// bottom padding.
    static let overflowHintHeight: CGFloat = 13

    /// How many rows fit in `height` without clipping, never fewer than one.
    ///
    /// When the rows overflow, the overflow hint sits under them and takes its
    /// height from the rows, so the count the hint reports is the count that
    /// is actually out of view.
    static func visibleRowCount(total: Int, height: CGFloat) -> Int {
        guard total > 0 else { return 0 }
        let available = height - bodyVerticalPadding * 2 - topDragAreaHeight
        guard available >= rowHeight else { return 1 }
        let fit = Int(available / rowHeight)
        if fit >= total { return total }
        return max(1, Int((available - overflowHintHeight) / rowHeight))
    }

    /// The panel size that shows every pinned row at the richest level the
    /// content can actually use.
    static func fitSize(rowCount: Int, hasDualMeterRow: Bool, allowsTitle: Bool = true) -> NSSize {
        let rows = CGFloat(max(1, rowCount))
        let height = rows * rowHeight + bodyVerticalPadding * 2 + topDragAreaHeight
        let width = hasDualMeterRow
            ? padding * 2 + (allowsTitle ? fullMinWidth : logoWithCountdownMinWidth)
            : max(singleMeterDefaultWidth, padding * 2 + logoSingleMeterMinWidth)
        return NSSize(
            width: min(maxWidth, max(minWidth, width)),
            height: min(maxHeight, max(minHeight, height))
        )
    }
}

/// Floating on-screen Picture-in-Picture (PiP) HUD widget for CodeCaps.
/// Keeps critical AI quota meters visible on top of all windows at all times.
@MainActor
final class PipWidgetController: NSObject, NSWindowDelegate {
    static let shared = PipWidgetController()

    private var panel: NSPanel?
    private weak var currentModel: MonitorModel?
    private var dragMonitor: PipDragMonitor?

    /// The pinned rows the panel was last sized for.  The panel is refitted only
    /// when this changes, so a size the owner chose by dragging is theirs to
    /// keep — but pinning a row, or a row disappearing from the model, always
    /// gets the window back to a size that actually fits its content.
    private var fittedRowSignature: [String] = []

    private override init() {
        super.init()
    }

    func update(model: MonitorModel) {
        self.currentModel = model
        guard model.isPipEnabled else {
            close()
            return
        }
        show(model: model)
    }

    func show(model: MonitorModel) {
        self.currentModel = model
        if let panel {
            panel.contentView = NSHostingView(rootView: PipWidgetView(model: model))
            applyLevel()
            applyFit(for: model)
            // The hosting view observes the model, so it is built once and
            // updated by the model itself.  Swapping it on every refresh
            // rebuilt the whole view hierarchy every poll and reset the
            // panel's intrinsic size.
            panel.orderFrontRegardless()
        } else {
            createPanel(model: model)
        }
    }

    func close() {
        dragMonitor = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// The console window while it sits elevated above the Glance popover
    /// (`popUpMenuWindow + 1`), or nil once it has been lowered.  Remembered
    /// rather than applied once: the panel is torn down and recreated at
    /// `.floating` whenever the PiP toggle on the elevated Dashboard page is
    /// flipped, and the HUD or the console can be moved while elevated.
    private weak var elevatedConsole: NSWindow?

    /// Records that `console` is elevated and lifts the PiP HUD above it, but
    /// only while the HUD's frame actually overlaps the console's frame.  A
    /// HUD left at `consoleLevel + 1` (103) would draw over the Dock and over
    /// other apps' menus, so it stays at `.floating` (3) whenever the console
    /// cannot occlude it.  Safe to call when the panel does not exist.
    func raise(above console: NSWindow) {
        elevatedConsole = console
        applyLevel()
    }

    /// Forgets the elevated console and restores the PiP HUD to its default
    /// `.floating` level.  Idempotent.
    func demoteToFloating() {
        elevatedConsole = nil
        applyLevel()
    }

    /// Re-derives the HUD level after the HUD or the elevated console moved
    /// or resized, so the promotion tracks the overlap that motivated it.
    func refreshLevel() {
        applyLevel()
    }

    /// `.floating` unless an elevated console's frame would cover the HUD,
    /// in which case one level above that console.
    private var desiredLevel: NSWindow.Level {
        let floating = NSWindow.Level.floating
        guard let panel,
              let console = elevatedConsole,
              console.level.rawValue > floating.rawValue,
              panel.frame.intersects(console.frame) else { return floating }
        return NSWindow.Level(console.level.rawValue + 1)
    }

    private func applyLevel() {
        guard let panel else { return }
        let level = desiredLevel
        if panel.level != level { panel.level = level }
    }

    private func createPanel(model: MonitorModel) {
        let rows = Self.targetRows(for: model)
        let initialSize = PipMetrics.fitSize(rowCount: rows.count,
            hasDualMeterRow: rows.contains { Self.meterCount(for: $0, now: model.now,
                issue: model.issues[$0.providerKey], disabledSources: model.disabledSources) > 1 },
            allowsTitle: model.pipShowProviderNames)
        let p = NSPanel(
            contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: initialSize),
            styleMask: PipMetrics.panelStyleMask,
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        // Start at `.floating`; `applyLevel()` below lifts the HUD again if it
        // is recreated (Dashboard toggle) while the console is still elevated
        // and its frame overlaps the console.
        p.level = .floating
        p.isMovableByWindowBackground = true
        // Borderless panel: the rounded SwiftUI surface is the whole window, so
        // there is no titlebar strip to keep invisible.  See `panelStyleMask`.
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // Resizable, but bounded: below `minWidth` a meter has no room for a
        // bar and a percentage, and a taller panel than this shows more rows
        // than the owner has providers.
        p.minSize = NSSize(width: PipMetrics.minWidth, height: PipMetrics.minHeight)
        p.maxSize = NSSize(width: PipMetrics.maxWidth, height: PipMetrics.maxHeight)
        p.setFrameAutosaveName("CodeCapsPipWidgetPanel")
        p.delegate = self
        p.contentView = NSHostingView(rootView: PipWidgetView(model: model))
        self.panel = p
        dragMonitor = PipDragMonitor(window: p)
        applyLevel()
        // Seed the signature from the rows the window is being created for, so
        // a restored size survives a relaunch instead of being overridden by
        // the very first refresh.
        fittedRowSignature = Self.rowSignature(for: model)
        p.orderFrontRegardless()
    }

    /// Grows the panel to whatever is pinned, but only when the pinned set has
    /// actually changed.  A drag-resize by the owner is left alone.
    private func applyFit(for model: MonitorModel) {
        guard let panel else { return }
        let rows = Self.targetRows(for: model)
        let signature = rows.map(\.id)
        guard signature != fittedRowSignature else { return }
        fittedRowSignature = signature

        let hasDualMeterRow = rows.contains { Self.meterCount(for: $0, now: model.now,
            issue: model.issues[$0.providerKey], disabledSources: model.disabledSources) > 1 }
        let fit = PipMetrics.fitSize(rowCount: rows.count, hasDualMeterRow: hasDualMeterRow,
                                     allowsTitle: model.pipShowProviderNames)
        let clamped = NSSize(
            width: min(max(panel.frame.width, panel.minSize.width), panel.maxSize.width),
            height: min(max(fit.height, panel.minSize.height), panel.maxSize.height)
        )
        panel.setContentSize(clamped)
    }

    /// The HUD is movable by its background; re-check overlap with the
    /// elevated console after every drag.
    func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSWindow) === panel else { return }
        applyLevel()
    }

    func windowWillClose(_ notification: Notification) {
        currentModel?.isPipEnabled = false
        dragMonitor = nil
        panel = nil
    }

    // MARK: Row derivation

    /// The rows the HUD shows: the pinned ones, else the two lowest quotas.
    /// Shared with the controller's sizing so the panel and the view can never
    /// count different rows.
    static func targetRows(for model: MonitorModel) -> [DisplaySection] {
        let all = model.orderedPipDisplaySections()
        let selected = model.pipPinnedRowIds.union(model.pipAutoAddedRowIds)
        if !selected.isEmpty {
            let rows = all.filter { selected.contains($0.id) }
            if !rows.isEmpty { return rows }
        }
        // The default target set is what the HUD can honestly draw.  A row
        // whose provider failed cannot describe the current allowance, so it is
        // not a default target and it never displaces a row that can be
        // measured.  It is used only to fill a HUD that would otherwise have
        // nothing to show, and only after the rows that are quiet rather than
        // failed.  A pinned failed row still shows, because the user asked for
        // it and it reports its status instead of a cached quota.
        func remainingPercent(_ row: DisplaySection) -> Double {
            rankingPercent(for: row, now: model.now, issue: model.issues[row.providerKey],
                           disabledSources: model.disabledSources, peerRows: all)
        }
        func isMeasurable(_ row: DisplaySection) -> Bool {
            readingStatus(for: row, now: model.now, issue: model.issues[row.providerKey],
                          disabledSources: model.disabledSources, peerRows: all) == nil
        }
        let measurable = all.filter { isMeasurable($0) }
        let failed = all.filter { model.issues[$0.providerKey] != nil }
        let quiet = all.filter { !isMeasurable($0) && model.issues[$0.providerKey] == nil }
        var chosen = Array(measurable.sorted { remainingPercent($0) < remainingPercent($1) }.prefix(2))
        if chosen.count < 2 {
            chosen += Array(quiet.sorted { remainingPercent($0) < remainingPercent($1) }
                .prefix(2 - chosen.count))
        }
        if chosen.count < 2 {
            chosen += Array(failed.sorted { remainingPercent($0) < remainingPercent($1) }
                .prefix(2 - chosen.count))
        }
        return chosen.sorted { a, b in
            let aAvailable = isMeasurable(a)
            let bAvailable = isMeasurable(b)
            if aAvailable != bAvailable { return aAvailable }
            return remainingPercent(a) < remainingPercent(b)
        }
    }

    /// Cached or failed-source readings cannot describe the current allowance.
    /// When a row participates in a unified subscription pool (e.g. Cursor, xAI, Grok,
    /// Grok Bot), a fresh reading from any peer row is adopted if this row has none.
    static func currentWindows(for row: DisplaySection, now: Date, issue: String? = nil,
                               disabledSources: Set<String> = [],
                               peerRows: [DisplaySection] = []) -> [QuotaWindowSnapshot] {
        guard issue == nil else { return [] }
        let own = row.section.windows
            .filter { !$0.window.isSupplementaryVideoQuota && !row.isMasked($0)
                && !$0.window.remainingUnknown
                && !disabledSources.contains($0.window.source ?? "") }
            .map { QuotaWindowSnapshot(window: $0.window, now: now) }
            .filter { $0.isFresh && $0.remainingPercent != nil
                && (!$0.window.skip || $0.remainingPercent == 0) }
        if !own.isEmpty { return own }

        if UnifiedSubscriptionPool.participantKeys.contains(row.providerKey) {
            let candidates = peerRows
                .filter { $0.id != row.id && UnifiedSubscriptionPool.participantKeys.contains($0.providerKey) }
                .flatMap { peer in
                    currentWindows(for: peer, now: now, issue: nil,
                                   disabledSources: disabledSources, peerRows: []).map(\.window)
                }
            if let best = UnifiedSubscriptionPool.freshestReading(in: candidates, now: now) {
                let adapted = UnifiedSubscriptionPool.adapt(best, for: row.providerKey)
                return [QuotaWindowSnapshot(window: adapted, now: now)]
            }
        }
        return []
    }

    /// The extra balance a row may still spend, if the provider publishes one.
    ///
    /// The Muse Assist extra allowance is a *count*, not a percentage: it has
    /// no cap and no reset date, so `currentWindows` drops it -- a window with
    /// no remaining percentage cannot describe a quota.  Glance asks over the
    /// row's raw windows instead, which is why the menu bar window could say
    /// "using extra balance" while the HUD said "At Cap" (owner, 2026-10-28).
    ///
    /// The filter here is deliberately narrower than `currentWindows`: only the
    /// windows the row must not believe are dropped (masked, disabled, or a
    /// supplementary video quota).  The extra balance is then found the same
    /// way Glance finds it, so the two surfaces cannot disagree.
    ///
    /// A failed provider still claims nothing: `issue != nil` returns nil.
    static func usableMuseExtra(for row: DisplaySection, now: Date, issue: String? = nil,
                                 disabledSources: Set<String> = []) -> QuotaWindowSnapshot? {
        guard issue == nil else { return nil }
        let windows = row.section.windows
            .filter { !$0.window.isSupplementaryVideoQuota && !row.isMasked($0)
                && !disabledSources.contains($0.window.source ?? "") }
            .map { QuotaWindowSnapshot(window: $0.window, now: now) }
        return glanceUsableMuseExtra(windows)
    }

    /// The percentage a row may be ranked by when the HUD picks its default
    /// targets.  A row whose provider failed has no current reading, so it
    /// ranks as unreadable rather than by a cached quota the panel has already
    /// declared untrustworthy.
    static func rankingPercent(for row: DisplaySection, now: Date, issue: String? = nil,
                                disabledSources: Set<String> = [],
                                peerRows: [DisplaySection] = []) -> Double {
        (currentWindows(for: row, now: now, issue: issue, disabledSources: disabledSources, peerRows: peerRows)
            .compactMap(\.remainingPercent).min() ?? 100)
    }

    static func readingStatus(for row: DisplaySection, now: Date, issue: String? = nil,
                              disabledSources: Set<String> = [],
                              peerRows: [DisplaySection] = []) -> String? {
        if let issue { return glanceRowStatusText(issue: issue, hasWindows: !row.section.windows.isEmpty) }
        if !currentWindows(for: row, now: now, issue: issue, disabledSources: disabledSources, peerRows: peerRows).isEmpty { return nil }
        let relevant = row.section.windows.filter { !$0.window.isSupplementaryVideoQuota && !row.isMasked($0) }
        if !relevant.isEmpty, relevant.allSatisfy({ disabledSources.contains($0.window.source ?? "") }) {
            return "source disabled"
        }
        let snapshots = relevant.map { QuotaWindowSnapshot(window: $0.window, now: now) }
        if snapshots.contains(where: \.isAwaitingRefresh) { return "awaiting refresh" }
        if snapshots.contains(where: \.isStale) { return "stale reading" }
        return "unavailable"
    }

    private static func rowSignature(for model: MonitorModel) -> [String] {
        targetRows(for: model).map(\.id)
    }

    /// The snapshots one row draws as meters, de-duplicated the same way Glance
    /// de-duplicates them so the HUD never renders one window twice.
    static func meterCount(for row: DisplaySection, now: Date, issue: String? = nil,
                           disabledSources: Set<String> = [],
                           peerRows: [DisplaySection] = []) -> Int {
        meterSnapshots(for: row, now: now, issue: issue, disabledSources: disabledSources, peerRows: peerRows).count
    }

    static func meterSnapshots(for row: DisplaySection, now: Date, issue: String? = nil,
                               disabledSources: Set<String> = [],
                               peerRows: [DisplaySection] = []) -> [QuotaWindowSnapshot] {
        let windows = currentWindows(for: row, now: now, issue: issue, disabledSources: disabledSources, peerRows: peerRows)
        let current = DisplaySection(id: row.id, providerKey: row.providerKey, title: row.title,
            platformTitle: row.platformTitle,
            section: QuotaPlatformSection(providerKey: row.providerKey, providerLabel: row.section.providerLabel,
                via: row.section.via, expected: row.section.expected, windows: windows, iconHint: row.section.iconHint),
            poolKey: row.poolKey, remainingPercent: windows.compactMap(\.remainingPercent).min(),
            resetAt: nil, maskedWindowIds: row.maskedWindowIds)
        let meters = glanceMeterPair(for: current, now: now)
        var out: [QuotaWindowSnapshot] = []
        if let short = meters.short { out.append(short) }
        if let long = meters.long, long.window.id != meters.short?.window.id {
            out.append(long)
        } else if meters.short == nil, let primary = windows.first {
            out.append(primary)
        }
        return out
    }
}

extension PipMetrics {
    /// `.resizable` is what turns this from a fixed HUD into a window the owner
    /// can drag the edge of; the view inside degrades rather than clips.
    ///
    /// There is deliberately **no `.titled` and no `.hudWindow`** (owner report,
    /// 2026-10-08: "it needs to not have the blank silver part on top for no
    /// reason").  Both of those make AppKit paint a titlebar strip at the top
    /// of the window that sits *outside* the SwiftUI content, so it shows as a
    /// blank light band above the rounded panel — and with `titleVisibility`
    /// hidden and `titlebarAppearsTransparent` set, it was a strip with nothing
    /// on it at all.  `.fullSizeContentView` cannot hide it either, because the
    /// strip is drawn by the window frame rather than by the content view.
    ///
    /// A borderless, nonactivating, resizable panel has no such strip: the
    /// rounded panel *is* the window.  `isMovableByWindowBackground` already
    /// makes the body draggable, so the titlebar was never load-bearing.
    static var panelStyleMask: NSWindow.StyleMask {
        [.borderless, .nonactivatingPanel, .resizable]
    }
}

struct WindowDragView: NSViewRepresentable {
    final class DragNSView: NSView {
        override func mouseDown(with event: NSEvent) {
            window?.performDrag(with: event)
        }
    }

    func makeNSView(context: Context) -> DragNSView {
        DragNSView()
    }

    func updateNSView(_ nsView: DragNSView, context: Context) {}
}

/// The SwiftUI view for the floating PiP HUD widget.
struct PipWidgetView: View {
    @ObservedObject var model: MonitorModel

    /// The platform whose detail the panel opens on.
    ///
    /// The owner opens a platform by clicking its row, which sets the state
    /// below.  This says the same thing up front, so a preview or a render can
    /// show the expanded rows without a click.
    var opensDetailRowId: String?

    /// The same rows laid end to end.  Every row keeps its logo at its own left
    /// edge, so scrolling never hides which platform you are looking at —
    /// which was the whole point of the owner's request.
    private func horizontalRows(detail: PipMetrics.Detail, expandedCadence: Bool,
                                peerRows: [DisplaySection]) -> some View {
        // Wide enough for the widest pinned row, including a flame if any row
        // has one, so no row is clipped by the frame below.
        let rowWidth = PipMetrics.rowWidth(for: detail, hasFlame: anyRowSpiking(peerRows: peerRows), titleWidth: providerTitleWidth,
                                          meterCount: maximumMeterCount, expandedCadence: expandedCadence)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PipMetrics.rowSpacing * 2) {
                ForEach(Array(targetRows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        // A rule between platforms, so a wide strip reads as
                        // several platforms and not as one row of smudges
                        // (owner, 2026-10-28).
                        Rectangle()
                            .fill(background.ink.opacity(0.12))
                            .frame(width: 1)
                            .frame(height: PipMetrics.rowHeight)
                    }
                    pipRow(row, detail: detail, expandedCadence: expandedCadence, peerRows: peerRows,
                           available: rowWidth)
                        .frame(width: rowWidth, alignment: .leading)
                }
            }
            .padding(.horizontal, PipMetrics.padding)
            .padding(.vertical, PipMetrics.bodyVerticalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Match the vertical rows panel: a grey `groupBand` read as the silver
        // header strip the owner asked to remove (CC-9).
        .background(background.fill)
    }

    /// The row whose platform detail is open, if the owner clicked one.  `nil`
    /// is the normal all-rows HUD.
    @State private var detailRowId: String?

    init(model: MonitorModel, opensDetailRowId: String? = nil) {
        self.model = model
        self.opensDetailRowId = opensDetailRowId
        _detailRowId = State(initialValue: opensDetailRowId)
    }
    /// The whole panel, not just the header: the owner asked for the close
    /// button to appear when the mouse is anywhere over the window.
    @State private var isHovering = false

    /// Whether any pinned row currently shows a usage spike.  One answer for
    /// the whole strip: rows are a uniform width by design, so one spiking row
    /// widens them all rather than each row being a different size.
    private func anyRowSpiking(peerRows: [DisplaySection]) -> Bool {
        targetRows.contains { row in
            PipWidgetController.readingStatus(for: row, now: model.now, issue: model.issues[row.providerKey],
                disabledSources: model.disabledSources, peerRows: peerRows) == nil && model.hasActiveRunawayAnomaly(for: row)
        }
    }

    private var targetRows: [DisplaySection] {
        PipWidgetController.targetRows(for: model)
    }

    private var providerTitleWidth: CGFloat {
        PipMetrics.titleColumnWidth(for: targetRows.map(\.title))
    }

    private var maximumMeterCount: Int {
        max(1, targetRows.map { row in
            PipWidgetController.meterCount(for: row, now: model.now, issue: model.issues[row.providerKey],
                                            disabledSources: model.disabledSources)
        }.max() ?? 1)
    }

    /// The chosen background, resolved once and passed down.
    ///
    /// Fill, ink and mark variant have to agree; resolving them at each call
    /// site is how a light HUD ends up with white text or a dark mark on white.
    private var background: PipBackground { model.pipBackground }

    /// The mark style a provider's logo takes on this background.  Same logos as
    /// the popover (the owner asked for that on 2026-10-10), then adapted to the
    /// fill so they read on it.
    private func markStyle(for row: DisplaySection) -> MarkStyle {
        background.markStyle(for: model.glanceMarkStyle(for: row.id))
    }

    /// The one row the detail view is showing, or nil.
    private var detailRow: DisplaySection? {
        guard let detailRowId else { return nil }
        return targetRows.first { $0.id == detailRowId }
    }

    private var isSingleModel: Bool {
        detailRow != nil || targetRows.count == 1
    }

    private var dragStrip: some View {
        HStack {
            Spacer()
            Capsule()
                .fill(background.ink.opacity(0.18))
                .frame(width: 28, height: 3)
            Spacer()
        }
        .frame(height: PipMetrics.topDragAreaHeight)
        .background(WindowDragView())
    }

    var body: some View {
        GeometryReader { geo in
            // The rows are resolved once per render and handed to every helper
            // that needs them.  `orderedPipDisplaySections` walks every window
            // of every provider, so asking for it again inside each row
            // helper rebuilt the same list once per row, once per frame.
            let peerRows = model.orderedPipDisplaySections()
            let spiking = anyRowSpiking(peerRows: peerRows)
            let expandedCadence = isSingleModel && PipMetrics.expandedCadenceFits(
                forWidth: geo.size.width, titleWidth: providerTitleWidth,
                hasFlame: spiking, meterCount: maximumMeterCount,
                allowsTitle: model.pipShowProviderNames)
            // One ladder for the whole panel, so the expanded detail reads the
            // same width the rows do.
            let detail = PipMetrics.detail(forWidth: geo.size.width, titleWidth: providerTitleWidth,
                                           hasFlame: spiking, meterCount: maximumMeterCount,
                                           expandedCadence: expandedCadence,
                                           allowsTitle: model.pipShowProviderNames)
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    dragStrip
                    if let detailRow {
                        detailPanel(detailRow, detail: detail, peerRows: peerRows,
                                    height: geo.size.height, width: geo.size.width)
                    } else {
                        rowsPanel(detail: detail, height: geo.size.height, width: geo.size.width,
                                  expandedCadence: expandedCadence, peerRows: peerRows)
                    }
                }
                floatingControl
                    .padding(PipMetrics.controlInset)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: PipMetrics.cornerRadius, style: .continuous)
                .fill(background.fill)
                .overlay {
                    RoundedRectangle(cornerRadius: PipMetrics.cornerRadius, style: .continuous)
                        .fill(model.accentColor.opacity(0.05))
                }
                .background(WindowDragView())
        }
        .clipShape(RoundedRectangle(cornerRadius: PipMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PipMetrics.cornerRadius, style: .continuous)
                .strokeBorder(model.accentColor.opacity(0.35), lineWidth: 1)
        }
        .environment(\.colorScheme, background.isDark ? .dark : .light)
        .onHover { hovering in
            isHovering = hovering
        }
    }

    // MARK: Header

    /// Close, or Back when a platform detail is open.  It floats over the
    /// rows' top-right corner and appears only on hover, so it never occupies
    /// permanent space above the numbers.
    @ViewBuilder
    private var floatingControl: some View {
        if isHovering {
            if detailRow == nil {
                HStack(spacing: 5) {
                    settingsButton
                    closeButton
                }
            } else {
                backButton
            }
        }
    }

    private var settingsButton: some View {
        Button {
            if let delegate = NSApp.delegate as? AppDelegate {
                delegate.showSettings()
            } else {
                NSApp.sendAction(#selector(AppDelegate.showSettings), to: nil, from: nil)
            }
        } label: {
            Group {
                if let mark = PipWidgetController.brandMark {
                    Image(nsImage: mark)
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 15, height: 15)
                        .foregroundStyle(background.ink.opacity(0.85))
                } else {
                    Text("CC")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(background.ink.opacity(0.85))
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Dashboard")
        .accessibilityLabel("Open Dashboard")
    }

    private var closeButton: some View {
        Button {
            model.isPipEnabled = false
        } label: {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.88))
                    .frame(width: 16, height: 16)
                    .shadow(color: Color.black.opacity(0.12), radius: 1, x: 0, y: 1)
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.black.opacity(0.75))
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Close PiP Widget")
        .accessibilityLabel("Close PiP Widget")
    }

    /// Replaces the close button while a platform detail is open.  Dismissing
    /// the whole HUD is not what the owner wants at that point; going back to
    /// the rows is.
    private var backButton: some View {
        Button {
            detailRowId = nil
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 9, weight: .bold))
                Text("Back")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(background.ink.opacity(0.75))
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Back to all rows")
        .accessibilityLabel("Back to all rows")
    }

    // MARK: Rows

    /// The rows panel: every pinned row, or the ones that fit, or the lot
    /// scrolled if the owner has made the window shorter than its content.
    @ViewBuilder
    private func rowsPanel(detail: PipMetrics.Detail, height: CGFloat, width: CGFloat,
                           expandedCadence: Bool, peerRows: [DisplaySection]) -> some View {
        let visible = PipMetrics.visibleRowCount(total: targetRows.count, height: height)
        let overflows = visible < targetRows.count

        // Horizontal strips are for the squeezed-short case the owner asked
        // for: the panel must be too short to stack every pinned row first.
        // Without the height constraint a tall panel emptied its rows onto one
        // sideways line (owner 2026-10-16: "at certain sizes it looks like
        // that").  Wide enough for one full row and a peek of the next, the
        // rows become a horizontal strip, each keeping its own logo at its
        // left edge.
        if overflows && PipMetrics.rowsScrollHorizontally(forWidth: width, titleWidth: providerTitleWidth,
                                                       hasFlame: anyRowSpiking(peerRows: peerRows), meterCount: maximumMeterCount,
                                                       expandedCadence: expandedCadence,
                                                       allowsTitle: model.pipShowProviderNames) {
            horizontalRows(detail: detail, expandedCadence: expandedCadence, peerRows: peerRows)
        } else {
            verticalRows(detail: detail, visible: visible, overflows: overflows, expandedCadence: expandedCadence,
                         peerRows: peerRows, available: width - PipMetrics.padding * 2)
        }
    }

    private func verticalRows(detail: PipMetrics.Detail, visible: Int, overflows: Bool,
                              expandedCadence: Bool, peerRows: [DisplaySection],
                              available: CGFloat) -> some View {
        VStack(spacing: 0) {
            // Every pinned row is in the scroll view.  Only the ones that fit
            // used to be, so the hint below promised a scroll that had nothing
            // to scroll to (owner, 2026-10-30).
            ScrollView(.vertical, showsIndicators: overflows) {
                VStack(spacing: 0) {
                    ForEach(targetRows) { row in
                        pipRow(row, detail: detail, expandedCadence: expandedCadence, peerRows: peerRows,
                               available: available)
                    }
                }
                .padding(.horizontal, PipMetrics.padding)
                .padding(.vertical, PipMetrics.bodyVerticalPadding)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if overflows {
                // Say so, rather than letting a pinned row look absent.  It
                // sits under the scroll view so it never scrolls away itself.
                Text("\(targetRows.count - max(1, visible)) more pinned — scroll")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(background.countdownInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, PipMetrics.padding)
                    .padding(.bottom, 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(background.fill)
    }

    /// One row.  The whole row is the tap target for opening that platform's
    /// detail.
    private func pipRow(_ row: DisplaySection, detail: PipMetrics.Detail, expandedCadence: Bool,
                         peerRows: [DisplaySection], available: CGFloat) -> some View {
        let issue = model.issues[row.providerKey]
        let status = PipWidgetController.readingStatus(for: row, now: model.now, issue: issue,
                                                       disabledSources: model.disabledSources,
                                                       peerRows: peerRows)
        // A row that only has room for one of its two meters keeps the one
        // with the least remaining, not whichever came first (owner,
        // 2026-10-30).
        let meters = QuotaWindowPresentation.collapsedMeters(
            PipWidgetController.meterSnapshots(for: row, now: model.now, issue: issue,
                                               disabledSources: model.disabledSources,
                                               peerRows: peerRows),
            limit: detail.maxMeters
        )

        let spiking = status == nil && model.hasActiveRunawayAnomaly(for: row)
        // Owner 2026-10-11: the HUD showed a capped plan's meters, so a plan
        // that could not be used at all drew a full 100% bar.  One line of
        // words is the honest thing in a strip this narrow.
        let windows = PipWidgetController.currentWindows(for: row, now: model.now, issue: issue,
                                                         disabledSources: model.disabledSources,
                                                         peerRows: peerRows)
        let atCap = QuotaPlatformSection(providerKey: row.providerKey, providerLabel: row.section.providerLabel,
                                         expected: row.section.expected, windows: windows).atCapWindow()
        // The extra balance is asked over the row's raw windows, not over the
        // filtered set: a counted balance has no percentage, so the filter
        // drops it and the HUD would say "At Cap" while the menu bar window
        // said "using extra balance" (owner, 2026-10-28).
        let extra = PipWidgetController.usableMuseExtra(for: row, now: model.now, issue: issue,
                                                         disabledSources: model.disabledSources)

        return HStack(spacing: PipMetrics.rowSpacing) {
            if detail.showsProviderLogo {
                PlatformLogo(providerKey: row.id,
                             size: PipMetrics.providerLogoSize,
                             style: markStyle(for: row),
                             iconHint: row.poolKey == nil ? row.section.iconHint : nil,
                             forceMonochrome: true)
                // Owner 2026-10-10: "after the platform name (or logo if no
                // name shown) there should be a little flame for usage spike".
                // Beside the LOGO rather than after the name, because the name
                // is the first thing the width ladder drops — at narrow widths
                // this is the only place the signal can live.
                if spiking {
                    Image(systemName: "flame.fill")
                        .font(.system(size: PipMetrics.providerLogoSize * 0.7))
                        .frame(width: PipMetrics.flameIconWidth)
                        .foregroundStyle(Theme.warning)
                        .help("Usage spike detected on this platform")
                        .accessibilityLabel("Usage spike detected on this platform")
                }
            }

            if detail.showsTitle {
                // The name hugs its own bar instead of sitting in a column of
                // its own: the owner asked for the logo and the name close to
                // the meter, not aligned somewhere else (owner, 2026-10-28).
                // It never grows past the width the ladder budgeted for it
                // though: a long name truncates instead of pushing the meters
                // out of the row.
                Text(row.title)
                    .font(.system(size: PipMetrics.titleFontSize, weight: .medium))
                    .foregroundStyle(background.ink)
                    .lineLimit(1)
                    .frame(maxWidth: PipMetrics.titleWidth, alignment: .leading)
            }

            if let status {
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(background.countdownInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            } else if atCap != nil, let extra {
                // The words hug their meter.  Splitting the row in half put a
                // void between the sentence and the bar it describes, which is
                // the same dead gap the meters had (owner, 2026-10-28).
                //
                // They never push the meter out of the row either.  The words
                // take the room they need and shrink to give the meter what is
                // left, and when even that is not enough the meter goes first:
                // the words are what says the plan is still working (owner,
                // 2026-10-28).
                let meterMin = detail.showsCadence ? PipMetrics.meterMinWidth : PipMetrics.bareMeterMinWidth
                let identity = PipMetrics.providerLogoSize + PipMetrics.rowSpacing
                let textBudget = max(0, available - identity - PipMetrics.meterSpacing - meterMin)
                let showsMeter = textBudget >= PipMetrics.extraBalanceTextMinWidth
                let words = Text("extra")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(background.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if showsMeter {
                    HStack(spacing: PipMetrics.meterSpacing) {
                        words.frame(maxWidth: textBudget, alignment: .leading)
                        pipMeter(extra, detail: detail, expandedCadence: expandedCadence,
                                 extraWordShownBeside: true)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    words.frame(maxWidth: max(0, available - identity), alignment: .leading)
                }
            } else if let atCap {
                pipAtCap(atCap, detail: detail)
            } else {
                HStack(spacing: PipMetrics.meterSpacing) {
                    ForEach(Array(meters.enumerated()), id: \.offset) { _, snapshot in
                        pipMeter(snapshot, detail: detail, expandedCadence: expandedCadence)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(height: PipMetrics.rowHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { detailRowId = row.id }
        .help(row.title)
        .accessibilityLabel("\(row.title) — open details")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: Platform detail

    /// One platform, in the panel, with every window it publishes rather than
    /// the two the summary row has room for.
    private func detailPanel(_ row: DisplaySection, detail: PipMetrics.Detail,
                              peerRows: [DisplaySection], height: CGFloat,
                              width: CGFloat) -> some View {
        let issue = model.issues[row.providerKey]
        // The platform's own 5-hour and 7-day windows first, then its
        // per-model windows such as Fable (owner, 2026-10-30).
        let windows = QuotaWindowPresentation.primaryFirst(
            PipWidgetController.currentWindows(for: row, now: model.now, issue: issue,
                                               disabledSources: model.disabledSources,
                                               peerRows: peerRows))
        let status = PipWidgetController.readingStatus(for: row, now: model.now, issue: issue,
                                                       disabledSources: model.disabledSources,
                                                       peerRows: peerRows)
        // Clicking a platform opens its detail, and a panel with room to
        // spare spreads the rows out instead of huddling them at the top
        // (owner, 2026-10-28).
        let spacing = detailRowSpacing(rowCount: windows.count, height: height)
        // What one line of the panel actually has to work with.
        let available = max(0, width - PipMetrics.padding * 2)

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    PlatformLogo(providerKey: row.id,
                                 size: 16,
                                 style: markStyle(for: row),
                                 iconHint: row.poolKey == nil ? row.section.iconHint : nil,
                                 forceMonochrome: true)
                    Text(row.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(background.ink)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if row.section.expected, row.section.windows.isEmpty {
                        Text("No readings published")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.warning)
                            .lineLimit(1)
                    }
                }
                .padding(.bottom, 1)

                ForEach(Array(windows.enumerated()), id: \.element.window.id) { index, snapshot in
                    detailWindowRow(snapshot, detail: detail, available: available)
                        .frame(height: PipMetrics.detailRowHeight)
                        .padding(.top, index == 0 ? PipMetrics.detailRowSpacingMin : spacing)
                }

                if windows.isEmpty {
                    Text(status ?? "No readings for this platform right now.")
                        .font(.system(size: 10))
                        .foregroundStyle(background.countdownInk)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PipMetrics.padding)
            .padding(.vertical, PipMetrics.bodyVerticalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(background.fill)
    }

    /// One window in the expanded platform detail.
    ///
    /// One line: the cadence caption, the model name if the window belongs to
    /// one model, the bar, then the percentage and the countdown.  The
    /// percentage sits after the bar as it does on every other surface
    /// (owner, 2026-10-30).
    ///
    /// The label is dropped when it only restates the caption -- "5-hour"
    /// beside "5h" says the same thing twice -- and kept when it names
    /// something the caption cannot.  A per-model window is always named by
    /// its model, because its own label is often only the cadence.
    private func detailWindowRow(_ snapshot: QuotaWindowSnapshot, detail: PipMetrics.Detail,
                                  available: CGFloat) -> some View {
        let metrics = QuotaBarMetrics(snapshot: snapshot, now: model.now)
        let remaining = snapshot.remainingPercent
        let isExtra = isMuseAssistExtra(snapshot)
        let cd = isExtra ? "extra" : (detail.usesCompactCountdown ? glanceResetCompactCountdown(snapshot.resetAt, now: model.now) : glanceResetCountdown(snapshot.resetAt, now: model.now))
        let cadenceCaption = glanceMeterCaption(snapshot)
        let modelName = snapshot.window.subModelName
        let label = modelName ?? cleanWindowLabel(snapshot.window.label)
        // The line gives way before the panel clips: the countdown goes
        // first, then the label, and the bar takes whatever is left.
        let showsCountdown = !cd.isEmpty && available >= PipMetrics.detailRowMinWidthWithCountdown
        let labelBudget = max(0, available - PipMetrics.detailRowMinWidth - PipMetrics.meterSpacing
                              - (showsCountdown ? PipMetrics.meterSpacing + PipMetrics.countdownWidth : 0))
        let showLabel = (modelName != nil || !detailLabelRedundant(caption: cadenceCaption, label: label))
            && labelBudget >= PipMetrics.detailLabelMinWidth
        let labelWidth = min(labelBudget, PipMetrics.detailLabelMaxWidth)

        return HStack(spacing: PipMetrics.meterSpacing) {
            Text(cadenceCaption)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(background.countdownInk)
                .frame(width: PipMetrics.cadenceWidth, alignment: .leading)

            if showLabel {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(background.ink)
                    .lineLimit(1)
                    .frame(maxWidth: labelWidth, alignment: .leading)
            }

            QuotaUsageBar(
                metrics: metrics,
                height: 5,
                dimmed: quotaBarIsDimmed(for: snapshot, sourceFailed: false),
                markerHeight: 11
            )
            .frame(minWidth: PipMetrics.barMinWidth, maxWidth: PipMetrics.detailBarMaxWidth)

            Text(remaining.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(background.ink)
                .lineLimit(1)
                .frame(width: PipMetrics.percentWidth, alignment: .leading)

            if showsCountdown {
                Text(cd)
                    .font(isExtra ? .system(size: 9, weight: .bold) : .system(size: 9).monospacedDigit())
                    .foregroundStyle(isExtra ? background.ink : background.countdownInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .fixedSize()
            }
        }
        .help(isExtra ? "Extra token usage" : (snapshot.resetAt.map { "Resets \(glanceResetCountdown($0, now: model.now))" } ?? ""))
    }

    /// How far apart the expanded rows sit.
    ///
    /// The rows hug each other when the panel is tight and open out when it
    /// has room to spare, so opening a platform in a tall panel does not leave
    /// a block of readings stranded at the top (owner, 2026-10-28).
    private func detailRowSpacing(rowCount: Int, height: CGFloat) -> CGFloat {
        let rows = CGFloat(max(1, rowCount))
        let headerHeight: CGFloat = 17
        let chrome = PipMetrics.bodyVerticalPadding * 2 + PipMetrics.topDragAreaHeight + headerHeight
        let spare = height - chrome - rows * PipMetrics.detailRowHeight
        guard spare > 0, rows > 1 else { return PipMetrics.detailRowSpacingMin }
        // Half the spare room goes into the gaps and half stays as breathing
        // space, so the rows open out without floating apart.
        return min(PipMetrics.detailRowSpacingMax,
                   PipMetrics.detailRowSpacingMin + spare / (rows - 1) / 2)
    }

    /// The HUD's capped state, in place of its bars: the words "At Cap" and
    /// how long until the plan is usable again.  Sized like the meter it
    /// replaces so a capped row does not resize the strip.
    private func pipAtCap(_ snapshot: QuotaWindowSnapshot, detail: PipMetrics.Detail) -> some View {
        let cap = GlanceAtCap(snapshot: snapshot, now: model.now)
        let summary = glanceAtCapSummary(snapshot, now: model.now)
        return Text(summary)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(background.ink)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
        .help(snapshot.resetAt.map { glanceResetHelp($0, now: model.now) ?? "At cap" } ?? "At cap")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(cap.spokenDescription)
    }

    private func pipMeter(_ snapshot: QuotaWindowSnapshot, detail: PipMetrics.Detail,
                          expandedCadence: Bool, extraWordShownBeside: Bool = false) -> some View {
        let metrics = QuotaBarMetrics(snapshot: snapshot, now: model.now)
        let isExtra = isMuseAssistExtra(snapshot)
        let cd: String
        if isExtra {
            // The capped row already says "extra" to the left of this meter,
            // so the trailing slot stays empty instead of repeating it.
            cd = extraWordShownBeside ? "" : "extra"
        } else if detail.usesCompactCountdown {
            cd = glanceResetCompactCountdown(snapshot.resetAt, now: model.now)
        } else {
            cd = glanceResetCountdown(snapshot.resetAt, now: model.now)
        }
        let remaining = snapshot.remainingPercent
        let showExpanded = expandedCadence && detail == .full
        let cadenceCaption = showExpanded ? singleModelCadenceExpanded(snapshot) : glanceMeterCaption(snapshot)
        // Reserve the countdown's width only when a countdown is actually
        // drawn.  Reserving it always left a column of empty space to the
        // right of every percentage, which read as a huge gap between the two
        // meters of a row (owner, 2026-10-28).
        let showsCountdown = detail.showsCountdown && !cd.isEmpty
        let countdownWidth = detail.usesCompactCountdown ? PipMetrics.countdownCompactWidth : PipMetrics.countdownWidth
        let trailingWidth = showsCountdown
            ? PipMetrics.percentWidth + PipMetrics.countdownGap + countdownWidth
            : PipMetrics.percentWidth

        return HStack(spacing: PipMetrics.meterSpacing) {
            if detail.showsCadence && !extraWordShownBeside {
                Text(cadenceCaption)
                    .font(.system(size: showExpanded ? 10 : 9, weight: showExpanded ? .bold : .bold))
                    .foregroundStyle(background.countdownInk)
                    .frame(width: showExpanded ? PipMetrics.cadenceExpandedWidth : PipMetrics.cadenceWidth, alignment: .trailing)
            }

            QuotaUsageBar(
                metrics: metrics,
                height: PipMetrics.barHeight,
                dimmed: quotaBarIsDimmed(for: snapshot, sourceFailed: false),
                markerHeight: 10
            )
            .frame(minWidth: PipMetrics.barMinWidth, maxWidth: .infinity)

            // Fixed combined width, leading-aligned: the countdown stays
            // directly after the percent while the bar keeps a uniform width
            // across rows as values tick.
            HStack(spacing: PipMetrics.countdownGap) {
                Text(remaining.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(background.ink)
                    .lineLimit(1)
                    .fixedSize()
                    .help("Remaining: \(remaining.map { "\(Int($0.rounded()))%" } ?? "unknown")")

                if showsCountdown {
                    Text(cd)
                        .font(isExtra
                              ? .system(size: 9, weight: .bold)
                              : .system(size: 9, weight: .medium).monospacedDigit())
                        .foregroundStyle(isExtra ? background.ink : background.countdownInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .fixedSize()
                }
            }
            .frame(width: trailingWidth, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

func singleModelCadenceExpanded(_ snapshot: QuotaWindowSnapshot) -> String {
    let caption = glanceMeterCaption(snapshot)
    switch caption {
    case "5h": return "5 hour"
    case "7d": return "7 day"
    case "24h", "1d": return "1 day"
    case "1m": return "1 month"
    default:
        let lower = snapshot.window.label.lowercased()
        if lower.contains("5-hour") || lower.contains("5 hour") { return "5 hour" }
        if lower.contains("weekly") || lower.contains("7-day") || lower.contains("7d") { return "7 day" }
        return caption
    }
}

/// Whether a window's label only repeats the cadence caption beside it.
///
/// "5-hour" beside "5h", or "7-day" beside "7d", says the same thing twice
/// (owner, 2026-10-28).  A label that names something the caption cannot -- a
/// model, a plan -- is kept.
func detailLabelRedundant(caption: String, label: String) -> Bool {
    let text = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return true }
    let captionText = caption.lowercased()
    let labelText = text.lowercased()
    if captionText == labelText { return true }
    let digits = captionText.prefix(while: { $0.isNumber })
    guard !digits.isEmpty else { return false }
    guard labelText.hasPrefix(String(digits)) else { return false }
    // Only a time unit after the digits repeats the caption: "5h" and
    // "5-hour", "7d" and "7-day".  A label that merely starts with the same
    // number -- "5 GB bonus" beside a "5h" caption -- names something the
    // caption cannot, so it stays.
    let rest = labelText.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
    let unit = rest.hasPrefix("-") ? String(rest.dropFirst()) : rest
    return ["", "h", "d", "hr", "hrs", "hour", "hours", "day", "days"].contains(unit)
}

func cleanWindowLabel(_ label: String) -> String {
    var text = label
    for term in [" window", " Window", " (window)", " (Window)"] {
        text = text.replacingOccurrences(of: term, with: "")
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

extension PipWidgetController {
    /// The owner's cropped black-on-transparent mark, loaded once.  It is drawn
    /// as a template everywhere it appears, which is what makes one asset
    /// correct in both appearances.
    static let brandMark: NSImage? = {
        guard let url = ResourceBundle.resolved?.url(forResource: "CodeCapsMenuBarIcon",
                                                      withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        return image
    }()
}
