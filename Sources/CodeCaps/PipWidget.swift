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
    static let titleWidth: CGFloat = 150
    static let cadenceWidth: CGFloat = 18
    static let cadenceExpandedWidth: CGFloat = 40
    /// Wide enough for "100%" in bold monospaced digits at 10pt, left-aligned so
    /// a long number never clips: the owner saw "100%" lose a couple of points
    /// at the narrow end when it was right-aligned into a tight frame.
    static let percentWidth: CGFloat = 30
    static let countdownWidth: CGFloat = 42
    static let countdownCompactWidth: CGFloat = 28
    static let barMinWidth: CGFloat = 20
    static let barHeight: CGFloat = 4

    // MARK: Floating controls

    /// The close/back control floats over the rows rather than living in a band
    /// of its own (owner, 2026-10-08), so it is inset from the corner rather
    /// than laid out beside a title.
    static let controlInset: CGFloat = 4
    static let controlHitSize: CGFloat = 18

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
    static let meterMinWidthWithCountdown: CGFloat =
        meterMinWidth + meterSpacing + countdownWidth

    /// The same meter plus its compact reset countdown.
    static let meterMinWidthWithCompactCountdown: CGFloat =
        meterMinWidth + meterSpacing + countdownCompactWidth

    /// Caption-less meter: bar and percent only.
    private static let bareMeterMinWidth: CGFloat =
        meterSpacing + barMinWidth + meterSpacing + percentWidth

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

    /// Two labelled meters, with no provider identity at all.
    static let minimalMinWidth: CGFloat = meterMinWidth + rowSpacing + meterMinWidth

    /// Two bare meters: bar and percent each.
    static let barsOnlyMinWidth: CGFloat =
        bareMeterMinWidth + rowSpacing + bareMeterMinWidth

    /// Provider logo and one meter, countdown kept.
    static let singleMeterMinWidth: CGFloat =
        providerLogoSize + rowSpacing + meterMinWidthWithCountdown

    /// A single bare meter, which is the floor: bar and percent, nothing else.
    static let singleBarMinWidth: CGFloat = bareMeterMinWidth

    // MARK: Responsive detail

    /// How much of a row survives at a given panel width, richest first.
    ///
    /// The platform name is dropped before the countdown disappears:
    /// `full > logoWithFullCountdown > logoWithCompactCountdown > logoOnly > minimal > singleMeter > barsOnly > singleBar`.
    enum Detail: Int, CaseIterable, Comparable {
        /// Bar, percent, 2-unit reset countdown; provider logo and title.
        case full
        /// Two meters with 2-unit countdowns; provider logo kept, platform name dropped.
        case logoWithFullCountdown
        /// Two meters with 1-unit rounded-up countdowns; provider logo kept, platform name dropped.
        case logoWithCompactCountdown
        /// Two meters, countdowns and platform name dropped; provider logo kept.
        case logoOnly
        /// Two labelled meters, provider identity dropped entirely.
        case minimal
        /// One meter, with its countdown, still named/identified.
        case singleMeter
        /// Two bars and two percentages, captions dropped.
        case barsOnly
        /// One bar and its percentage.
        case singleBar

        /// Legacy alias for tests.
        static let noCountdown = Detail.logoOnly

        static func < (lhs: Detail, rhs: Detail) -> Bool { lhs.rawValue > rhs.rawValue }

        var maxMeters: Int {
            switch self {
            case .full, .logoWithFullCountdown, .logoWithCompactCountdown, .logoOnly, .minimal, .barsOnly: return 2
            case .singleMeter, .singleBar: return 1
            }
        }

        var showsCountdown: Bool {
            self == .full || self == .logoWithFullCountdown || self == .logoWithCompactCountdown || self == .singleMeter
        }

        var usesCompactCountdown: Bool {
            self == .logoWithCompactCountdown
        }

        var showsCadence: Bool {
            self != .barsOnly && self != .singleBar
        }

        var showsProviderLogo: Bool {
            self == .full || self == .logoWithFullCountdown || self == .logoWithCompactCountdown || self == .logoOnly || self == .singleMeter
        }

        /// The platform name drops before the countdown: only `.full` keeps the title.
        var showsTitle: Bool {
            self == .full
        }
    }

    /// The richest level whose content fits `width`, content width being what
    /// survives the panel's own padding.
    static func detail(forWidth width: CGFloat) -> Detail {
        let available = width - padding * 2
        switch available {
        case fullMinWidth...: return .full
        case logoWithCountdownMinWidth...: return .logoWithFullCountdown
        case logoWithCompactCountdownMinWidth...: return .logoWithCompactCountdown
        case logoOnlyMinWidth...: return .logoOnly
        case minimalMinWidth...: return .minimal
        case singleMeterMinWidth...: return .singleMeter
        case barsOnlyMinWidth...: return .barsOnly
        default: return .singleBar
        }
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
    /// row: the same number drives `fitSize` and `applyFit`, so leaving it out
    /// both clipped the icon in the vertical list and let it overflow the
    /// fixed frame in the horizontal one.
    static func rowWidth(for detail: Detail, hasFlame: Bool = false) -> CGFloat {
        let base: CGFloat
        switch detail {
        case .full: base = fullMinWidth
        case .logoWithFullCountdown: base = logoWithCountdownMinWidth
        case .logoWithCompactCountdown: base = logoWithCompactCountdownMinWidth
        case .logoOnly: base = logoOnlyMinWidth
        case .minimal: base = minimalMinWidth
        case .singleMeter: base = singleMeterMinWidth
        case .barsOnly: base = barsOnlyMinWidth
        case .singleBar: base = singleMeterMinWidth
        }
        return hasFlame && detail.showsProviderLogo ? base + flameWidth : base
    }

    /// The flame's own width plus its gap from the logo.  Fixed so the row
    /// arithmetic above can be exact rather than approximate.
    static let flameWidth: CGFloat = rowSpacing + 10

    /// Whether the panel is wide enough to scroll its rows sideways.
    ///
    /// Owner 2026-10-10: "once it gets to where it is in the screenshot or
    /// actually 80-100 pixels wider than that so that it could still have
    /// platform logos at the left … we could make it scroll left to right like
    /// it now does up and down."
    ///
    /// Derived rather than hardcoded to his 80-100 figure, because the number
    /// that matters is the row's own width at the detail level in force, which
    /// moves when any bar metric changes.  The result lands in his range: the
    /// squeeze point is around 222pt, and this is roughly 90pt past it.
    static func rowsScrollHorizontally(forWidth width: CGFloat) -> Bool {
        // The threshold uses the richest row width so it is monotonic in panel
        // width: deriving it from the detail level in force flipped the strip
        // on and off as a resize crossed the detail ladder (owner 2026-10-16:
        // "as you stretch it out it alternates between showing correctly or
        // not").
        width >= padding * 2 + rowWidth(for: .full) + horizontalPeek
    }

    /// How many rows fit in `height` without clipping, never fewer than one.
    static func visibleRowCount(total: Int, height: CGFloat) -> Int {
        guard total > 0 else { return 0 }
        let available = height - bodyVerticalPadding * 2 - topDragAreaHeight
        guard available >= rowHeight else { return 1 }
        return min(total, max(1, Int(available / rowHeight)))
    }

    /// The panel size that shows every pinned row at the richest level the
    /// content can actually use.
    static func fitSize(rowCount: Int, hasDualMeterRow: Bool) -> NSSize {
        let rows = CGFloat(max(1, rowCount))
        let height = rows * rowHeight + bodyVerticalPadding * 2 + topDragAreaHeight
        let width = hasDualMeterRow
            ? padding * 2 + fullMinWidth
            : max(singleMeterDefaultWidth, padding * 2 + singleMeterMinWidth)
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
                issue: model.issues[$0.providerKey], disabledSources: model.disabledSources) > 1 })
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
        let fit = PipMetrics.fitSize(rowCount: rows.count, hasDualMeterRow: hasDualMeterRow)
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
        let sorted = all.sorted { a, b in
            let aAvailable = readingStatus(for: a, now: model.now, issue: model.issues[a.providerKey],
                                          disabledSources: model.disabledSources) == nil
            let bAvailable = readingStatus(for: b, now: model.now, issue: model.issues[b.providerKey],
                                          disabledSources: model.disabledSources) == nil
            if aAvailable != bAvailable { return aAvailable }
            return (currentWindows(for: a, now: model.now, disabledSources: model.disabledSources)
                .compactMap(\.remainingPercent).min() ?? 100)
                < (currentWindows(for: b, now: model.now, disabledSources: model.disabledSources)
                    .compactMap(\.remainingPercent).min() ?? 100)
        }
        return Array(sorted.prefix(2))
    }

    /// Cached or failed-source readings cannot describe the current allowance.
    static func currentWindows(for row: DisplaySection, now: Date, issue: String? = nil,
                               disabledSources: Set<String> = []) -> [QuotaWindowSnapshot] {
        guard issue == nil else { return [] }
        return row.section.windows
            .filter { !$0.window.isSupplementaryVideoQuota && !row.isMasked($0)
                && !$0.window.remainingUnknown
                && !disabledSources.contains($0.window.source ?? "") }
            .map { QuotaWindowSnapshot(window: $0.window, now: now) }
            .filter { $0.isFresh && $0.remainingPercent != nil
                && (!$0.window.skip || $0.remainingPercent == 0) }
    }

    static func readingStatus(for row: DisplaySection, now: Date, issue: String? = nil,
                              disabledSources: Set<String> = []) -> String? {
        if let issue { return glanceRowStatusText(issue: issue, hasWindows: !row.section.windows.isEmpty) }
        if !currentWindows(for: row, now: now, disabledSources: disabledSources).isEmpty { return nil }
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
                           disabledSources: Set<String> = []) -> Int {
        meterSnapshots(for: row, now: now, issue: issue, disabledSources: disabledSources).count
    }

    static func meterSnapshots(for row: DisplaySection, now: Date, issue: String? = nil,
                               disabledSources: Set<String> = []) -> [QuotaWindowSnapshot] {
        let windows = currentWindows(for: row, now: now, issue: issue, disabledSources: disabledSources)
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
    /// The same rows laid end to end.  Every row keeps its logo at its own left
    /// edge, so scrolling never hides which platform you are looking at —
    /// which was the whole point of the owner's request.
    private func horizontalRows(detail: PipMetrics.Detail) -> some View {
        // Wide enough for the widest pinned row, including a flame if any row
        // has one, so no row is clipped by the frame below.
        let rowWidth = PipMetrics.rowWidth(for: detail, hasFlame: anyRowSpiking)
        return ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: PipMetrics.rowSpacing * 2) {
                ForEach(targetRows) { row in
                    pipRow(row, detail: detail)
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
    /// The whole panel, not just the header: the owner asked for the close
    /// button to appear when the mouse is anywhere over the window.
    @State private var isHovering = false

    /// Whether any pinned row currently shows a usage spike.  One answer for
    /// the whole strip: rows are a uniform width by design, so one spiking row
    /// widens them all rather than each row being a different size.
    private var anyRowSpiking: Bool {
        targetRows.contains { model.hasActiveRunawayAnomaly(for: $0) }
    }

    private var targetRows: [DisplaySection] {
        PipWidgetController.targetRows(for: model)
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
            let detail = PipMetrics.detail(forWidth: geo.size.width)
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    dragStrip
                    if let detailRow {
                        detailPanel(detailRow, detail: detail)
                    } else {
                        rowsPanel(detail: detail, height: geo.size.height, width: geo.size.width)
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
    private func rowsPanel(detail: PipMetrics.Detail, height: CGFloat, width: CGFloat) -> some View {
        let visible = PipMetrics.visibleRowCount(total: targetRows.count, height: height)
        let overflows = visible < targetRows.count

        // Horizontal strips are for the squeezed-short case the owner asked
        // for: the panel must be too short to stack every pinned row first.
        // Without the height constraint a tall panel emptied its rows onto one
        // sideways line (owner 2026-10-16: "at certain sizes it looks like
        // that").  Wide enough for one full row and a peek of the next, the
        // rows become a horizontal strip, each keeping its own logo at its
        // left edge.
        if overflows && PipMetrics.rowsScrollHorizontally(forWidth: width) {
            horizontalRows(detail: detail)
        } else {
            verticalRows(detail: detail, visible: visible, overflows: overflows)
        }
    }

    private func verticalRows(detail: PipMetrics.Detail, visible: Int, overflows: Bool) -> some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Array(targetRows.prefix(max(1, visible)))) { row in
                    pipRow(row, detail: detail)
                }
                if overflows {
                    // Say so, rather than letting a pinned row look absent.
                    Text("\(targetRows.count - max(1, visible)) more pinned — scroll")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(background.countdownInk)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PipMetrics.padding)
            .padding(.vertical, PipMetrics.bodyVerticalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(background.fill)
    }

    /// One row.  The whole row is the tap target for opening that platform's
    /// detail.
    private func pipRow(_ row: DisplaySection, detail: PipMetrics.Detail) -> some View {
        let issue = model.issues[row.providerKey]
        let status = PipWidgetController.readingStatus(for: row, now: model.now, issue: issue,
                                                       disabledSources: model.disabledSources)
        let meters = Array(
            PipWidgetController.meterSnapshots(for: row, now: model.now, issue: issue,
                                               disabledSources: model.disabledSources)
                .prefix(detail.maxMeters)
        )

        let spiking = status == nil && model.hasActiveRunawayAnomaly(for: row)
        // Owner 2026-10-11: the HUD showed a capped plan's meters, so a plan
        // that could not be used at all drew a full 100% bar.  One line of
        // words is the honest thing in a strip this narrow.
        let windows = PipWidgetController.currentWindows(for: row, now: model.now, issue: issue,
                                                         disabledSources: model.disabledSources)
        let atCap = QuotaPlatformSection(providerKey: row.providerKey, providerLabel: row.section.providerLabel,
                                         expected: row.section.expected, windows: windows).atCapWindow()
        let extra = glanceUsableMuseExtra(windows)

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
                        .foregroundStyle(Theme.warning)
                        .help("Usage spike detected on this platform")
                        .accessibilityLabel("Usage spike detected on this platform")
                }
            }

            if detail.showsTitle {
                Text(row.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(background.ink)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: PipMetrics.titleWidth, alignment: .leading)
            }

            if atCap == nil { Spacer(minLength: 0) }

            if let status {
                Text(status)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(background.countdownInk)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if atCap != nil, let extra {
                HStack(spacing: PipMetrics.meterSpacing) {
                    Text("Using extra balance")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(background.ink)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    pipMeter(extra, detail: detail)
                        .frame(maxWidth: .infinity)
                }
                .frame(maxWidth: .infinity)
            } else if let atCap {
                pipAtCap(atCap, detail: detail)
            } else {
                HStack(spacing: PipMetrics.meterSpacing) {
                    ForEach(Array(meters.enumerated()), id: \.offset) { _, snapshot in
                        pipMeter(snapshot, detail: detail)
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
    private func detailPanel(_ row: DisplaySection, detail: PipMetrics.Detail) -> some View {
        let issue = model.issues[row.providerKey]
        let windows = PipWidgetController.currentWindows(for: row, now: model.now, issue: issue,
                                                         disabledSources: model.disabledSources)
        let status = PipWidgetController.readingStatus(for: row, now: model.now, issue: issue,
                                                       disabledSources: model.disabledSources)

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 3) {
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

                ForEach(windows, id: \.window.id) { snapshot in
                    detailWindowRow(snapshot, detail: detail)
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

    private func detailWindowRow(_ snapshot: QuotaWindowSnapshot, detail: PipMetrics.Detail) -> some View {
        let metrics = QuotaBarMetrics(snapshot: snapshot, now: model.now)
        let remaining = snapshot.remainingPercent
        let isExtra = isMuseAssistExtra(snapshot)
        let cd = isExtra ? "extra" : (detail.usesCompactCountdown ? glanceResetCompactCountdown(snapshot.resetAt, now: model.now) : glanceResetCountdown(snapshot.resetAt, now: model.now))
        let showExpanded = detail == .full
        let cadenceCaption = showExpanded ? singleModelCadenceExpanded(snapshot) : glanceMeterCaption(snapshot)
        let cleanLabel = cleanWindowLabel(snapshot.window.label.isEmpty ? "Quota" : snapshot.window.label)
        let countdownWidth = detail.usesCompactCountdown ? PipMetrics.countdownCompactWidth : PipMetrics.countdownWidth

        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(cadenceCaption)
                    .font(.system(size: showExpanded ? 10 : 9, weight: showExpanded ? .bold : .bold))
                    .foregroundStyle(background.countdownInk)
                    .frame(width: showExpanded ? PipMetrics.cadenceExpandedWidth : PipMetrics.cadenceWidth, alignment: .leading)
                Text(cleanLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(background.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(remaining.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(background.ink)
                    .fixedSize()
                if !cd.isEmpty {
                    Text(cd)
                        .font(isExtra ? .system(size: 9, weight: .bold) : .system(size: 9).monospacedDigit())
                        .foregroundStyle(isExtra ? background.ink : background.countdownInk)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: countdownWidth, alignment: .trailing)
                }
            }
            QuotaUsageBar(
                metrics: metrics,
                height: 5,
                dimmed: quotaBarIsDimmed(for: snapshot, sourceFailed: false),
                markerHeight: 11
            )
            .frame(height: 5)
        }
        .help(isExtra ? "Extra token usage" : (snapshot.resetAt.map { "Resets \(glanceResetCountdown($0, now: model.now))" } ?? ""))
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

    private func pipMeter(_ snapshot: QuotaWindowSnapshot, detail: PipMetrics.Detail) -> some View {
        let metrics = QuotaBarMetrics(snapshot: snapshot, now: model.now)
        let isExtra = isMuseAssistExtra(snapshot)
        let cd: String
        if isExtra {
            cd = "extra"
        } else if detail.usesCompactCountdown {
            cd = glanceResetCompactCountdown(snapshot.resetAt, now: model.now)
        } else {
            cd = glanceResetCountdown(snapshot.resetAt, now: model.now)
        }
        let remaining = snapshot.remainingPercent
        let showExpanded = isSingleModel && detail == .full
        let cadenceCaption = showExpanded ? singleModelCadenceExpanded(snapshot) : glanceMeterCaption(snapshot)
        let countdownWidth = detail.usesCompactCountdown ? PipMetrics.countdownCompactWidth : PipMetrics.countdownWidth

        return HStack(spacing: PipMetrics.meterSpacing) {
            if detail.showsCadence {
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

            Text(remaining.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(background.ink)
                .lineLimit(1)
                .fixedSize()
                .frame(width: PipMetrics.percentWidth, alignment: .leading)
                .help("Remaining: \(remaining.map { "\(Int($0.rounded()))%" } ?? "unknown")")

            if detail.showsCountdown, !cd.isEmpty {
                Text(cd)
                    .font(isExtra
                          ? .system(size: 9, weight: .bold)
                          : .system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(isExtra ? background.ink : background.countdownInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .fixedSize()
                    .frame(width: countdownWidth, alignment: .trailing)
            }
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
