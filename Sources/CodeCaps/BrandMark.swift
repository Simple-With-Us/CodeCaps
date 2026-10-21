import AppKit
import SwiftUI

/// The owner's mark in colour, on a transparent background.
///
/// The vector is the source of truth and lives with the rest of the brand
/// family in `assets/brand/`.  This PNG is that vector rasterised, because
/// AppKit cannot draw an SVG, and it is bundled so the in-app surfaces can
/// show the real mark instead of a stand-in.
///
/// The menu bar keeps the owner's own black template icon, which is what that
/// artwork is for and where it belongs.  The PiP widget header and the Glance
/// popover header keep that same black template on purpose, so the template
/// mark still appears in the menu bar and in those two headers, and nowhere
/// else.
public enum BrandMarkImage {
    /// The mark, loaded once.  The asset is a required, bundled resource:
    /// `BrandAssetTests` fails the build if the bundle ever stops carrying it.
    /// `nil` only if the bundle is missing it, in which case every surface
    /// falls back to an SF Symbol rather than showing an empty gap.
    public static let asset: NSImage? = {
        guard let url = ResourceBundle.resolved?.url(forResource: "CodeCapsBrandMark", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        return image
    }()

    /// The ground the mark needs in dark appearance.  The needle and the six
    /// dots are dark, so on a dark surface they disappear and the mark reads
    /// as two empty rings.  This is the warm off-white the app icon uses, so
    /// the mark looks the same on the page as it does in the Dock.
    public static let lightGround = Color(red: 0.961, green: 0.953, blue: 0.937)
}
