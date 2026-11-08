import AppKit
import Carbon

enum QuitConfirmationChoice: Equatable {
    case closeAndKeepRunning
    case quit
    case cancel

    init(response: NSApplication.ModalResponse) {
        switch response {
        case .alertFirstButtonReturn:
            self = .closeAndKeepRunning
        case .alertSecondButtonReturn:
            self = .quit
        default:
            self = .cancel
        }
    }
}

enum QuitConfirmationPolicy {
    static func shouldConfirm(systemTerminationReason: OSType?, automaticInstallInProgress: Bool) -> Bool {
        guard !automaticInstallInProgress else { return false }
        guard let systemTerminationReason else { return true }
        return ![kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut].contains(systemTerminationReason)
    }
}

extension QuitConfirmationPolicy {
    static func shouldShowStatusItem(displayMode: DisplayMode, keepRunningOverride: Bool) -> Bool {
        displayMode != .dock || keepRunningOverride
    }
}

@MainActor
extension QuitConfirmationPolicy {
    static func windowsToHide(managed: [NSWindow?]) -> [NSWindow] {
        managed.compactMap { $0 }.filter {
            $0.styleMask.contains(.titled) && $0.level != .statusBar && $0.level != .popUpMenu
        }
    }
}
