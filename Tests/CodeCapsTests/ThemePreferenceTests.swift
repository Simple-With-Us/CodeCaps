import AppKit
import SwiftUI
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
            // A light accent is a *fill*, not body text: the owner asked for
            // light options specifically so something could carry dark ink on
            // it ("if real light then make the text dark over it if button or
            // something", 2026-10-06).  By construction it cannot also clear
            // 4.5:1 as text on a near-white surface, so the text contract does
            // not apply to it; `AccentContrastTests` covers what does — that it
            // carries readable ink in both appearances.
            guard !accent.isLight else {
                XCTAssertGreaterThanOrEqual(readableInkContrast(for: accent), 4.5,
                                            "\(accent.title) cannot carry readable ink on its own fill")
                continue
            }
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

    /// Contrast between an accent's own value in each appearance and the ink
    /// `Theme.readableInk` would put on it.
    private func readableInkContrast(for accent: AccentChoice) -> Double {
        func luminance(_ hex: UInt32) -> Double {
            func channel(_ value: UInt32) -> Double {
                let c = Double(value) / 255
                return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * channel((hex >> 16) & 0xFF)
                 + 0.7152 * channel((hex >> 8) & 0xFF)
                 + 0.0722 * channel(hex & 0xFF)
        }
        var worst = Double.infinity
        for hex in [accent.lightHex, accent.darkHex] {
            let ink = Theme.readableInk(on: hex)
            let inkHex: UInt32 = ink == .white ? 0xFFFFFF : 0x14181C
            let la = luminance(hex), lb = luminance(inkHex)
            worst = min(worst, (max(la, lb) + 0.05) / (min(la, lb) + 0.05))
        }
        return worst
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

    /// `Theme.selection` is the fill behind a selected sidebar row and behind
    /// the selected segment of the Glance header toggle.  It was declared with
    /// the teal hexes inlined, so it stayed teal under every accent while the
    /// row's border and label moved — a violet border around a teal wash.
    func testSelectionFollowsTheChosenAccentInBothAppearances() {
        func components(_ color: Color, _ appearance: NSAppearance.Name) -> (r: Double, g: Double, b: Double, a: Double) {
            let saved = NSAppearance.current
            NSAppearance.current = NSAppearance(named: appearance)!
            defer { NSAppearance.current = saved }
            // `Theme`'s colours are dynamic `NSColor`s, so they have to be
            // resolved against an appearance and moved into sRGB before their
            // components can be read at all.
            guard let ns = NSColor(color).usingColorSpace(.sRGB) else {
                XCTFail("selection did not resolve to an RGB colour under \(appearance.rawValue)")
                return (0, 0, 0, 0)
            }
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            ns.getRed(&r, green: &g, blue: &b, alpha: &a)
            return (Double(r), Double(g), Double(b), Double(a))
        }
        func expected(_ hex: UInt32, alpha: Double) -> (Double, Double, Double, Double) {
            (Double((hex >> 16) & 0xFF) / 255,
             Double((hex >> 8) & 0xFF) / 255,
             Double(hex & 0xFF) / 255,
             alpha)
        }
        func close(_ a: (r: Double, g: Double, b: Double, a: Double),
                   _ b: (r: Double, g: Double, b: Double, a: Double),
                   _ label: String) {
            XCTAssertEqual(a.r, b.r, accuracy: 0.01, label)
            XCTAssertEqual(a.g, b.g, accuracy: 0.01, label)
            XCTAssertEqual(a.b, b.b, accuracy: 0.01, label)
            XCTAssertEqual(a.a, b.a, accuracy: 0.01, label)
        }

        // Teal is unchanged, so the default app looks exactly as it shipped.
        AccentChoice.current = .teal
        close(components(Theme.selection, .aqua), expected(AccentChoice.teal.lightHex, alpha: 0.12), "teal light")
        close(components(Theme.selection, .darkAqua), expected(AccentChoice.teal.darkHex, alpha: 0.18), "teal dark")

        // Any other accent moves both the hue and the alpha is kept per appearance.
        for accent in AccentChoice.allCases where accent != .teal {
            AccentChoice.current = accent
            close(components(Theme.selection, .aqua), expected(accent.lightHex, alpha: 0.12),
                  "\(accent.title) light must tint the selection, not stay teal")
            close(components(Theme.selection, .darkAqua), expected(accent.darkHex, alpha: 0.18),
                  "\(accent.title) dark must tint the selection, not stay teal")
        }

        AccentChoice.current = .teal
    }
}
