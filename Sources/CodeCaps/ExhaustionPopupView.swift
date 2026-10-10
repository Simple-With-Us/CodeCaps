import SwiftUI

/// The window the owner asked for by name: a literal popup that says which
/// platform is about to run out and roughly how long is left, so there is time
/// to wind work up or leave handover notes.
///
/// It is deliberately NOT the Docked Bar and NOT a sheet over it.  The point is
/// to interrupt without changing any state — this is information, and closing
/// it loses nothing.
struct ExhaustionPopupView: View {
    let popup: MonitorModel.ExhaustionPopup
    /// Called when the owner dismisses it, so the popup does not reappear on
    /// the next read for a warning already shown.
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.dots.needle.50percent")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.warning)
                Text("Quota Running Low")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer(minLength: 8)
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.solidMark.opacity(0.55))
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss the quota warning")
            }

            Text(popup.platformLabel)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Theme.ink)

            Text("About \(popup.headroom) left.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink.opacity(0.85))

            Text("Wind up or hand off anything still running against it.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(Theme.surface)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(popup.platformLabel) has about \(popup.headroom) of quota left")
        .accessibilityAddTraits(.isStaticText)
    }
}

/// A non-activating panel: it takes the screen without stealing focus from
/// whatever the owner is actually doing, which is the whole point of warning
/// them mid-task.
@MainActor
final class ExhaustionPopupController {
    private var panel: NSPanel?
    private weak var model: MonitorModel?

    init(model: MonitorModel) {
        self.model = model
    }

    func update(_ popup: MonitorModel.ExhaustionPopup?) {
        guard let popup else {
            panel?.orderOut(nil)
            panel = nil
            return
        }
        guard panel == nil else { return }   // already up; a new warning reuses it
        let view = ExhaustionPopupView(popup: popup) { [weak self] in
            self?.model?.dismissExhaustionPopup()
        }
        let hosting = NSHostingController(rootView: view)
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 150),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        p.contentViewController = hosting
        p.isFloatingPanel = true
        p.level = .statusBar
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            // Top-right of the main screen: out of the way, and near the menu
            // bar the owner is already looking at.
            p.setFrameOrigin(NSPoint(x: frame.maxX - 320 - 16, y: frame.maxY - 150 - 16))
        }
        panel = p
        p.orderFrontRegardless()
    }
}
