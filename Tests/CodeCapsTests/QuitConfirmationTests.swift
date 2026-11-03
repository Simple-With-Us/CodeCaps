import AppKit
import Carbon
import XCTest
@testable import CodeCaps

final class QuitConfirmationTests: XCTestCase {
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
