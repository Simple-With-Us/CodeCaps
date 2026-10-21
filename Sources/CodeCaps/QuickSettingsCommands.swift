import AppKit
import ServiceManagement
import SwiftUI

/// Shared commands for the Glance gear menu.
struct QuickSettingsCommands: View {
    @ObservedObject var model: MonitorModel
    var openSettings: () -> Void

    var body: some View {
        Button("Settings...", action: openSettings)
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
struct LaunchAtLoginToggle: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    var body: some View {
        Toggle("Launch at Login", isOn: Binding(
            get: { enabled },
            set: { requested in
                do {
                    if requested { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                    if SMAppService.mainApp.status == .requiresApproval {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                } catch {
                    NSAlert(error: error).runModal()
                }
                enabled = SMAppService.mainApp.status == .enabled
            }))
            .onAppear { enabled = SMAppService.mainApp.status == .enabled }
    }
}
