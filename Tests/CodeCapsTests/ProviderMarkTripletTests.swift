import AppKit
import XCTest
@testable import CodeCaps

/// Every provider mark must ship three explicit variants — colour, light ink and
/// dark ink — and every one of them must resolve through the real loader.
///
/// The owner reported that no provider logo appeared at all except the one
/// custom mark on disk.  Measurement ruled out the obvious causes: the assets
/// were present, `Bundle.url(forResource:)` found every one, and
/// `PlatformLogoImage.load` returned a valid image for all eighteen provider
/// keys in a test process.  What was left was the delivery itself — the marks
/// were SVGs, which come back as `_NSSVGImageRep`, a PRIVATE AppKit class, and
/// the Muse rasters had an opaque white background baked in.
///
/// These assertions pin the delivered contract rather than a particular
/// implementation: whatever draws a mark must be an `NSBitmapImageRep`, so a
/// private rep cannot creep back in through any path.
final class ProviderMarkTripletTests: XCTestCase {
    private static let providerKeys = [
        "anthropic", "claude", "openai", "codex",
        "google-antigravity", "antigravity",
        "google-antigravity:gemini", "google-antigravity:third-party", "gemini",
        "xai", "grok", "grok-cli", "grok-bot",
        "minimax", "muse", "muse-assist", "muse-code", "cursor",
    ]

    override func setUp() {
        super.setUp()
        PlatformLogoImage.invalidateCaches()
    }

    func testEveryProviderResolvesInEveryStyleAndAppearance() {
        var unresolved: [String] = []
        for key in Self.providerKeys {
            for style in [MarkStyle.standard, .template] {
                for isDark in [false, true] {
                    if PlatformLogoImage.load(providerKey: key, style: style, isDarkMode: isDark) == nil {
                        unresolved.append("\(key) \(style.rawValue) \(isDark ? "dark" : "light")")
                    }
                }
            }
        }
        XCTAssertTrue(unresolved.isEmpty,
                      "these marks drew the placeholder glyph: \(unresolved.joined(separator: ", "))")
    }

    /// The failure that started this was an SVG resolving to `_NSSVGImageRep`.
    /// Whatever the artwork, a delivered mark must be a bitmap.
    func testEveryDeliveredMarkIsABitmapNotAPrivateRepresentation() {
        for key in Self.providerKeys {
            for style in [MarkStyle.standard, .template] {
                for isDark in [false, true] {
                    guard let image = PlatformLogoImage.load(providerKey: key, style: style, isDarkMode: isDark) else { continue }
                    XCTAssertTrue(image.representations.first is NSBitmapImageRep,
                                  "\(key) \(style.rawValue) came back as "
                                  + "\(image.representations.first.map { String(describing: type(of: $0)) } ?? "no representation")"
                                  + ", which is the private-rep path the owner reported as invisible.")
                }
            }
        }
    }

    /// A mark must not carry an opaque background, which is what made the Muse
    /// PNGs read as a white box on any non-white surface.
    func testNoDeliveredMarkHasAnOpaqueBackground() {
        for key in Self.providerKeys {
            for style in [MarkStyle.standard, .template] {
                guard let image = PlatformLogoImage.load(providerKey: key, style: style),
                      let rep = image.representations.first as? NSBitmapImageRep,
                      rep.pixelsWide > 0, rep.pixelsHigh > 0 else { continue }
                let corner = rep.colorAt(x: 0, y: 0)
                XCTAssertNotEqual(corner?.alphaComponent ?? 0, 1.0,
                                  "\(key) \(style.rawValue) has an opaque background; it would draw as a white box.")
            }
        }
    }

    /// Light and Dark are different ink, not the same file twice, so a Dark
    /// surface never gets a black silhouette that vanishes into it.
    func testLightAndDarkVariantsDiffer() {
        for key in Self.providerKeys {
            guard let light = PlatformLogoImage.load(providerKey: key, style: .template, isDarkMode: false),
                  let dark = PlatformLogoImage.load(providerKey: key, style: .template, isDarkMode: true) else {
                continue
            }
            XCTAssertNotEqual(light.representations.first as? NSBitmapImageRep,
                              dark.representations.first as? NSBitmapImageRep,
                              "\(key) served one identical silhouette for both appearances.")
        }
    }
}