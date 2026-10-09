import AppKit
import XCTest
@testable import CodeCaps

/// The light accents and the slider rail, both reported by the owner
/// (2026-10-06): the runaway-usage sliders were "barely visible" and the track
/// could come up black, and every accent in the table was dark-leaning so
/// there was no light option at all.
final class AccentContrastTests: XCTestCase {

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "com.jays.codecaps.accent.tests." + UUID().uuidString)
        originalAccent = defaults?.string(forKey: "accentChoice")
    }

    private var defaults: UserDefaults?
    private var originalAccent: String?

    override func tearDown() {
        if let defaults, let originalAccent {
            defaults.set(originalAccent, forKey: "accentChoice")
        }
        defaults = nil
        super.tearDown()
    }

    /// Relative luminance, for the contrast checks below.
    private func luminance(_ hex: UInt32) -> Double {
        func channel(_ value: UInt32) -> Double {
            let c = Double((value >> 0) & 0xFF) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = channel((hex >> 16) & 0xFF)
        let g = channel((hex >> 8) & 0xFF)
        let b = channel(hex & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// Every accent must be able to carry readable ink in **both** appearances.
    ///
    /// This is the check that would have caught white-on-Lemon before it
    /// shipped — and, as it turned out, white-on-teal in Dark appearance too,
    /// since the Dark values are deliberately bright (teal `#4FD1C5`) and white
    /// on those is 1.87:1.  `Theme.readableInk` picks whichever of black/white
    /// actually measures better, so the assertion is that the *chosen* ink
    /// always clears 4.5:1.
    func testEveryAccentHasReadableInkInBothAppearances() {
        for choice in AccentChoice.allCases {
            for (name, hex) in [("light", choice.lightHex), ("dark", choice.darkHex)] {
                let ink = Theme.readableInk(on: hex)
                let inkHex: UInt32 = ink == .white ? 0xFFFFFF : 0x14181C
                let ratio = contrast(hex, inkHex)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, """
                    \(choice.rawValue) \(name) (#\(String(hex, radix: 16))) can only carry \
                    \(String(hex == inkHex ? "itself" : "the opposite ink")) at \
                    \(String(format: "%.2f", ratio)):1, under the 4.5:1 needed for text.
                    """)
            }
        }
    }

    /// The four light accents must be light in the light appearance, since that
    /// is the appearance where they are read against a near-white surface.
    func testTheLightAccentsAreLightInTheLightAppearance() {
        for choice in AccentChoice.allCases where choice.isLight {
            XCTAssertGreaterThan(luminance(choice.lightHex), 0.35,
                                 "\(choice.rawValue) is offered as a light accent but is not light")
        }
        // And every accent must still be visible against the surface it is
        // drawn on in its own appearance, which is the property that matters
        // for a colour used as text or an icon.
        XCTAssertGreaterThan(contrast(0x1C1E20, AccentChoice.teal.darkHex), 3.0,
                             "the Dark-appearance teal must read against the dark background")
        XCTAssertGreaterThan(contrast(0xF5F7F7, AccentChoice.teal.lightHex), 3.0,
                             "the Light-appearance teal must read against the light background")
    }

    /// The slider rail is the reason the control read as missing.  It has to
    /// stay visible against the app's own surface in both appearances, which is
    /// the contrast an empty rail actually has to survive.
    func testSliderTrackStaysVisibleAgainstBothSurfaces() {
        // Theme.sliderTrack alphas, over Theme.groupBand, which is what the
        // runaway rows sit on.
        let lightSurface: UInt32 = 0xE1E6E7
        let darkSurface: UInt32 = 0x111214
        // 20% black over the light band, 28% white over the dark one, blended
        // by hand so the test states the number rather than trusting the token.
        let lightTrack = blend(fg: 0x000000, alpha: 0.20, over: lightSurface)
        let darkTrack = blend(fg: 0xFFFFFF, alpha: 0.28, over: darkSurface)

        XCTAssertGreaterThan(contrast(lightTrack, lightSurface), 1.25,
                             "the light-appearance rail is invisible against the surface it sits on")
        XCTAssertGreaterThan(contrast(darkTrack, darkSurface), 1.25,
                             "the dark-appearance rail is invisible against the surface it sits on")
    }

    private func blend(fg: UInt32, alpha: Double, over bg: UInt32) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let f = Double((fg >> shift) & 0xFF)
            let b = Double((bg >> shift) & 0xFF)
            return UInt32((f * alpha + b * (1 - alpha)).rounded())
        }
        return (channel(16) << 16) | (channel(8) << 8) | channel(0)
    }

    /// The menu bar mark was template-tinted, which is why no accent ever
    /// reached it.  A tinted mark must come back non-template, or macOS will
    /// discard its pixels and repaint it grey.
    func testAMenuBarAccentTintIsNotATemplateImage() throws {
        let source = try XCTUnwrap(PlatformLogoImage.menuBarImage(providerKey: "openai",
                                                                  style: .standard,
                                                                  isDarkMode: true))
        let tinted = try XCTUnwrap(MenuBarAccent.tinted(source, isDark: true))
        XCTAssertFalse(tinted.isTemplate,
                       "a tinted menu bar mark stayed a template, so macOS will discard the accent again")
        XCTAssertEqual(tinted.size, source.size, "tinting must not resize the mark")
    }

    func testTintingNothingReturnsNothing() {
        XCTAssertNil(MenuBarAccent.tinted(nil, isDark: true),
                     "tinting a missing mark must not invent one")
    }
}
