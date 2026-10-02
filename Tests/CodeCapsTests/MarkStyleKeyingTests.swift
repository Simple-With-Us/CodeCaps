import XCTest
@testable import CodeCaps
import QuotaCore

/// The Logo Style page and the menu bar mark override, both of which were
/// keyed on the bare `providerKey` while every row the owner actually sees is
/// keyed on a pool-qualified id.
@MainActor
final class MarkStyleKeyingTests: XCTestCase {
    private func model(_ seed: [String: MarkStyle]) -> MonitorModel {
        let suite = "com.jays.codecaps.tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        // `markStyles` is stored as one JSON-encoded dictionary, not per key.
        if let data = try? JSONEncoder().encode(seed) { defaults.set(data, forKey: "markStyles") }
        let m = MonitorModel(defaults: defaults)
        defaults.removePersistentDomain(forName: suite)
        return m
    }

    /// A style the owner set for "Antigravity" before the pools were listed
    /// separately has to keep applying to both pools.  Otherwise listing the
    /// pools silently reverts them to the default, which is what made the page
    /// look like the setting had been ignored.
    func testPoolQualifiedRowsInheritThePlatformStyle() {
        let m = model(["google-antigravity": .standard])
        XCTAssertEqual(m.markStyle(for: "google-antigravity:gemini"), .standard)
        XCTAssertEqual(m.markStyle(for: "google-antigravity:third-party"), .standard)
    }

    func testAPoolLevelOverrideWinsOverThePlatformStyle() {
        let m = model(["google-antigravity": .standard, "google-antigravity:gemini": .template])
        XCTAssertEqual(m.markStyle(for: "google-antigravity:gemini"), .template)
        XCTAssertEqual(m.markStyle(for: "google-antigravity:third-party"), .standard)
    }

    func testAnUnsetPlatformStillFallsBackToTheDefault() {
        let m = model([:])
        XCTAssertEqual(m.markStyle(for: "anthropic"), .template)
        XCTAssertEqual(m.glanceMarkStyle(for: "google-antigravity:gemini"), .standard)
    }

    /// The menu bar mark override, which exists because the status item sits on
    /// a system surface the owner does not control.
    func testMenuBarMarkStyleOverridesTheProviderStyleOnlyWhenAsked() {
        XCTAssertEqual(MenuBarMarkStyle.followProvider.resolved(.standard), .standard,
                       "Match Provider must leave the per-provider choice alone")
        XCTAssertEqual(MenuBarMarkStyle.followProvider.resolved(.template), .template)
        XCTAssertEqual(MenuBarMarkStyle.lightDark.resolved(.standard), .template,
                       "Light/Dark must override a provider set to Colour")
        XCTAssertEqual(MenuBarMarkStyle.colour.resolved(.template), .standard,
                       "Colour must override a provider set to Light/Dark")
    }

    /// Guards the reason the owner could not get a colour menu bar mark: the
    /// single-colour artwork renders as a template in every style, so forcing
    /// "Colour" cannot conjure a colour that is not in the file.
    func testSingleColourMarksStayMonochromeUnderEveryMenuBarChoice() {
        for key in ["codex", "cursor", "grok", "grok-bot", "minimax"] {
            XCTAssertTrue(PlatformLogoImage.isMonochromeMark(key),
                          "\(key) ships single-colour artwork; the settings copy depends on this")
        }
        for key in ["anthropic", "claude", "google-antigravity:gemini"] {
            XCTAssertFalse(PlatformLogoImage.isMonochromeMark(key),
                           "\(key) has brand colour to preserve, so Standard is meaningful")
        }
    }
}
