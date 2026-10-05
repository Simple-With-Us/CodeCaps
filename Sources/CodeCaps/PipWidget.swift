import AppKit
import QuotaCore
import SwiftUI

/// Floating on-screen Picture-in-Picture (PiP) HUD widget for CodeCaps.
/// Keeps critical AI quota meters visible on top of all windows at all times.
@MainActor
final class PipWidgetController: NSObject, NSWindowDelegate {
    static let shared = PipWidgetController()

    private var panel: NSPanel?
    private weak var currentModel: MonitorModel?

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
            contentRect: NSRect(x: 120, y: 120, width: 260, height: 120),
            styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        // Start at `.floating`; `applyLevel()` below lifts the HUD again if it
        // is recreated (Settings toggle) while the console is still elevated
        // and its frame overlaps the console.
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.setFrameAutosaveName("CodeCapsPipWidgetPanel")
        p.delegate = self
        p.contentView = NSHostingView(rootView: PipWidgetView(model: model))
        self.panel = p
        applyLevel()
        p.orderFrontRegardless()
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
}

/// The SwiftUI view for the floating PiP HUD widget.
struct PipWidgetView: View {
    @ObservedObject var model: MonitorModel
    @State private var isHovering = false

    private var targetRows: [DisplaySection] {
        let all = model.displaySections
        if model.pipPinnedRowIds.isEmpty {
            // Default to the 2 lowest remaining quota rows
            let sorted = all.sorted { a, b in
                (a.section.minimumRemainingPercent ?? 100) < (b.section.minimumRemainingPercent ?? 100)
            }
            return Array(sorted.prefix(2))
        }
        let pinned = all.filter { model.pipPinnedRowIds.contains($0.id) }
        return pinned.isEmpty ? Array(all.prefix(2)) : pinned
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header bar
            HStack(spacing: 6) {
                if let url = ResourceBundle.resolved?.url(forResource: "CodeCapsMenuBarIcon", withExtension: "png"),
                   let nsImage = NSImage(contentsOf: url) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .renderingMode(.template)
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(Theme.accent)
                } else {
                    Image(systemName: "gauge.with.needle.fill")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 12, height: 12)
                        .foregroundStyle(Theme.accent)
                }
                Text("CodeCaps PiP")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)

                Spacer()

                if isHovering {
                    Button {
                        model.isPipEnabled = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close PiP Widget")
                }
            }
            .padding(.bottom, 2)

            // Selected quota rows
            ForEach(targetRows) { row in
                pipRow(row)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
        .frame(minWidth: 230, maxWidth: 280)
    }

    private func pipRow(_ row: DisplaySection) -> some View {
        let meters = glanceMeterPair(for: row, now: model.now)
        let primarySnapshot = meters.short ?? meters.long ?? row.section.windows.first

        return HStack(spacing: 6) {
            PlatformLogo(providerKey: row.providerKey,
                         size: 14,
                         style: model.markStyle(for: row.providerKey),
                         iconHint: row.poolKey == nil ? row.section.iconHint : nil)

            Text(row.title)
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .frame(width: 68, alignment: .leading)

            Spacer(minLength: 2)

            if let short = meters.short {
                pipMeter(short)
            }
            if let long = meters.long, long.window.id != meters.short?.window.id {
                pipMeter(long)
            } else if meters.short == nil, let primary = primarySnapshot {
                pipMeter(primary)
            }
        }
        .padding(.vertical, 2)
    }

    private func pipMeter(_ snapshot: QuotaWindowSnapshot) -> some View {
        let metrics = QuotaBarMetrics(snapshot: snapshot, now: model.now)
        let cd = glanceResetCountdown(snapshot.resetAt, now: model.now)
        let remaining = snapshot.remainingPercent

        return HStack(spacing: 4) {
            Text(glanceMeterCaption(snapshot))
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)

            QuotaUsageBar(
                metrics: metrics,
                height: 4,
                dimmed: quotaBarIsDimmed(for: snapshot, sourceFailed: false),
                markerHeight: 10
            )
            .frame(width: 32, height: 4)

            Text(remaining.map { "\(Int($0.rounded()))%" } ?? "—")
                .font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(
                    pacingPillBackgroundColor(
                        remainingPercent: remaining,
                        elapsedFraction: snapshot.elapsedFraction(now: model.now),
                        isEnabled: model.pacingColorHighlights
                    ),
                    in: RoundedRectangle(cornerRadius: 3)
                )

            if !cd.isEmpty {
                Text(cd)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .center)
            }
        }
    }
}
