import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Theme color tokens for the CodeCaps companion app, matching the macOS `Theme` palette.
public enum CompanionTheme {
    /// Creates an appearance-sensitive dynamic Color from light and dark 0xRRGGBB hex values.
    public static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        return Color(uiColor: UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(
                    red: CGFloat((dark >> 16) & 0xFF) / 255.0,
                    green: CGFloat((dark >> 8) & 0xFF) / 255.0,
                    blue: CGFloat(dark & 0xFF) / 255.0,
                    alpha: 1.0
                )
                : UIColor(
                    red: CGFloat((light >> 16) & 0xFF) / 255.0,
                    green: CGFloat((light >> 8) & 0xFF) / 255.0,
                    blue: CGFloat(light & 0xFF) / 255.0,
                    alpha: 1.0
                )
        })
        #elseif canImport(AppKit)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(
                    srgbRed: CGFloat((dark >> 16) & 0xFF) / 255.0,
                    green: CGFloat((dark >> 8) & 0xFF) / 255.0,
                    blue: CGFloat(dark & 0xFF) / 255.0,
                    alpha: 1.0
                )
                : NSColor(
                    srgbRed: CGFloat((light >> 16) & 0xFF) / 255.0,
                    green: CGFloat((light >> 8) & 0xFF) / 255.0,
                    blue: CGFloat(light & 0xFF) / 255.0,
                    alpha: 1.0
                )
        })
        #endif
    }

    /// Primary accent token (default teal: 0x087370 light, 0x4FD1C5 dark).
    public static let accent = dynamic(light: 0x087370, dark: 0x4FD1C5)

    /// Warning token for near-cap quotas (0xA85C05 light, 0xF0B45A dark).
    public static let warning = dynamic(light: 0xA85C05, dark: 0xF0B45A)

    /// Danger token for exhausted quotas (0xBF3339 light, 0xFF6B6B dark).
    public static let danger = dynamic(light: 0xBF3339, dark: 0xFF6B6B)

    /// Segment colors for quota bars mirroring macOS Theme.
    public static let barUsed = danger
    public static let barRemaining = accent
}
