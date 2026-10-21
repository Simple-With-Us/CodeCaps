import AppKit
import XCTest
@testable import CodeCaps

/// The owner's mark must be a required bundled resource, not an optional one.
///
/// `BrandMarkImage.asset` is optional, so a missing bundle resource does not
/// fail loudly: the About and Settings pages quietly swap the owner's mark for
/// a generic SF Symbol, and the app still builds, ships and passes every test
/// that does not look at the bundle.  That is the same class of failure the
/// platform mark test exists for, and it is the same shape here, so the brand
/// asset gets the same guarantee.
///
/// The SF Symbol fallback stays in the UI, because an empty gap is worse than
/// a stand-in, but CI is what keeps it from ever being the thing that ships.
final class BrandAssetTests: XCTestCase {
    /// The bundle is resolved once, lazily, and cached for the process, so this
    /// also asserts the bundle actually carries the artwork rather than
    /// existing and being empty.
    func testTheResourceBundleCarriesTheBrandMark() throws {
        let bundle = try XCTUnwrap(ResourceBundle.resolved,
                                    "the SwiftPM resource bundle could not be resolved at all")
        let present = bundle.url(forResource: "CodeCapsBrandMark", withExtension: "png") != nil
        XCTAssertTrue(present, """
            CodeCapsBrandMark.png is missing from the CodeCaps resource bundle.  The About and \
            Settings pages would fall back to a generic SF Symbol instead of the owner's mark.  \
            Check that Sources/CodeCaps/Resources/CodeCapsBrandMark.png is still listed as a \
            resource in Package.swift and that the bundle was fully copied.
            """)
    }

    /// A mark that resolves but will not rasterise is the same failure wearing
    /// a different hat: `NSImage` returns an object, and the page draws
    /// nothing.
    func testTheBrandMarkRasterises() throws {
        let bundle = try XCTUnwrap(ResourceBundle.resolved,
                                    "the SwiftPM resource bundle could not be resolved at all")
        let url = try XCTUnwrap(bundle.url(forResource: "CodeCapsBrandMark", withExtension: "png"),
                                "CodeCapsBrandMark.png is missing from the CodeCaps resource bundle")
        let image = try XCTUnwrap(NSImage(contentsOf: url),
                                  "CodeCapsBrandMark.png is in the bundle but did not load")
        XCTAssertGreaterThan(image.size.width, 0, "CodeCapsBrandMark.png loaded with no width")
        XCTAssertNotNil(image.tiffRepresentation, "CodeCapsBrandMark.png produced no bitmap")
    }

    /// The UI keeps an SF Symbol fallback, but only as a last resort.  With the
    /// asset present the in-app surfaces must draw the owner's mark, in
    /// colour, and not a template image.
    func testTheBrandMarkResolvesInColourForTheInAppSurfaces() {
        let image = BrandMarkImage.asset
        XCTAssertNotNil(image, """
            BrandMarkImage.asset did not resolve, so the About and Settings pages would show the \
            SF Symbol fallback instead of the owner's mark.  CodeCapsBrandMark.png must be a \
            bundled resource of the CodeCaps target.
            """)
        XCTAssertFalse(image?.isTemplate ?? true,
                       "the brand mark must be drawn in colour, not as a template image")
    }
}
