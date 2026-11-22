import XCTest

/// Pinned iOS 18–27 home-screen gallery contract: decline the companion's
/// pending notification-permission alert, long-press empty wallpaper, Edit,
/// Add Widget, search CodeCaps, add AI Subscription Overview, Done.
/// A missing control fails closed with an `unsupported-path:` message.  The
/// test does not try a second gesture and does not retry.
final class WidgetHomeScreenProbeUITests: XCTestCase {
    /// SpringBoard labels the notification-permission decline button with a
    /// U+2019 apostrophe; the escape keeps the label byte-exact.
    private let doNotAllowLabel = "Don\u{2019}t Allow"
    private let allowLabel = "Allow"
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

        guard dismissPermissionAlert(springboard) else {
            XCTFail("unsupported-path: notification permission alert could not be dismissed; on-screen: \(elementInventory(springboard))")
            return
        }

        let wallpaper = springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.70))
        wallpaper.press(forDuration: 2.0)

        guard let edit = waitForControl(springboard, editLabel, timeout: 8) else {
            XCTFail("unsupported-path: Edit control missing after long-press; on-screen: \(elementInventory(springboard))")
            return
        }
        tap(edit)

        guard let addWidget = waitForControl(springboard, addWidgetLabel, timeout: 8) else {
            XCTFail("unsupported-path: Add Widget control missing; on-screen: \(elementInventory(springboard))")
            return
        }
        tap(addWidget)

        let search = springboard.searchFields.firstMatch
        guard search.waitForExistence(timeout: 8) else {
            XCTFail("unsupported-path: widget gallery search field missing; on-screen: \(elementInventory(springboard))")
            return
        }
        tap(search)
        search.typeText(appLabel)

        guard let widget = waitForWidgetResult(springboard) else {
            XCTFail("unsupported-path: CodeCaps widget missing from gallery search; on-screen: \(elementInventory(springboard))")
            return
        }
        tap(widget)

        guard let confirm = waitForControl(springboard, addWidgetLabel, timeout: 8) else {
            XCTFail("unsupported-path: gallery confirm Add Widget missing; on-screen: \(elementInventory(springboard))")
            return
        }
        tap(confirm)

        guard let done = waitForControl(springboard, doneLabel, timeout: 8) else {
            XCTFail("unsupported-path: Done control missing after add; on-screen: \(elementInventory(springboard))")
            return
        }
        tap(done)

        if springboard.searchFields.firstMatch.exists {
            XCTFail("unsupported-path: widget gallery search field still present after add; on-screen: \(elementInventory(springboard))")
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

    /// The companion asks for notification permission when its model first
    /// loads: two alert kinds ship enabled with notifications on, and the
    /// model's startup sync assigns its preferences, which makes the model
    /// request authorization.  On a fresh simulator that system alert is
    /// still sitting on SpringBoard when this test starts.  The alert is
    /// modal — while it is up, the long-press never reaches the Home Screen
    /// and no Edit control exists — so the contract declines it first.  The
    /// probe never grants a permission on the owner's behalf, and the widget
    /// render does not need notifications.  Returns false when an alert is
    /// present but will not dismiss.
    private func dismissPermissionAlert(_ app: XCUIApplication) -> Bool {
        guard let decline = waitForControl(app, doNotAllowLabel, timeout: 5) else {
            return true
        }
        tap(decline)
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if existingControl(app, doNotAllowLabel) == nil && existingControl(app, allowLabel) == nil {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return existingControl(app, doNotAllowLabel) == nil && existingControl(app, allowLabel) == nil
    }

    /// Diagnostic inventory for a contract failure: the labeled elements
    /// SpringBoard is presenting right now, so the failure line names what
    /// was actually on screen instead of only what was missing.
    private func elementInventory(_ app: XCUIApplication) -> String {
        let kinds: [(String, XCUIElement.ElementType)] = [
            ("button", .button),
            ("menuItem", .menuItem),
            ("cell", .cell),
            ("icon", .icon),
            ("staticText", .staticText),
            ("other", .other),
        ]
        var entries: [String] = []
        for (name, type) in kinds {
            for element in app.descendants(matching: type).allElementsBoundByIndex {
                if !element.label.isEmpty {
                    entries.append("\(name)=\(element.label)")
                }
                if entries.count >= 150 {
                    return entries.joined(separator: " | ")
                }
            }
        }
        return entries.isEmpty ? "<no labeled elements>" : entries.joined(separator: " | ")
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
