import XCTest
@testable import CodeCaps
import QuotaCore

/// Which artwork the PiP HUD draws beside each provider.  Automatic keeps the
/// shipped background-following behaviour; the two explicit choices exist
/// because the owner asked to choose which logo the PiP uses (2026-11-27).
@MainActor
final class PipLogoStyleTests: XCTestCase {

    /// Automatic is exactly the old rule: silhouettes on a dark HUD, brand
    /// colour on a white one, always monochrome-forced.
    func testAutomaticFollowsTheBackgroundAndForcesMonochrome() {
        for background in PipBackground.allCases {
            let presentation = PipLogoStyle.automatic.presentation(
                on: background, ownerStyle: .standard)
            XCTAssertEqual(presentation.style, background.markStyle(for: .standard),
                           "\(background.rawValue) changed its mark rule under Automatic")
            XCTAssertTrue(presentation.forceMonochrome,
                          "\(background.rawValue) must keep the monochrome default")
        }
    }

    /// Brand Color pins the full-colour mark whatever the background.
    func testBrandColorPinsTheColourMark() {
        for background in PipBackground.allCases {
            let presentation = PipLogoStyle.brandColor.presentation(
                on: background, ownerStyle: .standard)
            XCTAssertEqual(presentation.style, .standard,
                           "\(background.rawValue) must not restyle the colour mark")
            XCTAssertFalse(presentation.forceMonochrome,
                           "\(background.rawValue) must not force monochrome on a colour mark")
        }
    }

    /// Light/Dark pins the adapting silhouette.
    func testLightDarkPinsTheTemplateMark() {
        for background in PipBackground.allCases {
            let presentation = PipLogoStyle.lightDark.presentation(
                on: background, ownerStyle: .standard)
            XCTAssertEqual(presentation.style, .template,
                           "\(background.rawValue) must keep the light/dark silhouette")
            XCTAssertTrue(presentation.forceMonochrome,
                          "\(background.rawValue) must force monochrome on the silhouette")
        }
    }

    /// An owner-imported mark is never restyled in any PiP choice; only the
    /// monochrome forcing follows the style.
    func testACustomMarkIsNeverRewritten() {
        for style in PipLogoStyle.allCases {
            for background in PipBackground.allCases {
                let presentation = style.presentation(on: background, ownerStyle: .custom)
                XCTAssertEqual(presentation.style, .custom,
                               "\(style.rawValue) restyled an owner-imported mark on \(background.rawValue)")
            }
        }
        XCTAssertTrue(PipLogoStyle.automatic.presentation(on: .black, ownerStyle: .custom).forceMonochrome)
        XCTAssertFalse(PipLogoStyle.brandColor.presentation(on: .black, ownerStyle: .custom).forceMonochrome)
    }

    /// The preference round-trips through its raw value, so a saved choice
    /// restores instead of silently reverting to Automatic.
    func testRawValueRoundTrips() {
        for style in PipLogoStyle.allCases {
            XCTAssertEqual(PipLogoStyle(rawValue: style.rawValue), style)
        }
        XCTAssertNil(PipLogoStyle(rawValue: "bogus"),
                     "an unknown saved value must fall back to Automatic at the caller")
    }
}
