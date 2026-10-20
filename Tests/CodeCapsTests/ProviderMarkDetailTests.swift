import AppKit
import XCTest

/// A provider mark must be sharp at the size the app actually draws it.
///
/// Owner report, 2026-10-19: several of the bundled logos were visibly soft.
/// The cause was measured rather than assumed.  The marks were not low
/// resolution in the sense of a small canvas — the canvases were 256px and
/// 512px — they were *blurry upscales*.  The artwork inside each canvas was
/// carried by a 16px anti-aliased edge band, which is roughly 3.5 device pixels
/// of blur once the mark is drawn at 28pt on a 2x display.  A real raster of
/// the same artwork has a one-pixel edge, and that is the difference between a
/// crisp logo and a soft one.
///
/// The measure is the width of the anti-aliased transition at the mark's
/// silhouette, in the pixels the mark is drawn at.  It is the number of
/// partially transparent pixels over the mark's outline, which is how wide the
/// transition runs.  A mark whose outline is a hard step has almost no
/// partially transparent pixels; a mark that is a blurry upscale spreads its
/// transition over several pixels, and that is what reads on screen as a soft
/// logo.  Interior translucency counts towards the band too, so a mark that is
/// soft inside reads as soft here — that errs towards flagging a mark rather
/// than hiding one.
///
/// This guard is what stops the defect coming back.  It failed the shipped
/// assets that were soft (Cursor 1.81, Gemini 1.73, Grok 1.70, Claude 2.07
/// device pixels) and it failed a rebuild of the Antigravity colour star that
/// would have softened it from 0.89 to 5.43.  `scripts/regenerate-provider-marks.py`
/// enforces the same rule before it writes anything.
final class ProviderMarkDetailTests: XCTestCase {

    /// The Mac app draws a provider mark into a square frame 28pt across at
    /// 2x, so 56 device pixels.  The companion draws one 36pt across at 3x.
    private static let macDisplayPixels = 56.0
    private static let iosDisplayPixels = 108.0

    /// A mark with real detail has a one-pixel edge.  These files are allowed
    /// more than that, and each one is a known exception rather than a gap:
    ///
    /// - `openai-*` and `grok-bot-*` are soft-edged artwork.  This repository
    ///   ships `openai.svg` and `grok-bot.svg`, but they are *different
    ///   renderings* of those marks — the OpenAI vector draws a solid knot
    ///   where the shipped raster draws a hollow one, and the Grok bot vector
    ///   changes the eye cutouts.  Substituting them would be substituting
    ///   artwork, so there is no same-art higher-resolution copy to raise
    ///   these to.  They need the owner to supply one.
    ///
    /// Everything else must hold to the one-pixel rule.
    private static let softByDesign: Set<String> = [
        "openai-color.png", "openai-dark.png", "openai-light.png",
        "grok-bot-color.png", "grok-bot-dark.png", "grok-bot-light.png",
    ]

    /// A mark that is a blurry upscale has an edge several pixels wide.  A
    /// real raster of the same artwork has a one-pixel edge.  The limit is
    /// deliberately tight: it is set at a hair above the widest edge any
    /// shipped mark legitimately has, so a regression trips it.
    ///
    /// On the Mac the widest legitimate edge is 0.47 device pixels, and the
    /// soft marks that were shipped measured 1.70 to 2.07.
    ///
    /// On the companion the widest legitimate edge is 1.54 device pixels, in
    /// the 1x Muse Assist file: a 24px raster cannot do better than about
    /// one and a half device pixels on a 1x screen, and that is the floor of
    /// what the format allows.  The 1x MiniMax file that was shipped as a
    /// blurry upscale measured 1.72, which is over the limit.
    private static let macEdgeLimit = 1.0
    private static let iosEdgeLimit = 1.60

    private static let solidAlpha = 247
    private static let visibleAlpha = 8

    /// The repository root, found from this file's own path so the test reads
    /// the committed assets rather than a copy the build happened to make.
    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // CodeCapsTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
    }

    // MARK: - The Mac app's marks

    func testNoBundledMarkHasASoftSilhouette() throws {
        let directory = Self.repositoryRoot
            .appendingPathComponent("Sources/CodeCaps/Resources/ProviderMarks")
        let files = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // A path that no longer resolves would make this test pass by finding
        // nothing, so the count is asserted rather than assumed.
        XCTAssertGreaterThan(files.count, 30,
                             "expected the bundled provider marks in \(directory.path), found \(files.count)")

        var soft: [String] = []
        for file in files {
            let name = file.lastPathComponent
            guard let mark = Self.edgeBand(of: file) else { continue }
            let devicePixels = mark.band * (Self.macDisplayPixels / Double(mark.width))
            if devicePixels > Self.macEdgeLimit, !Self.softByDesign.contains(name) {
                soft.append("\(name) \(String(format: "%.2f", devicePixels))px")
            }
        }
        XCTAssertTrue(soft.isEmpty,
                      "these marks have a soft silhouette at 28pt on a 2x display, which is what the owner saw: "
                      + soft.joined(separator: ", ")
                      + ".  Raise them with scripts/regenerate-provider-marks.py from a same-art higher-resolution source.")
    }

    // MARK: - The companion's marks

    /// The companion draws its marks from asset-catalog image sets.  A 1x file
    /// is drawn on a 1x screen, a 3x file on a 3x screen, so the edge has to
    /// be measured in the pixels of the screen that serves it: a 3x file with
    /// a one-pixel edge is a third-of-a-pixel edge on the device.
    func testNoCompanionMarkHasASoftSilhouette() throws {
        let catalog = Self.repositoryRoot
            .appendingPathComponent("ios/CodeCapsCompanion/Assets.xcassets")
        let imagesets = try XCTUnwrap(try FileManager.default.contentsOfDirectory(
            at: catalog, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "imageset" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        XCTAssertGreaterThan(imagesets.count, 3,
                             "expected the companion asset catalog in \(catalog.path), found \(imagesets.count)")

        var soft: [String] = []
        for imageset in imagesets {
            let densities = Self.densities(of: imageset)
            let contents = try FileManager.default.contentsOfDirectory(
                at: imageset, includingPropertiesForKeys: nil)
            for file in contents where file.pathExtension == "png" {
                guard let mark = Self.edgeBand(of: file) else { continue }
                let name = file.lastPathComponent
                let devicePixels: Double
                if let density = densities[name] {
                    // A file with a declared scale is drawn on a screen of
                    // that density, so its edge is measured against it.
                    devicePixels = mark.band / density
                } else {
                    // A single-file image set is drawn at the companion's own
                    // mark size, which is at most 108 device pixels.  Using the
                    // largest possible size is the strict reading.
                    devicePixels = mark.band * (Self.iosDisplayPixels / Double(mark.width))
                }
                if devicePixels > Self.iosEdgeLimit {
                    soft.append("\(imageset.lastPathComponent)/\(name) \(String(format: "%.2f", devicePixels))px")
                }
            }
        }
        XCTAssertTrue(soft.isEmpty,
                      "these companion marks have a soft silhouette on the screen that serves them: "
                      + soft.joined(separator: ", ")
                      + ".  Rebuild them with scripts/regenerate-provider-marks.py from a same-art higher-resolution source.")
    }

    /// The density each file in an image set serves, read from the set's
    /// `Contents.json`.  A file with a `scale` of 1x, 2x or 3x is drawn on a
    /// screen of that density.  A file with no scale is the single-file
    /// variant of a set and is drawn at the device's own resolution.
    private static func densities(of imageset: URL) -> [String: Double] {
        let contents = imageset.appendingPathComponent("Contents.json")
        guard let data = try? Data(contentsOf: contents),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = object["images"] as? [[String: Any]] else { return [:] }
        var result: [String: Double] = [:]
        for image in images {
            guard let filename = image["filename"] as? String else { continue }
            switch image["scale"] as? String {
            case "1x": result[filename] = 1
            case "2x": result[filename] = 2
            case "3x": result[filename] = 3
            default: break
            }
        }
        return result
    }

    // MARK: - Measurement

    /// The width of the anti-aliased transition at the mark's silhouette, in
    /// the mark's own pixels, together with the canvas width so the caller can
    /// convert it to the pixels the mark is drawn at.
    private static func edgeBand(of url: URL) -> (band: Double, width: Int)? {
        guard let (width, height, alpha) = alphaPlane(of: url) else { return nil }
        let count = width * height

        var visible = [UInt8](repeating: 0, count: count)
        var partial = [UInt8](repeating: 0, count: count)
        visible.withUnsafeMutableBufferPointer { visible in
            partial.withUnsafeMutableBufferPointer { partial in
                alpha.withUnsafeBufferPointer { alpha in
                    for index in 0..<count {
                        let value = alpha[index]
                        if value > Self.visibleAlpha {
                            visible[index] = 1
                            if value < Self.solidAlpha { partial[index] = 1 }
                        }
                    }
                }
            }
        }

        // The perimeter is the ring of visible pixels with a non-visible
        // neighbour.  The band is the share of the perimeter that is a
        // gradient rather than a hard step.
        var perimeter = 0
        visible.withUnsafeBufferPointer { visible in
            for y in 0..<height {
                let row = y * width
                for x in 0..<width {
                    let index = row + x
                    guard visible[index] == 1 else { continue }
                    let left = x > 0 && visible[index - 1] == 1
                    let right = x < width - 1 && visible[index + 1] == 1
                    let up = y > 0 && visible[index - width] == 1
                    let down = y < height - 1 && visible[index + width] == 1
                    if !(left && right && up && down) { perimeter += 1 }
                }
            }
        }
        guard perimeter > 0 else { return nil }

        // The band is the number of partially transparent pixels over the
        // perimeter, which is how wide the anti-aliased transition runs.
        var gradient = 0
        partial.withUnsafeBufferPointer { partial in
            for index in 0..<count where partial[index] == 1 { gradient += 1 }
        }
        return (Double(gradient) / Double(perimeter), width)
    }

    /// The alpha channel of the image, drawn into a known 8-bit RGBA context so
    /// the byte order and the premultiplication are not a matter of guesswork.
    private static func alphaPlane(of url: URL) -> (width: Int, height: Int, alpha: [UInt8])? {
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
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }

        var alpha = [UInt8](repeating: 0, count: width * height)
        bytes.withUnsafeBufferPointer { bytes in
            alpha.withUnsafeMutableBufferPointer { alpha in
                for index in 0..<(width * height) { alpha[index] = bytes[index * 4 + 3] }
            }
        }
        return (width, height, alpha)
    }
}
