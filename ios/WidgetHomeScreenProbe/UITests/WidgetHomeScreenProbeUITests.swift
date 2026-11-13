import XCTest

/// Pinned iOS 18–27 home-screen gallery contract: long-press empty wallpaper,
/// Edit, Add Widget, search CodeCaps, add AI Subscription Overview, Done.
/// A missing control fails closed with an `unsupported-path:` message.  The
/// test does not try a second gesture and does not retry.
final class WidgetHomeScreenProbeUITests: XCTestCase {
    private let editLabel = "Edit"
    private let addWidgetLabel = "Add Widget"
    private let doneLabel = "Done"
    private let appLabel = "CodeCaps"
    private let widgetLabel = "AI Subscription Overview"
    /// Gallery placeholders never render this pair.  37% alone could match a
    /// status-bar battery, so the reading has to carry the provider title too.
    private let sentinelTitle = "GitHub Copilot"
    private let sentinelPercent = "37%"

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    func testHomeScreenRendersSeededQuota() {
        let host = XCUIApplication()
        if host.state != .notRunning {
            host.terminate()
        }

        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        springboard.activate()

        let wallpaper = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
        wallpaper.press(forDuration: 2.0)

        guard let edit = waitForControl(springboard, editLabel, timeout: 8) else {
            XCTFail("unsupported-path: Edit control missing after long-press")
            return
        }
        tap(edit)

        guard let add = waitForControl(springboard, addWidgetLabel, timeout: 8) else {
            XCTFail("unsupported-path: Add Widget control missing")
            return
        }
        tap(add)

        let search = springboard.searchFields.firstMatch
        guard search.waitForExistence(timeout: 8) else {
            XCTFail("unsupported-path: widget gallery search field missing")
            return
        }
        tap(search)
        search.typeText(appLabel)

        guard let widget = waitForWidgetResult(springboard) else {
            XCTFail("unsupported-path: CodeCaps widget missing from gallery search")
            return
        }
        tap(widget)

        guard let confirm = waitForControl(springboard, addWidgetLabel, timeout: 8) else {
            XCTFail("unsupported-path: gallery confirm Add Widget missing")
            return
        }
        tap(confirm)

        guard let done = waitForControl(springboard, doneLabel, timeout: 8) else {
            XCTFail("unsupported-path: Done control missing after add")
            return
        }
        tap(done)

        if springboard.searchFields.firstMatch.exists {
            XCTFail("unsupported-path: widget gallery search field still present after add")
            return
        }

        let predicate = NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@",
            sentinelTitle,
            sentinelPercent
        )
        let reading = springboard.descendants(matching: .any).matching(predicate).firstMatch
        guard reading.waitForExistence(timeout: 20) else {
            XCTFail("home-screen widget did not render seeded GitHub Copilot 37%")
            return
        }

        springboard.activate()
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.lifetime = .keepAlways
        attachment.name = "home-screen-widget"
        add(attachment)
    }

    /// Search lists the app, then the widget.  Tap the app row only when the
    /// widget name is not on screen yet, then require the widget itself.
    /// Rows are cells or buttons.  The search field's typed text is not a row.
    private func waitForWidgetResult(_ app: XCUIApplication) -> XCUIElement? {
        if let widget = waitForResult(app, widgetLabel, timeout: 8) {
            return widget
        }
        guard let appRow = waitForResult(app, appLabel, timeout: 2) else {
            return nil
        }
        tap(appRow)
        return waitForResult(app, widgetLabel, timeout: 8)
    }

    private func waitForResult(_ app: XCUIApplication, _ label: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = existingResult(app, label) {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return existingResult(app, label)
    }

    private func existingResult(_ app: XCUIApplication, _ label: String) -> XCUIElement? {
        let queries = [app.cells[label], app.buttons[label]]
        return queries.first { $0.exists }
    }

    private func waitForControl(_ app: XCUIApplication, _ label: String, timeout: TimeInterval) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let element = existingControl(app, label) {
                return element
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return existingControl(app, label)
    }

    private func existingControl(_ app: XCUIApplication, _ label: String) -> XCUIElement? {
        let queries = [
            app.buttons[label],
            app.menuItems[label],
            app.staticTexts[label],
            app.cells[label],
            app.otherElements[label],
        ]
        return queries.first { $0.exists }
    }

    private func tap(_ element: XCUIElement) {
        if element.isHittable {
            element.tap()
        } else {
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
    }
}
