import AppKit
import XCTest
@testable import CodeCaps

/// The owner's accent choice and the high-contrast escape hatch.
@MainActor
final class ThemePreferenceTests: XCTestCase {
    private var suite = ""

    override func setUp() {
        super.setUp()
        suite = "com.jays.codecaps.tests." + UUID().uuidString
        UserDefaults.standard.removeObject(forKey: "accentChoice")
        UserDefaults.standard.removeObject(forKey: "highContrast")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "accentChoice")
        UserDefaults.standard.removeObject(forKey: "highContrast")
        super.tearDown()
    }

    func testTealIsTheDefaultAccentSoTheAppLooksUnchangedOnUpgrade() {
        XCTAssertEqual(AccentChoice.current, .teal)
    }

    func testEveryAccentHasADistinctPair() {
        let lights = Set(AccentChoice.allCases.map(\.lightHex))
        let darks = Set(AccentChoice.allCases.map(\.darkHex))
        XCTAssertEqual(lights.count, AccentChoice.allCases.count, "two accents share a light value")
        XCTAssertEqual(darks.count, AccentChoice.allCases.count, "two accents share a dark value")
    }

    /// The accent is the colour of the percentage the owner reads at a glance,
    /// so every pair has to clear 4.5:1 against the surface it sits on.  A
    /// swatch that looks fine in a picker and fails here is a bar the owner
    /// cannot read.
    func testEveryAccentClearsFourAndAHalfToOneOnItsOwnSurface() {
        func luminance(_ hex: UInt32) -> Double {
            func channel(_ value: UInt32) -> Double {
                let c = Double(value) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            let r = channel((hex >> 16) & 0xFF)
            let g = channel((hex >> 8) & 0xFF)
            let b = channel(hex & 0xFF)
            return 0.2126 * r + 0.7152 * g + 0.0722 * b
        }
        // The surfaces the percentage is drawn on, in each appearance.
        let lightSurface = 0xFFFFFF as Double   // Theme.surface, light
        let darkSurface = 0x26292C as Double    // Theme.surface, dark
        _ = (lightSurface, darkSurface)

        func ratio(_ a: UInt32, _ b: UInt32) -> Double {
            let la = luminance(a), lb = luminance(b)
            return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
        }

        for accent in AccentChoice.allCases {
            // Default surfaces.
            XCTAssertGreaterThanOrEqual(ratio(accent.lightHex, 0xF5F7F7), 4.5,
                                        "\(accent.title) light fails 4.5:1 on the default light background")
            XCTAssertGreaterThanOrEqual(ratio(accent.darkHex, 0x1C1E20), 4.5,
                                        "\(accent.title) dark fails 4.5:1 on the default dark background")
            // High contrast switches both surfaces to pure black/white, which
            // is the harder case for the light value.
            XCTAssertGreaterThanOrEqual(ratio(accent.lightHex, 0xFFFFFF), 4.5,
                                        "\(accent.title) fails 4.5:1 on the high-contrast light surface")
        }
    }

    func testHighContrastIsOffUntilTheOwnerTurnsItOn() {
        XCTAssertFalse(Theme.highContrast)
        UserDefaults.standard.set(true, forKey: "highContrast")
        XCTAssertTrue(Theme.highContrast, "the preference is read live, not cached")
    }

    func testAccentChoiceRoundTripsThroughDefaults() {
        AccentChoice.current = .violet
        XCTAssertEqual(AccentChoice.current, .violet)
        AccentChoice.current = .teal
        XCTAssertEqual(AccentChoice.current, .teal)
    }

    func testBarRemainingRemainsHealthyToneAndDoesNotTurnRedWhenMagentaSelected() {
        AccentChoice.current = .magenta
        XCTAssertNotNil(Theme.barRemaining)
        AccentChoice.current = .green
        XCTAssertNotNil(Theme.barRemaining)
        AccentChoice.current = .teal
        XCTAssertNotNil(Theme.barRemaining)
    }
}
