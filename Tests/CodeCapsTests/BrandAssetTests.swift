import AppKit
import XCTest
@testable import CodeCaps

/// The owner's marks must be required bundled resources, not optional ones.
///
/// `BrandMarkImage.asset` is optional, so a missing bundle resource does not
/// fail loudly: the About and Settings pages quietly swap the owner's mark for
/// a generic SF Symbol, and the app still builds, ships and passes every test
/// that does not look at the bundle.  That is the same class of failure the
/// platform mark test exists for, and it is the same shape here, so the brand
/// assets get the same guarantee.
///
/// The SF Symbol fallback stays in the UI, because an empty gap is worse than
/// a stand-in, but CI is what keeps it from ever being the thing that ships.
final class BrandAssetTests: XCTestCase {
    /// The mark the About and Settings pages draw, in colour.
    private static let colourMark = "CodeCapsBrandMark"

    /// The mark the menu bar, the PiP widget header and the Glance popover
    /// header draw, as a black template.
    private static let templateMark = "CodeCapsMenuBarIcon"

    /// The two ring colours the brand palette declares, by role.
    private static let ringRoles = ["teal", "red"]

    /// How far a sampled pixel may sit from a declared ring colour.
    ///
    /// The shipped PNG is the owner's vector rasterised, so a flat fill lands
    /// a little off the declared value: the rasteriser rounds and the colour
    /// profile shifts the flats slightly.  The shipped teal sits 17 units from
    /// the declared teal and the shipped red 29.  The limit is set well above
    /// both and far below the distance to any other artwork, so a black
    /// silhouette, a greyscale upscale or another brand's mark is still
    /// rejected.
    private static let colourTolerance = 48.0

    /// The repository root, found from this file's own path so the test reads
    /// the committed palette rather than a copy the build happened to make.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CodeCapsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
    }

    /// The bundle is resolved once, lazily, and cached for the process, so this
    /// also asserts the bundle actually carries the artwork rather than
    /// existing and being empty.
    ///
    /// Both owner marks are checked.  The template mark is the one the menu
    /// bar, the PiP widget header and the Glance popover header draw, and it
    /// has no other guard:  without this it could be renamed or dropped and
    /// all three surfaces would quietly fall back to the generic SF Symbol.
    func testTheResourceBundleCarriesBothOwnerMarks() throws {
        let bundle = try XCTUnwrap(ResourceBundle.resolved,
                                    "the SwiftPM resource bundle could not be resolved at all")
        for name in [Self.colourMark, Self.templateMark] {
            let present = bundle.url(forResource: name, withExtension: "png") != nil
            XCTAssertTrue(present, """
                \(name).png is missing from the CodeCaps resource bundle.  The surfaces that draw \
                it would fall back to a generic SF Symbol instead of the owner's mark.  Check that \
                Sources/CodeCaps/Resources/\(name).png is still listed as a resource in \
                Package.swift and that the bundle was fully copied.
                """)
        }
    }

    /// A mark that resolves but will not rasterise is the same failure wearing
    /// a different hat: `NSImage` returns an object, and the surface draws
    /// nothing.
    func testBothOwnerMarksRasterise() throws {
        let bundle = try XCTUnwrap(ResourceBundle.resolved,
                                    "the SwiftPM resource bundle could not be resolved at all")
        for name in [Self.colourMark, Self.templateMark] {
            let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "png"),
                                    "\(name).png is missing from the CodeCaps resource bundle")
            let image = try XCTUnwrap(NSImage(contentsOf: url),
                                      "\(name).png is in the bundle but did not load")
            XCTAssertGreaterThan(image.size.width, 0, "\(name).png loaded with no width")
            XCTAssertNotNil(image.tiffRepresentation, "\(name).png produced no bitmap")
        }
    }

    /// The artwork itself, not just the file name.
    ///
    /// `BrandMarkImage` hardcodes `isTemplate = false`, so an assertion on
    /// that flag proves nothing about the pixels:  any PNG at all would pass
    /// it.  A black silhouette or a greyscale upscale of the mark would keep
    /// CI green and leave the About and Settings pages drawing artwork that
    /// is not the owner's, which is exactly the failure these tests exist to
    /// prevent.
    ///
    /// So the raster is sampled and checked for the two ring colours the
    /// brand palette declares.
    func testTheColourMarkCarriesTheBrandRingColours() throws {
        let bundle = try XCTUnwrap(ResourceBundle.resolved,
                                    "the SwiftPM resource bundle could not be resolved at all")
        let url = try XCTUnwrap(bundle.url(forResource: Self.colourMark, withExtension: "png"),
                                "\(Self.colourMark).png is missing from the CodeCaps resource bundle")
        let data = try Data(contentsOf: url)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: data),
                                "\(Self.colourMark).png could not be read as a bitmap")
        let sampled = Self.sampledColours(of: rep)
        XCTAssertFalse(sampled.isEmpty, "\(Self.colourMark).png has no readable pixels")

        for (role, target) in try Self.declaredRingColours() {
            let closest = sampled.map { Self.distance($0, target) }.min() ?? .greatestFiniteMagnitude
            XCTAssertLessThanOrEqual(closest, Self.colourTolerance, """
                the \(role) ring is missing from \(Self.colourMark).png:  the closest sampled \
                pixel is \(Int(closest)) units away, so the bundled artwork is not the owner's \
                mark.
                """)
        }
    }

    /// The UI keeps an SF Symbol fallback, but only as a last resort.  With the
    /// asset present the in-app surfaces must draw the owner's mark, in
    /// colour, and not a template image.
    func testTheBrandMarkResolvesInColourForTheInAppSurfaces() {
        let image = BrandMarkImage.asset
        XCTAssertNotNil(image, """
            BrandMarkImage.asset did not resolve, so the About and Settings pages would show the \
            SF Symbol fallback instead of the owner's mark.  \(Self.colourMark).png must be a \
            bundled resource of the CodeCaps target.
            """)
        XCTAssertFalse(image?.isTemplate ?? true,
                       "the brand mark must be drawn in colour, not as a template image")
    }

    /// The two ring colours the committed palette declares, read from the
    /// palette so the test follows the brand rather than a copy of it.
    private static func declaredRingColours() throws -> [(role: String, rgb: (Double, Double, Double))] {
        let url = repositoryRoot.appendingPathComponent("assets/brand/brand-colors.json")
        let data = try Data(contentsOf: url)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any],
                                  "assets/brand/brand-colors.json is not a JSON object")
        let colors = try XCTUnwrap(json["colors"] as? [String: Any],
                                   "assets/brand/brand-colors.json declares no colours")
        var rings: [(role: String, rgb: (Double, Double, Double))] = []
        for role in ringRoles {
            let entry = try XCTUnwrap(colors[role] as? [String: Any],
                                      "assets/brand/brand-colors.json declares no \(role) colour")
            let hex = try XCTUnwrap(entry["hex"] as? String,
                                    "the \(role) colour in assets/brand/brand-colors.json has no hex value")
            let rgb = try XCTUnwrap(rgb(fromHex: hex), "the \(role) hex value \(hex) is unreadable")
            rings.append((role, rgb))
        }
        return rings
    }

    /// Every fourth pixel of the raster, which is enough to catch the flat
    /// fills of the two rings without walking a quarter of a million pixels.
    private static func sampledColours(of rep: NSBitmapImageRep) -> [(Double, Double, Double)] {
        var colours: [(Double, Double, Double)] = []
        for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                colours.append((c.redComponent, c.greenComponent, c.blueComponent))
            }
        }
        return colours
    }

    private static func rgb(fromHex hex: String) -> (Double, Double, Double)? {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")).uppercased()
        guard cleaned.count == 6, let value = UInt32(cleaned, radix: 16) else { return nil }
        return (Double((value >> 16) & 0xFF) / 255.0,
                Double((value >> 8) & 0xFF) / 255.0,
                Double(value & 0xFF) / 255.0)
    }

    /// The distance between two colours in RGB units.
    private static func distance(_ a: (Double, Double, Double),
                                 _ b: (Double, Double, Double)) -> Double {
        let dr = (a.0 - b.0) * 255.0
        let dg = (a.1 - b.1) * 255.0
        let db = (a.2 - b.2) * 255.0
        return (dr * dr + dg * dg + db * db).squareRoot()
    }
}
