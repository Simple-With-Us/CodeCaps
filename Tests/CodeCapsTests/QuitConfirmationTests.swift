import AppKit
import Carbon
import XCTest
@testable import CodeCaps

final class QuitConfirmationTests: XCTestCase {
    @MainActor
    func testOnlyManagedContentWindowsAreSelectedForHiding() {
        func window(_ style: NSWindow.StyleMask = [.titled]) -> NSWindow {
            NSWindow(contentRect: .zero, styleMask: style, backing: .buffered, defer: false)
        }
        let console = window()
        let glance = window()
        let status = window()
        status.level = .statusBar
        let popup = window()
        popup.level = .popUpMenu
        let system = window([])
        let unrelated = window()
        let selected = QuitConfirmationPolicy.windowsToHide(managed: [console, nil, glance, status, popup, system])
        XCTAssertEqual(selected.map(ObjectIdentifier.init), [console, glance].map(ObjectIdentifier.init))
        XCTAssertFalse(selected.contains { $0 === unrelated })
        XCTAssertFalse(console.isVisible, "Selection alone must not show or hide windows")
        XCTAssertTrue(QuitConfirmationPolicy.shouldShowStatusItem(displayMode: .dock, keepRunningOverride: true))
    }

    func testAlertResponsesChooseTheExpectedQuitAction() {
        XCTAssertEqual(QuitConfirmationChoice(response: .alertFirstButtonReturn), .closeAndKeepRunning)
        XCTAssertEqual(QuitConfirmationChoice(response: .alertSecondButtonReturn), .quit)
        XCTAssertEqual(QuitConfirmationChoice(response: .alertThirdButtonReturn), .cancel)
        XCTAssertEqual(QuitConfirmationChoice(response: NSApplication.ModalResponse(rawValue: 0)), .cancel)
    }

    func testKeepRunningChoiceKeepsMenuBarAccessInDockOnlyMode() {
        XCTAssertFalse(QuitConfirmationPolicy.shouldShowStatusItem(displayMode: .dock, keepRunningOverride: false))
        XCTAssertTrue(QuitConfirmationPolicy.shouldShowStatusItem(displayMode: .dock, keepRunningOverride: true))
        XCTAssertTrue(QuitConfirmationPolicy.shouldShowStatusItem(displayMode: .both, keepRunningOverride: false))
    }

    func testOrdinaryQuitPromptsEvenWithoutAUserEvent() {
        XCTAssertTrue(QuitConfirmationPolicy.shouldConfirm(systemTerminationReason: nil,
                                                           automaticInstallInProgress: false))
    }

    func testSystemShutdownLogoutAndRestartSkipThePrompt() {
        for reason in [kAEQuitAll, kAEShutDown, kAERestart, kAEReallyLogOut] {
            XCTAssertFalse(QuitConfirmationPolicy.shouldConfirm(systemTerminationReason: reason,
                                                                 automaticInstallInProgress: false))
        }
    }

    func testOnlyAnActiveAutomaticInstallSkipsThePrompt() {
        XCTAssertFalse(QuitConfirmationPolicy.shouldConfirm(systemTerminationReason: nil,
                                                            automaticInstallInProgress: true))
        XCTAssertTrue(QuitConfirmationPolicy.shouldConfirm(systemTerminationReason: nil,
                                                           automaticInstallInProgress: false))
    }
}
