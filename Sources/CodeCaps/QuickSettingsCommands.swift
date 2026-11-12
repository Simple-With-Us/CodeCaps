import AppKit
import ServiceManagement
import SwiftUI

/// Shared commands for the Glance gear menu.
struct QuickSettingsCommands: View {
    @ObservedObject var model: MonitorModel
    var openSettings: () -> Void

    var body: some View {
        Button("Dashboard…", action: openSettings)
            .keyboardShortcut(",", modifiers: .command)
        Divider()
        LaunchAtLoginToggle()
        Toggle("Attach to Menu Bar", isOn: $model.glanceAttachedToMenuBar)
        Toggle("Picture-in-Picture", isOn: $model.isPipEnabled)
        Divider()
        Button("Quit CodeCaps") { NSApp.terminate(nil) }
            .keyboardShortcut("q", modifiers: .command)
    }
}

/// Reads the OS registration state, never a separate preference flag.
///
/// `SMAppService.status` is a synchronous XPC round trip to `smd`, and the
/// `@State` initializer used to call it.  A `@State` initializer runs when
/// the view is constructed, so every SwiftUI update that rebuilt this menu
/// parked the main thread in `mach_msg` waiting for `smd` to answer.  When
/// `smd` was busy — during an app update, for one — that wait ran past two
/// seconds and the app-hang tracker reported the freeze.
///
/// The state therefore starts out unknown, and the real answer is read on a
/// background queue, so the main thread never waits on `smd`.  The toggle
/// stays disabled until that first read lands, so it never shows a stale
/// answer the user could act on.
struct LaunchAtLoginToggle: View {
    @State private var enabled = false
    @State private var isLoaded = false

    var body: some View {
        Toggle("Launch at Login", isOn: Binding(
            get: { enabled },
            set: { requested in apply(requested) }))
            .disabled(!isLoaded)
            .onAppear { loadStatus() }
    }

    /// Applies the requested registration, then re-reads the real state.
    ///
    /// `register()` and `unregister()` are synchronous XPC round trips to
    /// `smd` as well, so they run off the main thread too.  Only the alert
    /// and the state write come back to the main thread.
    private func apply(_ requested: Bool) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if requested { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                DispatchQueue.main.async { NSAlert(error: error).runModal() }
            }
            loadStatus { status in
                if status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        }
    }

    /// Reads the registration state off the main thread.
    ///
    /// The completion runs on the main thread, so callers can touch state
    /// and show UI directly.
    private func loadStatus(onReady: ((SMAppService.Status) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            let status = SMAppService.mainApp.status
            DispatchQueue.main.async {
                enabled = status == .enabled
                isLoaded = true
                onReady?(status)
            }
        }
    }
}
