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
    /// The artwork is the owner's vector rasterised, so the flat fills carry
    /// the declared values exactly, and the tolerance only has to absorb the
    /// rounding of the rasteriser.  The limit sits far below the distance to
    /// any other artwork, so a black silhouette, a greyscale upscale or
    /// another brand's mark is still rejected.
    private static let colourTolerance = 8.0

    /// How dark a pixel of the template mark has to be to count as the
    /// owner's ink.
    ///
    /// The template is the mark in a single near-black over transparency, so
    /// every one of its flat fills is well under this.  Only the anti-aliased
    /// edge pixels are lighter than the ink.
    private static let templateInkLimit = 0.35

    /// The share of the template mark's opaque pixels that have to be dark
    /// ink for the file to be the owner's silhouette.
    ///
    /// The shipped mark's anti-aliased edges are a fraction of a percent of
    /// its opaque pixels, so the share is a long way above this.
    private static let templateInkShare = 0.95

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
        let raster = try XCTUnwrap(Self.rawSamples(of: url),
                                   "\(Self.colourMark).png could not be read as a bitmap")
        let sampled = Self.sampledPixels(of: raster).opaque
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

    /// The template mark is content too, not just a file that loads.
    ///
    /// The menu bar, the PiP widget header and the Glance popover header
    /// draw it with `isTemplate = true`, so macOS tints whatever shape the
    /// file contains rather than falling back to an SF Symbol.  A black
    /// square, the colour mark or another brand's silhouette still loads,
    /// still rasterises and would be tinted into all three surfaces.
    ///
    /// So the template is sampled the way the colour mark is:  its opaque
    /// pixels have to be the owner's dark ink, and it has to keep the
    /// transparency that makes it a silhouette rather than a filled block.
    func testTheTemplateMarkIsTheDarkOwnerSilhouette() throws {
        let bundle = try XCTUnwrap(ResourceBundle.resolved,
                                    "the SwiftPM resource bundle could not be resolved at all")
        let url = try XCTUnwrap(bundle.url(forResource: Self.templateMark, withExtension: "png"),
                                "\(Self.templateMark).png is missing from the CodeCaps resource bundle")
        let raster = try XCTUnwrap(Self.rawSamples(of: url),
                                   "\(Self.templateMark).png could not be read as a bitmap")
        let pixels = Self.sampledPixels(of: raster)
        XCTAssertFalse(pixels.opaque.isEmpty, "\(Self.templateMark).png has no visible pixels")

        let ink = pixels.opaque.filter { max($0.0, max($0.1, $0.2)) < Self.templateInkLimit }.count
        let share = Double(ink) / Double(pixels.opaque.count)
        XCTAssertGreaterThanOrEqual(share, Self.templateInkShare, """
            \(Self.templateMark).png is not the owner's dark silhouette:  only \
            \(Int(share * 100))% of its opaque pixels are dark ink, so the menu bar, the PiP \
            widget header and the Glance popover header would tint artwork that is not the \
            owner's mark.
            """)

        XCTAssertGreaterThan(pixels.transparent, pixels.opaque.count, """
            \(Self.templateMark).png is a filled block rather than a silhouette:  its transparent \
            pixels do not outnumber its opaque ones, so a black square would pass as the owner's \
            mark.
            """)
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

    /// A raster read straight out of a PNG:  RGBA, premultiplied, four
    /// bytes per pixel, row by row.
    private struct Raster {
        let width: Int
        let height: Int
        let bytes: [UInt8]
    }

    /// The pixels of a bundled PNG, read without any colour management.
    ///
    /// The artwork carries no colour profile, so a sample that is converted
    /// into another colour space no longer carries the value the file stores:
    /// every flat fill lands a visible distance away from the palette, and the
    /// comparison has to be loosened to absorb it.  So the PNG is drawn into
    /// a known 8-bit RGBA context in the image's own colour space, where the
    /// samples are copied rather than converted, and the byte order and the
    /// premultiplication are not a matter of guesswork either.
    private static func rawSamples(of url: URL) -> Raster? {
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drew = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let context = CGContext(data: base, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: cgImage.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        return Raster(width: width, height: height, bytes: bytes)
    }

    /// Every fourth pixel of the raster, split into the fully opaque samples
    /// and the number of fully transparent ones.  Every fourth pixel is
    /// enough to catch the flat fills of the two rings and the shape of the
    /// silhouette without walking a quarter of a million pixels.
    ///
    /// Only fully opaque pixels are sampled.  The samples are premultiplied,
    /// so a half-covered edge pixel carries a darker colour than the artwork
    /// does and must not stand in for a flat fill.
    private static func sampledPixels(of raster: Raster) -> (opaque: [(Double, Double, Double)], transparent: Int) {
        var opaque: [(Double, Double, Double)] = []
        var transparent = 0
        for y in stride(from: 0, to: raster.height, by: 4) {
            for x in stride(from: 0, to: raster.width, by: 4) {
                let offset = (y * raster.width + x) * 4
                let alpha = raster.bytes[offset + 3]
                if alpha == 0 {
                    transparent += 1
                    continue
                }
                guard alpha >= 253 else { continue }   // 0.99 of full opacity
                opaque.append((Double(raster.bytes[offset]) / 255.0,
                               Double(raster.bytes[offset + 1]) / 255.0,
                               Double(raster.bytes[offset + 2]) / 255.0))
            }
        }
        return (opaque, transparent)
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
