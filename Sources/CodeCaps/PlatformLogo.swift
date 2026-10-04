import AppKit
import SwiftUI

/// Locates the SwiftPM resource bundle without tripping `Bundle.module`'s trap.
///
/// The generated accessor (see
/// `.build/*/CodeCaps.build/DerivedSources/resource_bundle_accessor.swift`) probes
/// exactly two paths: the app bundle root and the absolute `.build` directory
/// that compiled the target.  When neither exists it calls `fatalError`, so a
/// menu bar app that is merely missing a brand mark dies on the first draw --
/// during `applicationDidFinishLaunching`, which is what "it quits as soon as I
/// open it" turns out to be.  Resolving the same locations by hand keeps a
/// missing mark cosmetic, because `PlatformLogo` falls back to an SF Symbol.
public enum ResourceBundle {
    /// The name SwiftPM gives the generated bundle for the `CodeCaps` target.
    public static let name = "CodeCaps_CodeCaps"

    /// Every directory worth probing, nearest first.
    ///
    /// The upward hops matter for a `swift test` run, where the module bundle is
    /// a sibling of the test bundle rather than a child of it.  Three levels
    /// covers `Contents/MacOS`, `Contents`, and the package bin directory an
    /// xctest bundle executes from.
    public static var searchRoots: [URL] {
        var roots: [URL] = [Bundle.main.bundleURL]
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        if let executable = Bundle.main.executableURL?.deletingLastPathComponent() {
            roots.append(executable)
        }
        var parents: [URL] = []
        for root in roots {
            var dir = root
            for _ in 0..<3 {
                dir = dir.deletingLastPathComponent()
                parents.append(dir)
            }
        }
        roots.append(contentsOf: parents)
        var unique: [URL] = []
        for root in roots where !unique.contains(root) { unique.append(root) }
        return unique
    }

    /// The first root in `roots` that actually holds the resource bundle, or
    /// `nil` when none does.  Never traps, which is the whole point.
    public static func resolve(in roots: [URL]) -> Bundle? {
        let target = "\(name).bundle"
        for root in roots {
            let candidate = root.appendingPathComponent(target, isDirectory: true)
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            if let bundle = Bundle(path: candidate.path) { return bundle }
        }
        return nil
    }

    /// Whether the generated `Bundle.module` accessor is safe to reach for.
    ///
    /// Its second candidate is the absolute `.build` directory that compiled the
    /// target, and that directory is alive whenever the code is run as a bare
    /// executable from `.build` or as an XCTest bundle -- which is not something
    /// `Bundle.main` can tell you, because under `swift test` the main bundle is
    /// Xcode's own `xctest` tool.  An installed `.app` is the one case where the
    /// build directory is gone, so reaching for the accessor there is the trap
    /// itself and the app is expected to have shipped the bundle.
    public static func mayUseGeneratedAccessor(appBundleURL: URL) -> Bool {
        appBundleURL.pathExtension.lowercased() != "app"
    }

    public static func resolveBundle() -> Bundle? {
        if let mainBundleURL = Bundle.main.url(forResource: name, withExtension: "bundle"),
           let bundle = Bundle(url: mainBundleURL) {
            return bundle
        }
        if let resURL = Bundle.main.resourceURL {
            let direct = resURL.appendingPathComponent("\(name).bundle", isDirectory: true)
            if FileManager.default.fileExists(atPath: direct.path), let bundle = Bundle(url: direct) {
                return bundle
            }
        }
        if let found = resolve(in: searchRoots) { return found }
        guard mayUseGeneratedAccessor(appBundleURL: Bundle.main.bundleURL) else { return nil }
        return Bundle.module
    }

    public static let resolved: Bundle? = resolveBundle()
}

/// How a provider's brand mark should be drawn.
///
/// - `standard` keeps the mark's own brand colors (orange for OpenAI, blue for
///   Cursor, etc.).  Reads loudest on the menu bar, and is what every other
///   consumer of these icons ships by default.
/// - `template` keeps only the silhouette; the foreground color takes over, so
///   the same image is legible on Light and Dark surfaces and against any
///   menu bar tint.
/// - `custom` shows a user-supplied image (PNG, SVG, or PDF) chosen from
///   Settings → Platforms → ⋯ → Logo Style → Custom.
public enum MarkStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case standard
    case template
    case custom

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .standard:  return "Standard"
        case .template:  return "Light/Dark"
        case .custom:   return "Custom"
        }
    }
}

/// Presentation mode for a user-supplied custom logo.
public enum CustomMarkMode: String, CaseIterable, Identifiable, Codable, Sendable {
    case color
    case template

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .color:    return "Color Version"
        case .template: return "Light/Dark Version"
        }
    }
}

/// Displays the provider mark bundled with the menu bar application.
///
/// The provider key is the canonical key used by QuotaCore.  Unknown keys
/// deliberately use a neutral SF Symbol instead of guessing at a brand.
public struct PlatformLogo: View {
    @Environment(\.colorScheme) private var colorScheme
    public let providerKey: String
    public let size: CGFloat
    public let style: MarkStyle
    public let customMode: CustomMarkMode?
    public let tint: Color?

    /// `style` deliberately has **no default**.  A call site that forgets it
    /// used to compile and silently draw a monochrome template — which is how
    /// the Sources & Fleet list showed every mark in grey while the Logo Style
    /// page, using the same provider, showed the brand colour.  Every surface
    /// now has to say which style it means, and the compiler finds the ones
    /// that do not.
    public init(providerKey: String,
                size: CGFloat = 22,
                style: MarkStyle,
                customMode: CustomMarkMode? = nil,
                tint: Color? = nil) {
        self.providerKey = providerKey
        self.size = size
        self.style = style
        self.customMode = customMode
        self.tint = tint
    }

    private var effectiveCustomMode: CustomMarkMode {
        customMode ?? PlatformLogoImage.customMarkMode(for: providerKey)
    }

    /// A mark that is one colour by design renders as a template in every
    /// style, so it follows Light and Dark instead of drawing black on black.
    /// Custom marks honor the user's customMode preference (Color vs Template).
    private var rendersAsTemplate: Bool {
        if style == .custom {
            return effectiveCustomMode == .template
        }
        if style == .template {
            return true
        }
        return PlatformLogoImage.isMonochromeMark(providerKey)
    }

    public var body: some View {
        Group {
            let isDark = colorScheme == .dark
            if let image = PlatformLogoImage.load(providerKey: providerKey, style: style, isDarkMode: isDark) {
                if rendersAsTemplate {
                    Image(nsImage: image)
                        .renderingMode(.template)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(tint ?? (PlatformLogoImage.usesSolidTone(providerKey)
                                                  ? Theme.solidMark : Theme.ink))
                } else {
                    Image(nsImage: image)
                        .renderingMode(.original)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            } else {
                Image(systemName: PlatformLogoImage.fallbackSymbolName(for: providerKey))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

public enum PlatformLogoImage {
    /// Cached standard (full-color) marks, keyed by provider key.
    private static let standardCache = NSCache<NSString, NSImage>()
    /// Cached template (monochrome) marks, keyed by provider key.
    private static let templateCache = NSCache<NSString, NSImage>()
    /// Cached menu-bar renders, keyed by `<providerKey>|<style>`.
    private static let menuBarCache = NSCache<NSString, NSImage>()

    /// Filesystem location for user-supplied custom logos.  Created on first
    /// save so the OS shows it in Finder without a separate call.
    public static let customMarksDirectory: URL = {
        let fm = FileManager.default
        let appSupport = (try? fm.url(for: .applicationSupportDirectory,
                                      in: .userDomainMask,
                                      appropriateFor: nil,
                                      create: true)) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport
            .appendingPathComponent("CodeCaps", isDirectory: true)
            .appendingPathComponent("CustomMarks", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    private static let resourceNames: [String: (name: String, ext: String)] = [
        "anthropic": ("claude", "svg"),
        "claude": ("claude", "svg"),
        "openai": ("openai", "svg"),
        "codex": ("openai", "svg"),
        "google-antigravity": ("gemini", "svg"),
        "antigravity": ("gemini", "svg"),
        // The two Antigravity pools are told apart by their mark as well as
        // their name: the Gemini pool wears the colour Gemini star, and the
        // Third-Party pool the same star as a solid one-colour glyph.
        "google-antigravity:gemini": ("gemini-color", "png"),
        "google-antigravity:third-party": ("gemini-mono", "svg"),
        "gemini": ("gemini", "svg"),
        "xai": ("grok", "svg"),
        "grok": ("grok", "svg"),
        "grok-cli": ("grok", "svg"),
        "grok-bot": ("grok-bot", "svg"),
        "minimax": ("minimax", "png"),
        "muse": ("muse", "svg"),
        "cursor": ("cursor", "svg"),
    ]

    /// Return the bundled asset for `providerKey`, or `nil` if no artwork ships.
    /// The standard cache preserves brand colors; the template cache marks the
    /// image as a template so it adapts to Light/Dark and menu bar selection.
    private static func currentBundle() -> Bundle? {
        ResourceBundle.resolved ?? ResourceBundle.resolveBundle()
    }

    private static func bundledImage(providerKey: String, style: MarkStyle = .template) -> NSImage? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() as NSString
        let cache = (style == .standard) ? standardCache : templateCache
        if let cached = cache.object(forKey: key) { return cached }
        guard let bundle = currentBundle(),
              let resource = resourceNames[key as String] ?? resourceNames[platformKey(of: key as String)] else {
            return nil
        }
        let candidates: [URL?] = [
            bundle.url(forResource: resource.name, withExtension: resource.ext),
            bundle.url(forResource: resource.name, withExtension: resource.ext, subdirectory: "ProviderMarks"),
            bundle.resourceURL?.appendingPathComponent("\(resource.name).\(resource.ext)"),
            bundle.bundleURL.appendingPathComponent("Contents/Resources/\(resource.name).\(resource.ext)"),
            bundle.bundleURL.appendingPathComponent("\(resource.name).\(resource.ext)")
        ]
        var targetURL: URL?
        for candidate in candidates.compactMap({ $0 }) {
            if FileManager.default.fileExists(atPath: candidate.path) {
                targetURL = candidate
                break
            }
        }
        guard let url = targetURL,
              let image = NSImage(contentsOf: url) ?? NSImage(contentsOfFile: url.path) else {
            return nil
        }
        // Keep the brand color cached separately from the template copy.
        let colorCopy = NSImage(contentsOf: url) ?? NSImage(contentsOfFile: url.path)
        // A monochrome mark adapts to Light and Dark mode across all styles.
        colorCopy?.isTemplate = isMonochromeMark(key as String)
        standardCache.setObject(colorCopy ?? image, forKey: key)
        let templateCopy = NSImage(contentsOf: url) ?? NSImage(contentsOfFile: url.path)
        templateCopy?.isTemplate = true
        templateCache.setObject(templateCopy ?? image, forKey: key)
        return cache.object(forKey: key)
    }

    /// Marks that are a single colour by design: they carry no brand colour to
    /// preserve, so they always render as templates and follow the surface —
    /// near-black on Light, light grey on Dark.
    ///
    /// OpenAI, Cursor, Grok and MiniMax ship as plain black marks, which drew
    /// near-black on the dark Glance surface until they joined this set.
    /// Claude and the colour Gemini star keep their brand colour.
    public static func isMonochromeMark(_ providerKey: String) -> Bool {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return monochromeKeys.contains(key)
    }

    /// One-colour marks that draw pure black on Light and pure white on Dark
    /// rather than in the ink's softer grey.  The Third-Party star sits beside
    /// the colour Gemini star, and a grey one read as disabled (owner delta,
    /// 2026-09-30).
    public static func usesSolidTone(_ providerKey: String) -> Bool {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return solidToneKeys.contains(key)
    }

    private static let solidToneKeys: Set<String> = ["google-antigravity:third-party"]

    private static let monochromeKeys: Set<String> = [
        "grok-bot", "google-antigravity:third-party",
        "openai", "codex", "cursor", "minimax", "xai", "grok", "grok-cli",
    ]

    /// Presentation mode for a user-supplied custom mark.  Defaults to `.color`
    /// so an uploaded brand mark keeps its original colours rather than turning
    /// into a monochrome template.
    public static func customMarkMode(for providerKey: String) -> CustomMarkMode {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let data = UserDefaults.standard.data(forKey: "customMarkModes"),
           let dict = try? JSONDecoder().decode([String: CustomMarkMode].self, from: data),
           let mode = dict[key] {
            return mode
        }
        return .color
    }

    /// Persist the presentation mode for `providerKey` and invalidate caches.
    public static func setCustomMarkMode(_ mode: CustomMarkMode, for providerKey: String) {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var dict: [String: CustomMarkMode] = [:]
        if let data = UserDefaults.standard.data(forKey: "customMarkModes"),
           let decoded = try? JSONDecoder().decode([String: CustomMarkMode].self, from: data) {
            dict = decoded
        }
        dict[key] = mode
        if let encoded = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(encoded, forKey: "customMarkModes")
        }
        invalidateCache(for: key)
    }

    /// The platform a pool-scoped key belongs to: `google-antigravity:gemini`
    /// is `google-antigravity`.  A custom mark is chosen per platform, so both
    /// pools show it.
    static func platformKey(of providerKey: String) -> String {
        providerKey.split(separator: ":", maxSplits: 1).first.map(String.init) ?? providerKey
    }

    /// Return a mark for `providerKey` honoring `style`.  Custom marks are
    /// resolved relative to `customMarksDirectory`; an unreadable file falls
    /// back to the bundled asset so a stale selection does not blank the menu
    /// bar.
    public static func load(providerKey: String, style: MarkStyle, isDarkMode: Bool = false) -> NSImage? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch style {
        case .standard:
            return bundledImage(providerKey: key, style: .standard)
        case .template:
            return bundledImage(providerKey: key, style: .template)
        case .custom:
            if let custom = loadCustom(providerKey: key, isDarkMode: isDarkMode)
                ?? loadCustom(providerKey: platformKey(of: key), isDarkMode: isDarkMode) {
                return custom
            }
            return bundledImage(providerKey: key, style: .standard)
        }
    }

    /// Whether a user-supplied custom mark exists on disk for this provider or platform.
    public static func hasCustomMark(providerKey: String) -> Bool {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let plat = platformKey(of: key)
        return customPrimaryMarkURL(providerKey: key) != nil
            || customDarkMarkURL(providerKey: key) != nil
            || customPrimaryMarkURL(providerKey: plat) != nil
            || customDarkMarkURL(providerKey: plat) != nil
    }

    /// The on-disk path for a provider's primary custom mark, or `nil` if none
    /// has been chosen yet.
    public static func customPrimaryMarkURL(providerKey: String) -> URL? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = key.contains(":") ? [key, platformKey(of: key)] : [key]
        for candidate in candidates {
            for ext in ["png", "svg", "jpg", "jpeg", "pdf"] {
                let url = customMarksDirectory.appendingPathComponent("\(candidate).\(ext)")
                if FileManager.default.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    /// The on-disk path for a provider's dark-mode custom mark, or `nil` if none
    /// has been imported yet.
    public static func customDarkMarkURL(providerKey: String) -> URL? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = key.contains(":") ? [key, platformKey(of: key)] : [key]
        for candidate in candidates {
            for ext in ["png", "svg", "jpg", "jpeg", "pdf"] {
                let darkUrl = customMarksDirectory.appendingPathComponent("\(candidate)-dark.\(ext)")
                if FileManager.default.fileExists(atPath: darkUrl.path) { return darkUrl }
            }
        }
        return nil
    }

    /// The on-disk path for a provider's custom mark, or `nil` if none has been
    /// chosen yet.  Checks for a dark variant (`<key>-dark.<ext>`) first when
    /// `isDarkMode` is true, falling back to the primary custom file.
    public static func customMarkURL(providerKey: String, isDarkMode: Bool = false) -> URL? {
        if isDarkMode, let dark = customDarkMarkURL(providerKey: providerKey) {
            return dark
        }
        return customPrimaryMarkURL(providerKey: providerKey)
    }

    /// Copy `source` into `customMarksDirectory` as `<key>.<ext>` or `<key>-dark.<ext>`,
    /// removing any older variant first so an owner swapping a PNG for an SVG never
    /// ends up with two files and the wrong one cached.  Returns the new on-disk URL,
    /// or `nil` if the source could not be read.
    @discardableResult
    public static func importCustomMark(from source: URL, providerKey: String, isDarkMode: Bool = false) -> URL? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = source.pathExtension.lowercased()
        guard ["svg", "png", "pdf"].contains(ext) else { return nil }
        guard let data = try? Data(contentsOf: source) else { return nil }
        let baseName = isDarkMode ? "\(key)-dark" : key
        for old in ["svg", "png", "pdf"] {
            let url = customMarksDirectory.appendingPathComponent("\(baseName).\(old)")
            try? FileManager.default.removeItem(at: url)
        }
        let destination = customMarksDirectory.appendingPathComponent("\(baseName).\(ext)")
        do {
            try data.write(to: destination, options: [.atomic])
        } catch {
            return nil
        }
        invalidateCache(for: key)
        return destination
    }

    /// Remove the custom mark for `providerKey`, if any.
    public static func removeCustomMark(providerKey: String, isDarkMode: Bool? = nil) {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let namesToRemove: [String]
        if let isDarkMode {
            namesToRemove = [isDarkMode ? "\(key)-dark" : key]
        } else {
            namesToRemove = [key, "\(key)-dark"]
        }
        for name in namesToRemove {
            for ext in ["svg", "png", "pdf"] {
                let url = customMarksDirectory.appendingPathComponent("\(name).\(ext)")
                try? FileManager.default.removeItem(at: url)
            }
        }
        invalidateCache(for: key)
    }

    /// Bust the render cache so marks reload on the next draw.
    public static func invalidateCache(for providerKey: String) {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        standardCache.removeObject(forKey: key as NSString)
        templateCache.removeObject(forKey: key as NSString)
        for style in MarkStyle.allCases {
            menuBarCache.removeObject(forKey: "\(key)|\(style.rawValue)" as NSString)
            menuBarCache.removeObject(forKey: "\(key)|\(style.rawValue)|dark" as NSString)
            menuBarCache.removeObject(forKey: "\(key)|\(style.rawValue)|light" as NSString)
        }
    }

    private static func loadCustom(providerKey: String, isDarkMode: Bool = false) -> NSImage? {
        guard let url = customMarkURL(providerKey: providerKey, isDarkMode: isDarkMode) else { return nil }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let mode = customMarkMode(for: providerKey)
        image.isTemplate = (mode == .template)
        return image
    }

    public static func menuBarImage(providerKey: String, size: CGFloat = 16, style: MarkStyle = .template, isDarkMode: Bool? = nil) -> NSImage? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let isDark = isDarkMode ?? (NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let cacheKey = "\(key)|\(style.rawValue)|\(isDark ? "dark" : "light")" as NSString
        if let cached = menuBarCache.object(forKey: cacheKey) { return cached }
        guard let original = load(providerKey: key, style: style, isDarkMode: isDark) else {
            return nil
        }
        let targetSize = NSSize(width: size, height: size)
        let img = NSImage(size: targetSize)
        img.lockFocus()
        original.draw(in: NSRect(origin: .zero, size: targetSize),
                      from: NSRect(origin: .zero, size: original.size),
                      operation: .copy,
                      fraction: 1.0)
        img.unlockFocus()
        if style == .custom {
            img.isTemplate = (customMarkMode(for: key) == .template)
        } else {
            img.isTemplate = (style == .template) || isMonochromeMark(key)
        }
        menuBarCache.setObject(img, forKey: cacheKey)
        return img
    }

    /// Obvious, uniform fallback symbol when artwork cannot be resolved.
    /// Fleet-wide rule: never use lookalike SF symbols to disguise missing marks.
    public static func fallbackSymbolName(for providerKey: String) -> String {
        "questionmark.square.dashed"
    }
}
