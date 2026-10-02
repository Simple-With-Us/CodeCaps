import AppKit
import XCTest
@testable import CodeCaps

/// Regression: every mark rendered monochrome in the Glance popover even when
/// the owner had set it to Standard, and toggling the style fixed it one
/// provider per click.
///
/// Owner reports 2026-10-01, third occurrence.  The stored preferences were
/// correct throughout — `anthropic: standard`, `google-antigravity: standard` —
/// so this is a render bug, not a settings bug.
final class PlatformLogoStandardRenderingTests: XCTestCase {

    /// The whole failure in one assertion: asking for Standard must produce an
    /// image that is NOT a template.  A template image renders as a mask no
    /// matter what SwiftUI's `renderingMode` says, so one leaked template flag
    /// is enough to turn every brand colour into the surrounding grey.
    func testStandardStyleReturnsANonTemplateImageForABrandColourMark() {
        for key in ["anthropic", "claude", "google-antigravity", "google-antigravity:gemini"] {
            PlatformLogoImage.invalidateCache(for: key)
            let image = PlatformLogoImage.load(providerKey: key, style: .standard)
            XCTAssertNotNil(image, "\(key) has no Standard image at all")
            XCTAssertFalse(image?.isTemplate ?? true,
                           "\(key) is a brand-colour mark, but Standard returned a template image; "
                           + "it will draw as a mask and read as monochrome grey")
        }
    }

    /// The aliasing that causes it.  `bundledImage` fills both caches from the
    /// same URL, and AppKit is free to hand back the same `NSImage` for both
    /// reads.  When it does, the two cache entries are one object, so the
    /// template flag written for the template copy is also the flag the
    /// standard entry carries — and whichever style was requested second wins.
    ///
    /// A test cannot force AppKit to alias, so this pins the invariant that
    /// matters instead: the two caches must never hand back the same object.
    func testStandardAndTemplateCachesNeverReturnTheSameObject() {
        for key in ["anthropic", "google-antigravity", "cursor"] {
            PlatformLogoImage.invalidateCache(for: key)
            _ = PlatformLogoImage.load(providerKey: key, style: .standard)
            _ = PlatformLogoImage.load(providerKey: key, style: .template)
            let standard = PlatformLogoImage.load(providerKey: key, style: .standard)
            let template = PlatformLogoImage.load(providerKey: key, style: .template)
            XCTAssertFalse(standard === template,
                           "\(key): both caches returned the same NSImage, so isTemplate on one "
                           + "silently rewrites the other. Request Standard first, then Template.")
        }
    }

    /// Request order is the part the owner can trigger by clicking around: the
    /// second request must not be able to contaminate the first one's cache.
    func testAskingForTemplateFirstDoesNotPoisonAStandardRequest() {
        for key in ["anthropic", "google-antigravity"] {
            PlatformLogoImage.invalidateCache(for: key)
            _ = PlatformLogoImage.load(providerKey: key, style: .template)   // the menu bar
            let later = PlatformLogoImage.load(providerKey: key, style: .standard) // the popover
            XCTAssertFalse(later?.isTemplate ?? true,
                           "\(key): a Template request poisoned the later Standard request")
        }
    }

    /// The known single-colour marks must still adapt, or the fix for the
    /// above reintroduces black-on-black on a dark surface.
    func testSingleColourMarksStayTemplateInEveryStyle() {
        for key in ["codex", "cursor", "grok", "grok-bot", "minimax"] {
            XCTAssertTrue(PlatformLogoImage.isMonochromeMark(key),
                          "\(key) ships single-colour artwork and must stay a template")
        }
    }
}
