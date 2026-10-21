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
    /// The flat fills of the shipped mark land exactly on the declared values
    /// once only the fully opaque pixels are compared in one explicit colour
    /// space, so this limit is tight:  it covers a unit of rounding and
    /// nothing else.  Any other artwork is far outside it.
    private static let colourTolerance = 8.0

    /// How dark a template pixel has to be.
    ///
    /// The template mark is tinted by macOS at draw time, so the file itself
    /// has to stay a black silhouette.  The colour mark's teal sits at a
    /// luminance of 0.71 and its red at 0.54, so both are outside this limit
    /// while the shipped silhouette, at about 0.13, is well inside it.
    private static let templateLuminance = 0.35

    /// How much of the template has to be that dark silhouette.
    ///
    /// The shipped template is 95.8 percent dark, with a thin tail of fully
    /// opaque pixels that the rasteriser rounded up from the anti-aliased
    /// edge.  A per-pixel rule would trip on that tail, so the rule is on the
    /// share.  The colour mark is 8 percent dark, so it cannot pass.
    private static let templateDarkShare = 0.9

    /// How much of the two silhouettes has to agree.
    ///
    /// The shipped template and the shipped colour mark agree on 94 percent
    /// of their shape, so this leaves room for a re-rasterisation of the same
    /// vector while still rejecting a filled shape or an unrelated mark.
    private static let silhouetteOverlap = 0.85

    /// The grid each silhouette is reduced to before the two are compared.
    private static let silhouetteCells = 48

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
        let pixels = try XCTUnwrap(Self.srgbPixels(of: url),
                                   "\(Self.colourMark).png could not be read as a bitmap")
        let colours = Self.opaqueColours(of: pixels)
        XCTAssertFalse(colours.isEmpty, "\(Self.colourMark).png has no fully opaque pixels")

        for (role, target) in try Self.declaredRingColours() {
            let closest = colours.map { Self.distance($0, target) }.min() ?? .greatestFiniteMagnitude
            XCTAssertLessThanOrEqual(closest, Self.colourTolerance, """
                the \(role) ring is missing from \(Self.colourMark).png:  the closest fully opaque \
                pixel is \(Self.describe(closest)) units from the declared colour, so the bundled \
                artwork is not the owner's mark.
                """)
        }
    }

    /// The template mark is drawn as a silhouette in three places, so its
    /// content has to be the owner's mark and not just any opaque PNG.
    ///
    /// The three load sites force `isTemplate = true`, so macOS tints
    /// whatever shape the file holds instead of falling back to an SF
    /// Symbol.  That makes a substituted file worse than a missing one:  a
    /// black square, the colour mark or another brand's silhouette would all
    /// draw quietly and wrongly.
    ///
    /// Two properties rule that out.  The file has to stay black, because
    /// macOS tints it.  And its shape has to be the same mark the About and
    /// Settings pages draw, so the menu bar and the two floating headers
    /// cannot show a different artwork from the rest of the app.
    func testTheTemplateMarkIsTheDarkOwnerSilhouette() throws {
        let bundle = try XCTUnwrap(ResourceBundle.resolved,
                                    "the SwiftPM resource bundle could not be resolved at all")
        let templateURL = try XCTUnwrap(bundle.url(forResource: Self.templateMark, withExtension: "png"),
                                         "\(Self.templateMark).png is missing from the CodeCaps resource bundle")
        let colourURL = try XCTUnwrap(bundle.url(forResource: Self.colourMark, withExtension: "png"),
                                       "\(Self.colourMark).png is missing from the CodeCaps resource bundle")
        let templatePixels = try XCTUnwrap(Self.srgbPixels(of: templateURL),
                                           "\(Self.templateMark).png could not be read as a bitmap")
        let colourPixels = try XCTUnwrap(Self.srgbPixels(of: colourURL),
                                         "\(Self.colourMark).png could not be read as a bitmap")

        let templateColours = Self.opaqueColours(of: templatePixels)
        XCTAssertFalse(templateColours.isEmpty, "\(Self.templateMark).png has no fully opaque pixels")
        let dark = templateColours.filter { Self.luminance($0) <= Self.templateLuminance }.count
        let darkShare = templateColours.isEmpty ? 0 : Double(dark) / Double(templateColours.count)
        XCTAssertGreaterThanOrEqual(darkShare, Self.templateDarkShare, """
            \(Self.templateMark).png is not the dark owner silhouette:  only \(Int(darkShare * 100)) \
            percent of its opaque pixels are dark, and macOS tints this file at draw time, so a \
            coloured file would draw the wrong artwork in every appearance.
            """)

        let templateGrid = Self.silhouetteGrid(of: templatePixels)
        let colourGrid = Self.silhouetteGrid(of: colourPixels)
        XCTAssertFalse(templateGrid.isEmpty, "\(Self.templateMark).png has no opaque silhouette")
        XCTAssertFalse(colourGrid.isEmpty, "\(Self.colourMark).png has no opaque silhouette")
        let overlap = zip(templateGrid, colourGrid).reduce(0.0) { $0 + min($1.0, $1.1) }
        let union = zip(templateGrid, colourGrid).reduce(0.0) { $0 + max($1.0, $1.1) }
        let agreement = union > 0 ? overlap / union : 0
        XCTAssertGreaterThanOrEqual(agreement, Self.silhouetteOverlap, """
            \(Self.templateMark).png is not the same silhouette as \(Self.colourMark).png:  the two \
            agree on only \(Int(agreement * 100)) percent of their shape, so the menu bar, the PiP \
            widget header and the Glance popover header would draw a different artwork from the \
            one the About and Settings pages show.
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

    /// The raster drawn into one explicit sRGB space.
    ///
    /// The shipped PNGs carry no iCCP, sRGB or gAMA chunk, so reading them
    /// straight through `NSBitmapImageRep` hands back premultiplied
    /// components in an uncalibrated space:  an edge pixel's colour is not
    /// the artwork's colour.  Drawing into an sRGB context normalises the
    /// space, and taking only the fully opaque pixels means the flat fills
    /// are compared as they were drawn.
    private static func srgbPixels(of url: URL) -> (width: Int, height: Int, bytes: [UInt8])? {
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
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        return (width, height, bytes)
    }

    /// The fully opaque pixels, in sRGB.
    private static func opaqueColours(of pixels: (width: Int, height: Int, bytes: [UInt8])) -> [(Double, Double, Double)] {
        var colours: [(Double, Double, Double)] = []
        pixels.bytes.withUnsafeBufferPointer { buffer in
            for index in 0..<(pixels.width * pixels.height) {
                guard buffer[index * 4 + 3] == 255 else { continue }
                colours.append((Double(buffer[index * 4]) / 255.0,
                                Double(buffer[index * 4 + 1]) / 255.0,
                                Double(buffer[index * 4 + 2]) / 255.0))
            }
        }
        return colours
    }

    /// The mark's opaque silhouette, normalised by its own bounding box and
    /// reduced to a grid of coverage fractions.
    ///
    /// Normalising by the bounding box is what lets a cropped black template
    /// and a 512px colour raster be compared at all:  the artwork lands in
    /// the same place in the grid even though the canvases differ.
    private static func silhouetteGrid(of pixels: (width: Int, height: Int, bytes: [UInt8])) -> [Double] {
        let (width, height, bytes) = pixels
        var minX = width, maxX = -1, minY = height, maxY = -1
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] == 255 {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return [] }
        let boxWidth = maxX - minX + 1
        let boxHeight = maxY - minY + 1
        let cells = silhouetteCells
        var grid = [Double](repeating: 0, count: cells * cells)
        for y in 0..<height {
            for x in 0..<width where bytes[(y * width + x) * 4 + 3] == 255 {
                let cellX = min(cells - 1, (x - minX) * cells / boxWidth)
                let cellY = min(cells - 1, (y - minY) * cells / boxHeight)
                grid[cellY * cells + cellX] += 1.0
            }
        }
        let perCell = Double(boxWidth) * Double(boxHeight) / Double(cells * cells)
        for index in grid.indices { grid[index] = min(1.0, grid[index] / perCell) }
        return grid
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

    /// The perceived brightness of a colour.
    private static func luminance(_ colour: (Double, Double, Double)) -> Double {
        0.2126 * colour.0 + 0.7152 * colour.1 + 0.0722 * colour.2
    }

    /// A distance in plain words.
    ///
    /// `Int()` traps on a value this large, and a test that crashes while
    /// reporting a failure reports nothing at all, so the distance is
    /// formatted rather than converted.
    private static func describe(_ distance: Double) -> String {
        distance < 1_000_000 ? "\(Int(distance))" : "no comparable pixel"
    }
}
