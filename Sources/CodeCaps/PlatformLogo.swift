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

    public static let resolved: Bundle? = {
        if let found = resolve(in: searchRoots) { return found }
        guard mayUseGeneratedAccessor(appBundleURL: Bundle.main.bundleURL) else { return nil }
        return Bundle.module
    }()
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

/// Displays the provider mark bundled with the menu bar application.
///
/// The provider key is the canonical key used by QuotaCore.  Unknown keys
/// deliberately use a neutral SF Symbol instead of guessing at a brand.
public struct PlatformLogo: View {
    public let providerKey: String
    public let size: CGFloat
    public let style: MarkStyle
    public let tint: Color?

    public init(providerKey: String,
                size: CGFloat = 22,
                style: MarkStyle = .template,
                tint: Color? = nil) {
        self.providerKey = providerKey
        self.size = size
        self.style = style
        self.tint = tint
    }

    /// A mark that is one colour by design renders as a template in every
    /// style, so it follows Light and Dark instead of drawing black on black.
    private var rendersAsTemplate: Bool {
        style != .standard || PlatformLogoImage.isMonochromeMark(providerKey)
    }

    public var body: some View {
        Group {
            if let image = PlatformLogoImage.load(providerKey: providerKey, style: style) {
                Image(nsImage: image)
                    .renderingMode(rendersAsTemplate ? .template : .original)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .foregroundStyle(tint ?? Theme.ink)
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
        "minimax": ("minimax", "svg"),
        "cursor": ("cursor", "svg"),
    ]

    /// Return the bundled asset for `providerKey`, or `nil` if no artwork ships.
    /// The standard cache preserves brand colors; the template cache marks the
    /// image as a template so it adapts to Light/Dark and menu bar selection.
    private static func bundledImage(providerKey: String, style: MarkStyle = .template) -> NSImage? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() as NSString
        let cache = (style == .standard) ? standardCache : templateCache
        if let cached = cache.object(forKey: key) { return cached }
        guard let bundle = ResourceBundle.resolved,
              let resource = resourceNames[key as String] ?? resourceNames[platformKey(of: key as String)],
              let url = bundle.url(forResource: resource.name, withExtension: resource.ext)
                  ?? bundle.url(
                      forResource: resource.name,
                      withExtension: resource.ext,
                      subdirectory: "ProviderMarks"
                  ),
              let image = NSImage(contentsOf: url) else {
            return nil
        }
        // Keep the brand color cached separately from the template copy.
        let colorCopy = NSImage(contentsOf: url)
        // A monochrome mark adapts to Light and Dark mode across all styles.
        colorCopy?.isTemplate = isMonochromeMark(key as String)
        standardCache.setObject(colorCopy ?? image, forKey: key)
        let templateCopy = NSImage(contentsOf: url)
        templateCopy?.isTemplate = true
        templateCache.setObject(templateCopy ?? image, forKey: key)
        return cache.object(forKey: key)
    }

    /// Marks that are a single colour by design: they carry no brand colour to
    /// preserve, so they always render as templates and follow the surface —
    /// near-black on Light, light grey on Dark.
    public static func isMonochromeMark(_ providerKey: String) -> Bool {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return ["grok-bot", "google-antigravity:third-party"].contains(key)
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
    public static func load(providerKey: String, style: MarkStyle) -> NSImage? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch style {
        case .standard:
            return bundledImage(providerKey: key, style: .standard)
        case .template:
            return bundledImage(providerKey: key, style: .template)
        case .custom:
            if let custom = loadCustom(providerKey: key) ?? loadCustom(providerKey: platformKey(of: key)) {
                return custom
            }
            return bundledImage(providerKey: key, style: .standard)
        }
    }

    /// The on-disk path for a provider's custom mark, or `nil` if none has been
    /// chosen yet.  Exposed so Settings can show the path and offer Remove.
    public static func customMarkURL(providerKey: String) -> URL? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for ext in ["svg", "png", "pdf"] {
            let url = customMarksDirectory.appendingPathComponent("\(key).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Copy `source` into `customMarksDirectory` as `<key>.<ext>`, removing any
    /// older variant first so an owner swapping a PNG for an SVG never ends up
    /// with two files and the wrong one cached.  Returns the new on-disk URL,
    /// or `nil` if the source could not be read.
    @discardableResult
    public static func importCustomMark(from source: URL, providerKey: String) -> URL? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = source.pathExtension.lowercased()
        guard ["svg", "png", "pdf"].contains(ext) else { return nil }
        guard let data = try? Data(contentsOf: source) else { return nil }
        // Drop any older variant (PNG/SVG/PDF) so the menu bar never caches the
        // wrong one.
        for old in ["svg", "png", "pdf"] {
            let url = customMarksDirectory.appendingPathComponent("\(key).\(old)")
            try? FileManager.default.removeItem(at: url)
        }
        let destination = customMarksDirectory.appendingPathComponent("\(key).\(ext)")
        do {
            try data.write(to: destination, options: [.atomic])
        } catch {
            return nil
        }
        // Bust the menu-bar render cache so the new file shows on the next draw.
        for style in MarkStyle.allCases {
            menuBarCache.removeObject(forKey: "\(key)|\(style.rawValue)" as NSString)
        }
        return destination
    }

    /// Remove the custom mark for `providerKey`, if any.
    public static func removeCustomMark(providerKey: String) {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for ext in ["svg", "png", "pdf"] {
            let url = customMarksDirectory.appendingPathComponent("\(key).\(ext)")
            try? FileManager.default.removeItem(at: url)
        }
        for style in MarkStyle.allCases {
            menuBarCache.removeObject(forKey: "\(key)|\(style.rawValue)" as NSString)
        }
    }

    private static func loadCustom(providerKey: String) -> NSImage? {
        guard let url = customMarkURL(providerKey: providerKey) else { return nil }
        return NSImage(contentsOf: url)
    }

    public static func menuBarImage(providerKey: String, size: CGFloat = 16, style: MarkStyle = .template) -> NSImage? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cacheKey = "\(key)|\(style.rawValue)" as NSString
        if let cached = menuBarCache.object(forKey: cacheKey) { return cached }
        guard let original = load(providerKey: key, style: style) else {
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
        img.isTemplate = (style == .template) || isMonochromeMark(key)
        menuBarCache.setObject(img, forKey: cacheKey)
        return img
    }

    public static func fallbackSymbolName(for providerKey: String) -> String {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "anthropic", "claude": return "sparkles"
        case "openai", "codex": return "cpu"
        case "google-antigravity", "antigravity", "gemini",
             "google-antigravity:gemini", "google-antigravity:third-party": return "sparkle"
        case "xai", "grok", "grok-cli": return "bolt"
        case "grok-bot": return "bolt.badge.a"
        case "minimax": return "m.square"
        case "cursor": return "cursorarrow.rays"
        default: return "gauge.with.dots.needle.50percent"
        }
    }
}
