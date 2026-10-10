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
    static let titleWidth: CGFloat = 60
    static let cadenceWidth: CGFloat = 18
    static let cadenceExpandedWidth: CGFloat = 40
    /// Wide enough for "100%" in bold monospaced digits at 10pt, left-aligned so
    /// a long number never clips: the owner saw "100%" lose a couple of points
    /// at the narrow end when it was right-aligned into a tight frame.
    static let percentWidth: CGFloat = 30
    static let countdownWidth: CGFloat = 30
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
    static let singleMeterDefaultWidth: CGFloat = 300

    // MARK: Derived widths

    /// The narrowest one meter can be and still show caption, bar and percent.
    static let meterMinWidth: CGFloat =
        cadenceWidth + meterSpacing + barMinWidth + meterSpacing + percentWidth

    /// The same meter plus its reset countdown.
    static let meterMinWidthWithCountdown: CGFloat =
        meterMinWidth + meterSpacing + countdownWidth

    /// Caption-less meter: bar and percent only.
    private static let bareMeterMinWidth: CGFloat =
        meterSpacing + barMinWidth + meterSpacing + percentWidth

    /// Provider logo, title, and two fully-labelled meters.
    static let fullMinWidth: CGFloat =
        providerLogoSize + rowSpacing + titleWidth + rowSpacing
        + meterMinWidthWithCountdown + rowSpacing + meterMinWidthWithCountdown

    /// Provider logo, title and two meters, countdowns dropped.
    static let noCountdownMinWidth: CGFloat =
        providerLogoSize + rowSpacing + titleWidth + rowSpacing
        + meterMinWidth + rowSpacing + meterMinWidth

    /// Provider logo and two meters, no countdowns and no title (platform name dropped first).
    static let logoOnlyMinWidth: CGFloat =
        providerLogoSize + rowSpacing + meterMinWidth + rowSpacing + meterMinWidth

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
    /// The platform name is dropped before the second bar:
    /// `full > noCountdown > logoOnly > minimal > singleMeter > barsOnly > singleBar`.
    enum Detail: Int, CaseIterable, Comparable {
        /// Bar, percent, reset countdown; provider logo and title.
        case full
        /// Two meters, no countdowns.
        case noCountdown
        /// Two meters and the provider's logo, but platform name dropped.
        case logoOnly
        /// Two labelled meters, provider identity dropped entirely.
        case minimal
        /// One meter, with its countdown, still named/identified.
        case singleMeter
        /// Two bars and two percentages, captions dropped.
        case barsOnly
        /// One bar and its percentage.
        case singleBar

        static func < (lhs: Detail, rhs: Detail) -> Bool { lhs.rawValue > rhs.rawValue }

        var maxMeters: Int {
            switch self {
            case .full, .noCountdown, .logoOnly, .minimal, .barsOnly: return 2
            case .singleMeter, .singleBar: return 1
            }
        }

        var showsCountdown: Bool {
            self == .full || self == .singleMeter
        }

        var showsCadence: Bool {
            self != .barsOnly && self != .singleBar
        }

        var showsProviderLogo: Bool {
            self == .full || self == .noCountdown || self == .logoOnly || self == .singleMeter
        }

        /// The platform name drops before the second bar.
        var showsTitle: Bool {
            self == .full || self == .noCountdown
        }
    }

    /// The richest level whose content fits `width`, content width being what
    /// survives the panel's own padding.
    static func detail(forWidth width: CGFloat) -> Detail {
        let available = width - padding * 2
        switch available {
        case fullMinWidth...: return .full
        case noCountdownMinWidth...: return .noCountdown
        case logoOnlyMinWidth...: return .logoOnly
        case minimalMinWidth...: return .minimal
        case singleMeterMinWidth...: return .singleMeter
        case barsOnlyMinWidth...: return .barsOnly
        default: return .singleBar
        }
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
        panel?.orderOut(nil)
        panel = nil
    }

    /// The console window while it sits elevated above the Glance popover
    /// (`popUpMenuWindow + 1`), or nil once it has been lowered.  Remembered
    /// rather than applied once: the panel is torn down and recreated at
    /// `.floating` whenever the PiP toggle on the elevated Settings page is
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
        let p = NSPanel(
            contentRect: NSRect(x: 120, y: 120, width: 300, height: 130),
            styleMask: PipMetrics.panelStyleMask,
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        // Start at `.floating`; `applyLevel()` below lifts the HUD again if it
        // is recreated (Settings toggle) while the console is still elevated
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

        let hasDualMeterRow = rows.contains { Self.meterCount(for: $0, now: model.now) > 1 }
        let fit = PipMetrics.fitSize(rowCount: rows.count, hasDualMeterRow: hasDualMeterRow)
        let clamped = NSSize(
            width: min(max(fit.width, panel.minSize.width), panel.maxSize.width),
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
        panel = nil
    }

    // MARK: Row derivation

    /// The rows the HUD shows: the pinned ones, else the two lowest quotas.
    /// Shared with the controller's sizing so the panel and the view can never
    /// count different rows.
    static func targetRows(for model: MonitorModel) -> [DisplaySection] {
        let all = model.orderedPipDisplaySections()
        if model.pipPinnedRowIds.isEmpty {
            let sorted = all.sorted { a, b in
                (a.section.minimumRemainingPercent ?? 100) < (b.section.minimumRemainingPercent ?? 100)
            }
            return Array(sorted.prefix(2))
        }
        let pinned = all.filter { model.pipPinnedRowIds.contains($0.id) }
        return pinned.isEmpty ? Array(all.prefix(2)) : pinned
    }

    private static func rowSignature(for model: MonitorModel) -> [String] {
        targetRows(for: model).map(\.id)
    }

    /// The snapshots one row draws as meters, de-duplicated the same way Glance
    /// de-duplicates them so the HUD never renders one window twice.
    static func meterCount(for row: DisplaySection, now: Date) -> Int {
        meterSnapshots(for: row, now: now).count
    }

    static func meterSnapshots(for row: DisplaySection, now: Date) -> [QuotaWindowSnapshot] {
        let meters = glanceMeterPair(for: row, now: now)
        var out: [QuotaWindowSnapshot] = []
        if let short = meters.short { out.append(short) }
        if let long = meters.long, long.window.id != meters.short?.window.id {
            out.append(long)
        } else if meters.short == nil, let primary = row.section.windows.first {
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
    /// The row whose platform detail is open, if the owner clicked one.  `nil`
    /// is the normal all-rows HUD.
    @State private var detailRowId: String?
    /// The whole panel, not just the header: the owner asked for the close
    /// button to appear when the mouse is anywhere over the window.
    @State private var isHovering = false

    private var targetRows: [DisplaySection] {
        PipWidgetController.targetRows(for: model)
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
                .fill(Theme.solidMark.opacity(0.18))
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
                        rowsPanel(detail: detail, height: geo.size.height)
                    }
                }
                floatingControl
                    .padding(PipMetrics.controlInset)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: PipMetrics.cornerRadius, style: .continuous)
                .fill(Theme.groupBand)
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
                        .foregroundStyle(Theme.solidMark.opacity(0.85))
                } else {
                    Text("CC")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.solidMark.opacity(0.85))
                }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Settings")
        .accessibilityLabel("Open Settings")
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
            .foregroundStyle(Theme.solidMark.opacity(0.75))
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
    private func rowsPanel(detail: PipMetrics.Detail, height: CGFloat) -> some View {
        let visible = PipMetrics.visibleRowCount(total: targetRows.count, height: height)
        let overflows = visible < targetRows.count

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 0) {
                ForEach(Array(targetRows.prefix(max(1, visible)))) { row in
                    pipRow(row, detail: detail)
                }
                if overflows {
                    // Say so, rather than letting a pinned row look absent.
                    Text("\(targetRows.count - max(1, visible)) more pinned — scroll")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PipMetrics.padding)
            .padding(.vertical, PipMetrics.bodyVerticalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.groupBand)
    }

    /// One row.  The whole row is the tap target for opening that platform's
    /// detail.
    private func pipRow(_ row: DisplaySection, detail: PipMetrics.Detail) -> some View {
        let meters = Array(
            PipWidgetController.meterSnapshots(for: row, now: model.now)
                .prefix(detail.maxMeters)
        )

        return HStack(spacing: PipMetrics.rowSpacing) {
            if detail.showsProviderLogo {
                PlatformLogo(providerKey: row.providerKey,
                             size: PipMetrics.providerLogoSize,
                             style: model.markStyle(for: row.providerKey),
                             iconHint: row.poolKey == nil ? row.section.iconHint : nil)
            }

            if detail.showsTitle {
                Text(row.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.solidMark)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: PipMetrics.titleWidth, alignment: .leading)
            }

            Spacer(minLength: 0)

            ForEach(Array(meters.enumerated()), id: \.offset) { _, snapshot in
                pipMeter(snapshot, detail: detail)
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
        let windows = row.section.windows
            .filter { !$0.window.isSupplementaryVideoQuota && !row.isMasked($0) }

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    PlatformLogo(providerKey: row.providerKey,
                                 size: 16,
                                 style: model.markStyle(for: row.providerKey),
                                 iconHint: row.poolKey == nil ? row.section.iconHint : nil)
                    Text(row.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.solidMark)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if row.section.expected, windows.isEmpty {
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
                    Text("No readings for this platform right now.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PipMetrics.padding)
            .padding(.vertical, PipMetrics.bodyVerticalPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.groupBand)
    }

    private func detailWindowRow(_ snapshot: QuotaWindowSnapshot, detail: PipMetrics.Detail) -> some View {
        let metrics = QuotaBarMetrics(snapshot: snapshot, now: model.now)
        let remaining = snapshot.remainingPercent
        let cd = glanceResetCountdown(snapshot.resetAt, now: model.now)
        let showExpanded = detail == .full
        let cadenceCaption = showExpanded ? singleModelCadenceExpanded(snapshot) : glanceMeterCaption(snapshot)
        let cleanLabel = cleanWindowLabel(snapshot.window.label.isEmpty ? "Quota" : snapshot.window.label)

        return VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Text(cadenceCaption)
                    .font(.system(size: showExpanded ? 10 : 9, weight: showExpanded ? .bold : .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: showExpanded ? PipMetrics.cadenceExpandedWidth : PipMetrics.cadenceWidth, alignment: .leading)
                Text(cleanLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.solidMark)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(remaining.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.solidMark)
                    .fixedSize()
                if !cd.isEmpty {
                    Text(cd)
                        .font(.system(size: 9).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
        .help(snapshot.resetAt.map { "Resets \(glanceResetCountdown($0, now: model.now))" } ?? "")
    }

    private func pipMeter(_ snapshot: QuotaWindowSnapshot, detail: PipMetrics.Detail) -> some View {
        let metrics = QuotaBarMetrics(snapshot: snapshot, now: model.now)
        let cd = glanceResetCountdown(snapshot.resetAt, now: model.now)
        let remaining = snapshot.remainingPercent
        let showExpanded = isSingleModel && detail == .full
        let cadenceCaption = showExpanded ? singleModelCadenceExpanded(snapshot) : glanceMeterCaption(snapshot)

        return HStack(spacing: PipMetrics.meterSpacing) {
            if detail.showsCadence {
                Text(cadenceCaption)
                    .font(.system(size: showExpanded ? 10 : 9, weight: showExpanded ? .bold : .bold))
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(Theme.solidMark)
                .lineLimit(1)
                .fixedSize()
                .frame(width: PipMetrics.percentWidth, alignment: .leading)
                .help("Remaining: \(remaining.map { "\(Int($0.rounded()))%" } ?? "unknown")")

            if detail.showsCountdown, !cd.isEmpty {
                Text(cd)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .frame(width: PipMetrics.countdownWidth, alignment: .trailing)
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