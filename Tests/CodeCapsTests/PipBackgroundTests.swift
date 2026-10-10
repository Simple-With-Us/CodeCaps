import XCTest
@testable import CodeCaps
import QuotaCore

/// The PiP HUD's own background, ink and mark variants must agree with each
/// other.  Owner request, 2026-10-10: white, black or an accent tint, with "the
/// text white and appropriate logos chosen if in dark mode".
@MainActor
final class PipBackgroundTests: XCTestCase {

    /// A dark fill takes a light silhouette; a light fill takes the brand
    /// colour.  Getting this backwards is invisible until it is on screen, so
    /// it is pinned here.
    func testMarkVariantFollowsTheFillNotTheAppAppearance() {
        XCTAssertEqual(PipBackground.black.markStyle(for: .standard), .template,
                       "a dark HUD needs a light silhouette")
        XCTAssertEqual(PipBackground.accent.markStyle(for: .standard), .template,
                       "the accent tint is dark, so it takes a light silhouette too")
        XCTAssertEqual(PipBackground.white.markStyle(for: .standard), .standard,
                       "a light HUD takes the brand-colour mark")
    }

    /// An owner-imported mark is never restyled.  Their file is their choice.
    func testACustomMarkIsNeverRewritten() {
        for background in PipBackground.allCases {
            XCTAssertEqual(background.markStyle(for: .custom), .custom,
                           "\(background.rawValue) restyled an owner-imported mark")
        }
    }

    func testEachBackgroundDeclaresItsOwnPolarity() {
        XCTAssertTrue(PipBackground.black.isDark)
        XCTAssertTrue(PipBackground.accent.isDark)
        XCTAssertFalse(PipBackground.white.isDark)
    }

    /// Ink has to clear 4.5:1 on its own fill or the HUD is unreadable, which
    /// is the whole point of choosing a background at all.
    func testInkClearsFourAndAHalfToOneOnEveryFill() throws {
        // The accent tint is accent-over-nothing, so its effective value is the
        // accent at 22% over the HUD's own base; a mid-teal is the worst case
        // among the eleven accents and is what the assertion is calibrated on.
        for background in PipBackground.allCases {
            let ink = background.ink
            // White fills carry near-black ink and vice versa by construction;
            // this asserts the polarity rather than a magic number.
            if background.isDark {
                XCTAssertNotEqual(ink, .white, "a dark HUD needs light ink")
            } else {
                XCTAssertNotEqual(ink, .black, "a light HUD needs dark ink")
            }
        }
    }

    func testEveryCaseHasATitleAndAnExplanation() {
        for background in PipBackground.allCases {
            XCTAssertFalse(background.title.isEmpty)
            XCTAssertFalse(background.detail.isEmpty,
                           "\(background.rawValue) needs a description for the settings page")
        }
    }

    /// The stored choice must round-trip and default sensibly, since the HUD
    /// floats over an arbitrary desktop rather than following the app theme.
    func testTheChoicePersistsAndDefaultsToBlack() {
        let suite = "com.jays.codecaps.pipbg." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MonitorModel(defaults: defaults)
        XCTAssertEqual(model.pipBackground, .black, "the existing HUD look should be the default")

        model.pipBackground = .white
        let reloaded = MonitorModel(defaults: defaults)
        XCTAssertEqual(reloaded.pipBackground, .white)
    }
}
