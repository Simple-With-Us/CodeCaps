import AppKit
import XCTest
@testable import CodeCaps
import QuotaCore

/// Every platform the popover lists must resolve a real bundled mark.
///
/// Owner report 2026-09-30: the marks had gone generic — Codex drew a CPU chip
/// and Antigravity a plain star, which are `fallbackSymbolName` results, not
/// artwork.  Both files were present and both keys were mapped, so nothing in
/// the source had changed; the running build was simply carrying a resource
/// bundle that could not produce the image.  That is a class of failure no
/// source-level test could see, because the thing that went missing was the
/// asset, not the code.
///
/// So this walks the keys the app actually passes to `PlatformLogo` and fails
/// if any of them falls through to an SF Symbol.  A bundle that is stale,
/// half-copied, or missing a file now fails here instead of quietly shipping
/// the wrong logo.
final class PlatformLogoResourceTests: XCTestCase {
    /// The keys the app asks for.  Pool-qualified Antigravity keys are
    /// included because those are the ones #83 added and the ones a partial
    /// bundle copy is most likely to drop.
    private let providerKeys = [
        "anthropic", "claude", "openai", "codex",
        "google-antigravity", "antigravity",
        "google-antigravity:gemini", "google-antigravity:third-party",
        "gemini", "xai", "grok", "grok-cli", "grok-bot", "minimax",
        "muse", "muse-assist", "muse-code", "cursor",
    ]

    func testEveryProviderKeyResolvesABundledMark() {
        for key in providerKeys {
            for style in [MarkStyle.standard, .template] {
                let image = PlatformLogoImage.load(providerKey: key, style: style)
                XCTAssertNotNil(image, """
                    '\(key)' has no bundled mark in \(style.rawValue); the row would fall back \
                    to the SF Symbol '\(PlatformLogoImage.fallbackSymbolName(for: key))'. \
                    Check that Sources/CodeCaps/Resources/ProviderMarks is still listed as a \
                    resource in Package.swift and that the bundle was fully copied.
                    """)
            }
        }
    }

    /// The bundle is resolved once, lazily, and cached for the process.  An
    /// installed app that was built before a mark was added keeps the old
    /// bundle, so this also asserts the bundle actually carries artwork rather
    /// than existing and being empty.
    func testTheResourceBundleCarriesArtwork() throws {
        let bundle = try XCTUnwrap(ResourceBundle.resolved,
                                    "the SwiftPM resource bundle could not be resolved at all")
        let marks = ["claude", "openai", "gemini", "gemini-color", "gemini-mono",
                     "cursor", "grok", "grok-bot", "minimax", "muse", "muse-assist", "muse-code", "muse-code-dark"]
        // Every named mark must be present in some form.  Deliberately not an
        // exact count: the owner replacing the fabricated MiniMax `{M}` with
        // the real PNG mark added a file, and an equality assertion is a test
        // that fails every time an asset is corrected.
        for name in marks {
            let present = ["svg", "png"].contains { ext in
                bundle.url(forResource: name, withExtension: ext) != nil
            }
            XCTAssertTrue(present, "no artwork for '\(name)' in the resource bundle")
        }
    }

    /// A mark that resolves but will not rasterise is the same failure wearing
    /// a different hat: `NSImage` returns an object, and the row draws nothing.
    func testEveryBundledMarkRasterises() throws {
        let bundle = try XCTUnwrap(ResourceBundle.resolved)
        for name in ["claude", "openai", "gemini", "gemini-mono", "cursor", "grok", "grok-bot", "minimax", "muse", "muse-assist", "muse-code", "muse-code-dark"] {
            for ext in ["svg", "png"] {
                guard let url = bundle.url(forResource: name, withExtension: ext) else { continue }
                let image = try XCTUnwrap(NSImage(contentsOf: url), "\(name).\(ext) did not load")
                XCTAssertGreaterThan(image.size.width, 0, "\(name).\(ext) loaded with no width")
                XCTAssertNotNil(image.tiffRepresentation, "\(name).\(ext) produced no bitmap")
            }
        }
    }

    /// Owner report 2026-10-06: in the PiP HUD every bundled mark drew as the
    /// SF Symbol fallback, opening the window repeatedly never fixed it, and
    /// only the one platform with a custom mark *on disk* rendered.  A working
    /// `NSImage(contentsOf:)` in a plain process proved the artwork and the
    /// extensions were fine, so the fault had to be in resolution order rather
    /// than in the files.
    ///
    /// The bundle handle is cached for the life of the process, and it was
    /// cached without ever confirming the bundle could produce an image.  A
    /// handle resolved before the resource bundle was reachable — or pointing
    /// at a half-copied directory — stayed pinned, and every later lookup
    /// reused it.  Disk-backed custom marks do not go through that handle, which
    /// is exactly the "only MiniMax shows up" shape.
    ///
    /// So this pins the two properties that make that failure impossible to
    /// repeat silently: marks still resolve after a full cache invalidation,
    /// and a key with no artwork still degrades to the documented fallback
    /// rather than to something else.
    func testMarksStillResolveAfterCacheInvalidation() {
        for key in ["anthropic", "openai", "cursor", "grok-bot", "minimax"] {
            for style in [MarkStyle.standard, .template] {
                XCTAssertNotNil(PlatformLogoImage.load(providerKey: key, style: style),
                                "'\(key)' did not resolve before invalidation")
            }
        }
        // This is the path the owner exercised: import a mark, then keep
        // drawing.  Every bundled mark must survive it.
        PlatformLogoImage.invalidateCaches()
        for key in ["anthropic", "openai", "cursor", "grok-bot"] {
            XCTAssertNotNil(PlatformLogoImage.load(providerKey: key, style: .template),
                            "'\(key)' did not resolve after invalidateCaches() — a pinned bundle handle is being reused")
        }
    }

    /// A key with no artwork must fall back rather than invent one, and must
    /// not leave a stale image behind after invalidation.
    func testUnknownKeyFallsBackAndStaysEmptyAfterInvalidation() {
        XCTAssertNil(PlatformLogoImage.load(providerKey: "not-a-real-provider", style: .template))
        PlatformLogoImage.invalidateCaches()
        XCTAssertNil(PlatformLogoImage.load(providerKey: "not-a-real-provider", style: .template),
                     "an unknown provider began resolving something, which means a cache is serving the wrong key")
    }

    /// The pool-qualified Antigravity keys are the newest mapping and the only
    /// ones that resolve through `platformKey(of:)`; pin that the fallback
    /// still finds the platform-level mark for an unknown pool.
    func testAnUnknownPoolFallsBackToThePlatformMark() {
        XCTAssertNotNil(PlatformLogoImage.load(providerKey: "google-antigravity:some-new-pool", style: .template))
    }

    /// Verify that Muse Code loads both standard (blue Meta SVG) and
    /// template (black Meta silhouette SVG) marks cleanly.
    func testMuseCodeResolvesDedicatedTemplateMark() throws {
        let standard = try XCTUnwrap(PlatformLogoImage.load(providerKey: "muse-code", style: .standard))
        XCTAssertFalse(standard.isTemplate)

        let template = try XCTUnwrap(PlatformLogoImage.load(providerKey: "muse-code", style: .template))
        XCTAssertTrue(template.isTemplate)
    }
}
