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
        let appContentsRes = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/\(name).bundle", isDirectory: true)
        if FileManager.default.fileExists(atPath: appContentsRes.path), let bundle = Bundle(url: appContentsRes) {
            return bundle
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
    /// Re-probe count for a mark that failed to load.  A missing mark can be
    /// transient -- the resource bundle can arrive after the first draw (an
    /// install swap, an update relaunch, a custom mark the owner imports while
    /// the panel is open) -- and SwiftUI will never re-run this body on its own
    /// while every input stays equal, so a failed first draw used to stick for
    /// the life of the view hierarchy.  Bumping this re-evaluates the body and
    /// re-runs the load until the mark lands.
    @State private var missingMarkRetry = 0
    /// Bumped when a background load fills the mark cache.  The body only
    /// reads that cache; this is what asks SwiftUI to look again.
    @State private var refreshTick = 0
    public let providerKey: String
    /// Server-supplied mark asset hint (from the manifest's `iconHint`).  When
    /// non-nil, `PlatformLogoImage` looks it up first and only falls back to
    /// the built-in `resourceNames` map when the hint does not resolve.
    public let iconHint: String?
    public let size: CGFloat
    public let style: MarkStyle
    public let customMode: CustomMarkMode?
    public let tint: Color?
    public let forceMonochrome: Bool

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
                tint: Color? = nil,
                iconHint: String? = nil,
                forceMonochrome: Bool = false) {
        self.forceMonochrome = forceMonochrome
        self.providerKey = providerKey
        self.iconHint = iconHint
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
        if forceMonochrome { return true }
        if style == .custom {
            return effectiveCustomMode == .template
        }
        if style == .template {
            return true
        }
        return PlatformLogoImage.isMonochromeMark(providerKey)
    }

    public var body: some View {
        let isDark = colorScheme == .dark
        let epoch = PlatformLogoImage.markCacheEpoch
        let catalog = PlatformLogoImage.customMarkCatalogEpoch
        let image = displayedMark(isDark: isDark)
        Group {
            if let image {
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
        .task(id: "\(providerKey)|\(iconHint ?? "")|\(style.rawValue)|\(isDark)|\(epoch)|\(catalog)|\(missingMarkRetry)") {
            // Disk work stays off the main thread.  A warm cache returns
            // without a probe; a miss loads once, then the retry interval
            // is the only thing that looks again.
            let resolved = await Self.resolveMark(providerKey: providerKey,
                                                   iconHint: iconHint,
                                                   style: style,
                                                   isDark: isDark,
                                                   refreshing: missingMarkRetry > 0)
            guard !Task.isCancelled else { return }
            if resolved {
                refreshTick += 1
                return
            }
            let delay = PlatformLogoImage.missingMarkRetryDelay(forAttempt: missingMarkRetry)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            missingMarkRetry += 1
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Memory-only.  `refreshTick` is read so a background load can publish
    /// into this row without the body touching the filesystem.
    private func displayedMark(isDark: Bool) -> NSImage? {
        _ = refreshTick
        return PlatformLogoImage.cachedImage(providerKey: providerKey,
                                              iconHint: iconHint,
                                              style: style,
                                              isDarkMode: isDark)
    }

    /// `true` when the cache holds a mark after this call.  The load itself
    /// runs on a utility queue so a ForEach update never stats from `body`.
    private static func resolveMark(providerKey: String,
                                    iconHint: String?,
                                    style: MarkStyle,
                                    isDark: Bool,
                                    refreshing: Bool) async -> Bool {
        if PlatformLogoImage.cachedImage(providerKey: providerKey,
                                          iconHint: iconHint,
                                          style: style,
                                          isDarkMode: isDark) != nil {
            return true
        }
        return await PlatformLogoImage.loadIntoCacheOffMain(providerKey: providerKey,
                                                            iconHint: iconHint,
                                                            style: style,
                                                            isDarkMode: isDark,
                                                            refreshing: refreshing)
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

    /// Provider key -> mark base name.  Every base has three shipped variants:
/// `-color` (brand colours, Standard style), `-light` (silhouette in the app's
/// Light ink) and `-dark` (silhouette in the app's Dark ink).
///
/// These used to be `name, ext` pairs pointing at SVG files with a hardcoded
/// `monochromeKeys` Set deciding which ones adapted to appearance.  Two problems
/// that measured, not assumed: the SVGs came back as `_NSSVGImageRep`, a PRIVATE
/// AppKit class, and the Muse rasters shipped a baked-in opaque white background.
/// Shipping the three variants as PNG makes appearance a property of the data
/// rather than of a guess, and puts every mark on `NSBitmapImageRep`.
private static let resourceNames: [String: String] = [
    "anthropic": "claude",
    "claude": "claude",
    "openai": "openai",
    "codex": "openai",
    "google-antigravity": "antigravity",
    "antigravity": "antigravity",
    // The two Antigravity pools are told apart by their mark as well as
    // their name: Gemini wears its star; Third-Party uses the supplied
    // Antigravity arch, with color and light/dark versions.
    "google-antigravity:gemini": "gemini-color",
    "google-antigravity:third-party": "antigravity",
    "gemini": "gemini",
    "xai": "xai",
    "x-ai": "xai",
    "grok": "grok",
    "grok-cli": "grok",
    "grok-bot": "grok-bot",
    "minimax": "minimax",
    "kimi": "kimi",
    // Z.ai is the brand; zcode remains the quota provider's stable key.
    "zcode": "zai",
    "z.ai": "zai",
    "z-ai": "zai",
    "zai": "zai",
    "muse": "muse",
    // Muse Assist ships byte-identical artwork to Muse; one base serves both.
    "muse-assist": "muse",
    "muse-code": "muse-code",
    "cursor": "cursor",
    "github-copilot": "copilot",
    "copilot": "copilot",
]

/// The file a style and appearance ask for, or `nil` when the mark is absent.
private static func variantFile(base: String, style: MarkStyle, isDark: Bool) -> String? {
    switch style {
    case .standard, .custom: return "\(base)-color.png"
    case .template: return isDark ? "\(base)-dark.png" : "\(base)-light.png"
    }
}

    /// Return the bundled asset for `providerKey`, or `nil` if no artwork ships.
    /// The standard cache preserves brand colors; the template cache marks the
    /// image as a template so it adapts to Light/Dark and menu bar selection.
    /// Guards cachedBundle and lastFailure:  preloadBundledMarks() warms the
    /// caches on a background queue while the main thread reads, and an
    /// unguarded String?/Bundle? write can tear.
    private static let stateLock = NSLock()
    private static var cachedBundle: Bundle? = nil
    /// Bumped by every invalidation.  A resolve that started before an
    /// invalidation must not pin its result afterwards, or the clear is
    /// silently undone.
    private static var bundleGeneration: UInt64 = 0
    /// Cache keys whose bundled artwork was already sought and not found.
    /// A SwiftUI update must not walk the candidate list again until a retry
    /// or an invalidation asks for a fresh probe.
    private static var missingBundledKeys = Set<String>()
    /// Candidate file URLs keyed by filename and bundle generation.  Building
    /// them with an unhinted `appendingPathComponent` stats through the
    /// sandbox, which is the CODECAPS-4 hang when a ForEach row does it.
    private static var candidateURLCache: [String: (generation: UInt64, urls: [URL])] = [:]
    /// Decoded custom marks.  The view reads this; it does not open the file.
    private static let customImageCache = NSCache<NSString, NSImage>()
    /// Keys placed in `customImageCache`.  `NSCache` cannot be enumerated, and
    /// a pool row (`platform:pool`) must be dropped when the platform mark changes.
    private static var customImageCacheKeys = Set<String>()
    /// Basename (no extension) to extension to file.  One directory listing
    /// fills it.  Row rendering only reads the snapshot.
    private static var customIndex: CustomMarkIndex?
    private static var customIndexGeneration: UInt64 = 0
    /// Bumped when the snapshot changes.  Open logo rows mix this into their
    /// task identity so a listing that lands after a fallback draw reloads.
    private static var customIndexEpoch: UInt64 = 0
    private static var customIndexBuildQueued = false
    /// How many times the custom-mark directory has been listed.  Tests use
    /// this to prove a row of lookups does not list again.
    static var customMarkDirectoryListings = 0
    /// How many times a bundled filename walked the filesystem.  A cache hit
    /// must not increment it.
    static var bundledCandidateProbes = 0
    /// Posted after the custom-mark index changes so open rows can re-read it
    /// without having listed the directory themselves.
    static let marksDidResolve = Notification.Name("CodeCapsProviderMarksDidResolve")

    /// Epoch mixed into the logo view's task identity.  Invalidation bumps
    /// `bundleGeneration`, which is what makes an open row load again.
    static var markCacheEpoch: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return bundleGeneration
    }

    /// Epoch for the custom-mark directory snapshot.  Distinct from
    /// `markCacheEpoch` so a listing does not throw away the bundled-asset pin.
    static var customMarkCatalogEpoch: UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return customIndexEpoch
    }

    /// Append a file component without asking the filesystem whether the
    /// result is a directory.  The single-argument
    /// `appendingPathComponent` calls `URLByAppendingPathComponent:`, which
    /// sandbox-checks the path.  The `isDirectory` overload does not.
    static func fileURL(appending component: String, to base: URL) -> URL {
        base.appendingPathComponent(component, isDirectory: false)
    }

    /// Append a directory component without a filesystem check.
    static func directoryURL(appending component: String, to base: URL) -> URL {
        base.appendingPathComponent(component, isDirectory: true)
    }
    /// A latch that only remembers success is a latch that can be poisoned
    /// before the bundle is reachable: the first call can land while the
    /// resource bundle is not yet resolvable, and every later call would then
    /// re-run resolution rather than serve the pinned `nil`.  Worse, a
    /// *resolved* bundle is cached without ever confirming it can produce an
    /// image, so a bundle pointing at a half-copied directory stays cached for
    /// the life of the process and every mark reads as missing.  The owner saw
    /// exactly that: only the one platform with a custom mark on disk drew
    /// anything in the PiP, which looked like a broken artwork cache but was a
    /// bundle that resolved and could not deliver.
    private static func currentBundle() -> Bundle? {
        stateLock.lock()
        if let cached = cachedBundle { stateLock.unlock(); return cached }
        let generation = bundleGeneration
        stateLock.unlock()
        //  Resolution is kept outside the lock:  it runs arbitrary bundle
        //  code and only the pin needs guarding.
        if let b = ResourceBundle.resolved ?? ResourceBundle.resolveBundle() {
            stateLock.lock()
            if generation == bundleGeneration { cachedBundle = b }
            stateLock.unlock()
            return b
        }
        return nil
    }

    /// Decode every bundled mark once, on a background queue, so the first
    /// draw of every surface finds a warm cache instead of paying per-row
    /// filesystem probes while the window is already on screen.  The custom
    /// mark directory is indexed in the same pass: a row must not list or
    /// stat it while SwiftUI is updating.
    public static func preloadBundledMarks() {
        rebuildCustomMarkIndex()
        for key in resourceNames.keys {
            for style in [MarkStyle.standard, .template] {
                for isDark in [false, true] {
                    _ = bundledImage(providerKey: key, style: style, isDark: isDark)
                }
            }
        }
        _ = BrandMarkImage.asset
    }

    /// Forget every cached bundle and mark.  Called when something changes that
    /// could have invalidated them — a custom mark import, or a resource bundle
    /// that appears after the first lookup.
    public static func invalidateCaches() {
        stateLock.lock()
        bundleGeneration &+= 1
        cachedBundle = nil
        missingBundledKeys.removeAll()
        candidateURLCache.removeAll()
        customImageCacheKeys.removeAll()
        stateLock.unlock()
        standardCache.removeAllObjects()
        templateCache.removeAllObjects()
        menuBarCache.removeAllObjects()
        customImageCache.removeAllObjects()
    }

    /// Why the last bundled lookup failed, for the log line the owner reads
    /// when a mark goes missing.  A silent nil here is what made this take days
    /// to find: there was no way to tell "no artwork for this key" from
    /// "artwork is there and the bundle could not open it".
    private static var lastFailure: String? = nil

    private static func noteFailure(_ reason: String) {
        stateLock.lock()
        guard lastFailure != reason else { stateLock.unlock(); return }
        lastFailure = reason
        stateLock.unlock()
        NSLog("CodeCaps: provider mark unavailable — %@", reason)
    }

    private static func bundledCacheIdentity(providerKey: String, iconHint: String?, style: MarkStyle, isDark: Bool) -> (key: NSString, cacheKey: NSString, cache: NSCache<NSString, NSImage>) {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() as NSString
        // Cache dimension: a manifest hint change must not keep serving the
        // previously cached mark for the same provider key, and appearance must
        // never serve a Light silhouette onto a Dark surface (or the reverse).
        let hintName = iconHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cache = (style == .standard) ? standardCache : templateCache
        // Server-first: try the manifest-supplied hint name first; fall back to
        // the built-in map when the hint does not resolve to a file, so a bad
        // hint can never blank a mark the map would have found.
        let hintBase = hintName.flatMap { name -> String? in
            guard !name.isEmpty else { return nil }
            return resourceNames[name] ?? name
        }
        let mappedBase = resourceNames[key as String] ?? resourceNames[platformKey(of: key as String)]
        // A hint that resolves to the same artwork as the built-in map shares
        // the map's cache entry, so launch preloading (which cannot know the
        // manifest's hints) still warms the first draw.
        let stem = (hintBase != nil && hintBase != mappedBase) ? "\(key)|\(hintName!)" : (key as String)
        let cacheKey = "\(stem)|v2|\(style.rawValue)|\(isDark ? "dark" : "light")" as NSString
        return (key, cacheKey, cache)
    }

    private static func bundledImage(providerKey: String, style: MarkStyle = .template, iconHint: String? = nil, isDark: Bool = false, refreshing: Bool = false) -> NSImage? {
        let identity = bundledCacheIdentity(providerKey: providerKey, iconHint: iconHint, style: style, isDark: isDark)
        let cacheKeyString = identity.cacheKey as String
        if refreshing {
            stateLock.lock()
            missingBundledKeys.remove(cacheKeyString)
            stateLock.unlock()
        } else if let cached = identity.cache.object(forKey: identity.cacheKey) {
            return cached
        } else {
            stateLock.lock()
            let missing = missingBundledKeys.contains(cacheKeyString)
            stateLock.unlock()
            if missing { return nil }
        }
        if let cached = identity.cache.object(forKey: identity.cacheKey) { return cached }
        let hintName = iconHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let hintBase = hintName.flatMap { name -> String? in
            guard !name.isEmpty else { return nil }
            return resourceNames[name] ?? name
        }
        let mappedBase = resourceNames[identity.key as String] ?? resourceNames[platformKey(of: identity.key as String)]
        var filenames: [String] = []
        for base in [hintBase, mappedBase].compactMap({ $0 }) {
            for filename in bundledFilenames(base: base, style: style, isDark: isDark) where !filenames.contains(filename) {
                filenames.append(filename)
            }
        }
        for filename in filenames {
            if let image = imageFromBundle(filename: filename, key: identity.key, cacheKey: identity.cacheKey, cache: identity.cache, refreshing: refreshing) {
                return image
            }
        }
        stateLock.lock()
        missingBundledKeys.insert(cacheKeyString)
        stateLock.unlock()
        return nil
    }
    /// A missing appearance variant should not hide a usable brand mark.
    /// Template rendering can tint the colour mark's alpha on either surface.
    static func bundledFilenames(base: String, style: MarkStyle, isDark: Bool) -> [String] {
        var names: [String] = []
        for name in [variantFile(base: base, style: style, isDark: isDark), "\(base)-color.png", "\(base).png"].compactMap({ $0 }) where !names.contains(name) {
            names.append(name)
        }
        return names
    }

    private static func imageFromBundle(filename: String, key: NSString, cacheKey: NSString, cache: NSCache<NSString, NSImage>, refreshing: Bool) -> NSImage? {
        // Walk EVERY candidate, decoding as we go, and take the first that
        // yields pixels.
        //
        // The previous version picked the first candidate whose *path existed*
        // and returned nil if that one would not decode — so a single stale or
        // wrong entry near the front of the list masked every good copy further
        // down.  That is the shape of a bug that survives ten "cache" fixes: it
        // is not the cache at all, it is a resolution order that gives up early.
        // Existence and decodability are now checked together, per candidate.
        stateLock.lock()
        bundledCandidateProbes += 1
        stateLock.unlock()
        let urls = candidateURLs(filename: filename, refreshing: refreshing)
        for candidate in urls {
            guard FileManager.default.fileExists(atPath: candidate.path) else { continue }
            guard let image = NSImage(contentsOf: candidate) ?? NSImage(contentsOfFile: candidate.path) else {
                noteFailure("'\(filename)' exists at \(candidate.path) but would not decode; trying the next location")
                continue
            }
            return finalize(image: image, url: candidate, key: key,
                            cacheKey: cacheKey, cache: cache)
        }
        noteFailure("'\(filename)' is mapped for '\(key as String)' but was not found in any of the \(urls.count) known locations")
        return nil
    }

    /// Every place the mark could legitimately live, across both the resolved
    /// bundle and `Bundle.main`.  The list is cached for the current bundle
    /// generation.  A retry passes `refreshing` so a bundle that appears
    /// later is still found.  Paths are built with an explicit directory
    /// hint so constructing the list does not sandbox-check each component.
    private static func candidateURLs(filename: String, refreshing: Bool) -> [URL] {
        stateLock.lock()
        let generation = bundleGeneration
        if !refreshing, let cached = candidateURLCache[filename], cached.generation == generation {
            stateLock.unlock()
            return cached.urls
        }
        stateLock.unlock()
        let urls = makeCandidateURLs(filename: filename)
        stateLock.lock()
        if bundleGeneration == generation {
            candidateURLCache[filename] = (generation, urls)
        }
        stateLock.unlock()
        return urls
    }

    private static func makeCandidateURLs(filename: String) -> [URL] {
        var urls: [URL] = []
        let bundled = directoryURL(appending: "Contents/Resources/CodeCaps_CodeCaps.bundle", to: Bundle.main.bundleURL)
        let bundles = [currentBundle(), Bundle(url: bundled)]
        for bundle in bundles.compactMap({ $0 }) {
            let name = (filename as NSString).deletingPathExtension
            let ext = (filename as NSString).pathExtension
            if let u = bundle.url(forResource: name, withExtension: ext) { urls.append(u) }
            if let u = bundle.url(forResource: name, withExtension: ext, subdirectory: "ProviderMarks") { urls.append(u) }
            if let base = bundle.resourceURL { urls.append(fileURL(appending: filename, to: base)) }
            urls.append(fileURL(appending: "Contents/Resources/\(filename)", to: bundle.bundleURL))
            urls.append(fileURL(appending: filename, to: bundle.bundleURL))
        }
        if let res = Bundle.main.resourceURL {
            urls.append(fileURL(appending: "CodeCaps_CodeCaps.bundle/Contents/Resources/\(filename)", to: res))
            urls.append(fileURL(appending: "CodeCaps_CodeCaps.bundle/\(filename)", to: res))
            urls.append(fileURL(appending: filename, to: res))
        }
        let main = Bundle.main.bundleURL
        urls.append(fileURL(appending: "Contents/Resources/CodeCaps_CodeCaps.bundle/Contents/Resources/\(filename)", to: main))
        urls.append(fileURL(appending: "Contents/Resources/CodeCaps_CodeCaps.bundle/\(filename)", to: main))
        urls.append(fileURL(appending: "Contents/Resources/\(filename)", to: main))

        // De-duplicate while preserving order, so the common case (the first
        // candidate hits) does the least work.
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    private static func finalize(image: NSImage, url: URL, key: NSString,
                                  cacheKey: NSString, cache: NSCache<NSString, NSImage>) -> NSImage? {
        // Keep the brand-colour copy and the template copy separate: a
        // monochrome mark adapts to Light and Dark, a colour one does not.
        let colorCopy = NSImage(contentsOf: url) ?? NSImage(contentsOfFile: url.path)
        colorCopy?.isTemplate = isMonochromeMark(key as String)
        standardCache.setObject(colorCopy ?? image, forKey: cacheKey)
        let templateCopy = NSImage(contentsOf: url) ?? NSImage(contentsOfFile: url.path)
        templateCopy?.isTemplate = true
        templateCache.setObject(templateCopy ?? image, forKey: cacheKey)
        return cache.object(forKey: cacheKey)
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
        // Pool-scoped keys ("github-copilot:premium") classify by platform,
        // matching the artwork lookup below.
        return monochromeKeys.contains(key) || monochromeKeys.contains(platformKey(of: key))
    }

    /// Marks that must always render in brand colour (orange Claude starburst,
    /// colour Gemini star, etc.), never as a black template silhouette.
    public static func requiresBrandColorMark(_ providerKey: String) -> Bool {
        let key = platformKey(of: providerKey)
        return key == "anthropic" || key == "claude"
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
        "grok-bot", "openai", "codex", "cursor", "xai", "x-ai", "grok", "grok-cli",
        "github-copilot", "copilot",
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
    ///
    /// `iconHint` is the manifest-supplied asset name (Phase 2 backend).  When
    /// present, `load` tries the hint first and falls back to the legacy
    /// `resourceNames` map; when absent, behaviour is unchanged from Phase 1.
    public static func load(providerKey: String, iconHint: String? = nil, style: MarkStyle, isDarkMode: Bool = false, refreshing: Bool = false) -> NSImage? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch style {
        case .standard:
            return bundledImage(providerKey: key, style: .standard, iconHint: iconHint, isDark: isDarkMode, refreshing: refreshing)
        case .template:
            return bundledImage(providerKey: key, style: .template, iconHint: iconHint, isDark: isDarkMode, refreshing: refreshing)
        case .custom:
            if refreshing { rebuildCustomMarkIndex() }
            let generation = currentCacheGeneration()
            if let custom = loadCustom(providerKey: key, iconHint: iconHint, isDarkMode: isDarkMode, startedAt: generation)
                ?? loadCustom(providerKey: platformKey(of: key), iconHint: iconHint, isDarkMode: isDarkMode, startedAt: generation) {
                return custom
            }
            // No custom file in the snapshot: fall back to the bundled colour
            // mark so the row still shows something real.  Stash that fallback
            // only once the snapshot exists, and under a key that includes the
            // manifest hint, so an earlier "index not ready" answer cannot
            // stick and a hint change cannot keep the previous artwork.
            let bundled = bundledImage(providerKey: key, style: .standard, iconHint: iconHint, isDark: isDarkMode, refreshing: refreshing)
            // A generation mismatch means an import cleared the cache while
            // this decode was in flight.  Keep the bitmap for this caller.
            // The cache write is refused, and the row treats success as
            // "cachedImage hit", so the rejected write still retries.
            guard peekCustomIndex() != nil else { return bundled }
            if let bundled {
                _ = rememberCustomImage(bundled, providerKey: key, iconHint: iconHint, isDarkMode: isDarkMode, startedAt: generation)
            }
            return bundled
        }
    }

    /// Memory-only read of a mark `load` has already decoded.  SwiftUI rows
    /// call this from `body`.  A miss returns nil and does not touch disk.
    public static func cachedImage(providerKey: String, iconHint: String? = nil, style: MarkStyle, isDarkMode: Bool = false) -> NSImage? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch style {
        case .standard:
            return cachedBundled(providerKey: key, iconHint: iconHint, style: .standard, isDark: isDarkMode)
        case .template:
            return cachedBundled(providerKey: key, iconHint: iconHint, style: .template, isDark: isDarkMode)
        case .custom:
            // Only an image `load` stored for this style.  A warm bundled
            // cache must not masquerade as the custom mark and skip the load.
            return cachedCustom(providerKey: key, iconHint: iconHint, isDarkMode: isDarkMode)
                ?? cachedCustom(providerKey: platformKey(of: key), iconHint: iconHint, isDarkMode: isDarkMode)
        }
    }

    /// Decode into the caches from a utility queue.  Returns whether a mark
    /// is now cached.  The image itself stays in the cache so it is not sent
    /// across the continuation.
    static func loadIntoCacheOffMain(providerKey: String, iconHint: String?, style: MarkStyle, isDarkMode: Bool, refreshing: Bool) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                _ = load(providerKey: providerKey, iconHint: iconHint, style: style, isDarkMode: isDarkMode, refreshing: refreshing)
                let cached = cachedImage(providerKey: providerKey, iconHint: iconHint, style: style, isDarkMode: isDarkMode) != nil
                continuation.resume(returning: cached)
            }
        }
    }

    private static func cachedBundled(providerKey: String, iconHint: String?, style: MarkStyle, isDark: Bool) -> NSImage? {
        let identity = bundledCacheIdentity(providerKey: providerKey, iconHint: iconHint, style: style, isDark: isDark)
        return identity.cache.object(forKey: identity.cacheKey)
    }

    /// Whether a user-supplied custom mark exists on disk for this provider or platform.
    /// Reads the in-memory index only.  A missing index schedules one background
    /// listing and reports false until that listing lands.
    public static func hasCustomMark(providerKey: String) -> Bool {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let plat = platformKey(of: key)
        guard let index = peekCustomIndex() else {
            scheduleCustomIndexBuild()
            return false
        }
        return index.url(base: key) != nil
            || index.url(base: "\(key)-dark") != nil
            || index.url(base: plat) != nil
            || index.url(base: "\(plat)-dark") != nil
    }

    /// The on-disk path for a provider's primary custom mark, or `nil` if none
    /// has been chosen yet.  Builds the index on the caller when it is still
    /// empty, which is the import, export, and test path.  Rows use
    /// `cachedCustomPrimaryMarkURL` instead.
    public static func customPrimaryMarkURL(providerKey: String) -> URL? {
        guard let index = indexForLookup(allowingDisk: true, refreshing: false) else { return nil }
        return primaryMarkURL(providerKey: providerKey, index: index)
    }

    /// The on-disk path for a provider's dark-mode custom mark, or `nil` if none
    /// has been imported yet.
    public static func customDarkMarkURL(providerKey: String) -> URL? {
        guard let index = indexForLookup(allowingDisk: true, refreshing: false) else { return nil }
        return darkMarkURL(providerKey: providerKey, index: index)
    }

    /// Memory-only primary lookup.  Schedules a background listing when the
    /// index has not been built yet and returns nil until it has.
    static func cachedCustomPrimaryMarkURL(providerKey: String) -> URL? {
        guard let index = peekCustomIndex() else {
            scheduleCustomIndexBuild()
            return nil
        }
        return primaryMarkURL(providerKey: providerKey, index: index)
    }

    /// Memory-only dark-variant lookup.  Same contract as
    /// `cachedCustomPrimaryMarkURL`.
    static func cachedCustomDarkMarkURL(providerKey: String) -> URL? {
        guard let index = peekCustomIndex() else {
            scheduleCustomIndexBuild()
            return nil
        }
        return darkMarkURL(providerKey: providerKey, index: index)
    }

    /// Whether a stored custom-mark path is in the current directory snapshot.
    /// `.unknown` means the snapshot has not been built yet, so the caller
    /// can keep trusting the path it already saved.
    static func storedCustomMarkPresence(atPath path: String) -> CustomMarkPresence {
        guard let index = peekCustomIndex() else {
            scheduleCustomIndexBuild()
            return .unknown
        }
        return index.contains(path: path) ? .present : .absent
    }

    /// The on-disk path for a provider's custom mark, or `nil` if none has been
    /// chosen yet.  Checks for a dark variant (`<key>-dark.<ext>`) first when
    /// `isDarkMode` is true, falling back to the primary custom file.
    public static func customMarkURL(providerKey: String, isDarkMode: Bool = false, refreshing: Bool = false) -> URL? {
        guard let index = indexForLookup(allowingDisk: true, refreshing: refreshing) else { return nil }
        if isDarkMode, let dark = darkMarkURL(providerKey: providerKey, index: index) {
            return dark
        }
        return primaryMarkURL(providerKey: providerKey, index: index)
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
            let url = fileURL(appending: "\(baseName).\(old)", to: customMarksDirectory)
            try? FileManager.default.removeItem(at: url)
        }
        let destination = fileURL(appending: "\(baseName).\(ext)", to: customMarksDirectory)
        do {
            try data.write(to: destination, options: [.atomic])
        } catch {
            return nil
        }
        invalidateCache(for: key)
        if peekCustomIndex() == nil {
            // The snapshot has not been built yet.  One listing here sees the
            // file just written plus every other mark.  A warm snapshot is
            // updated in place below and does not list.
            rebuildCustomMarkIndex()
        } else {
            noteCustomMarkFiles(removedBases: [baseName], added: (base: baseName, ext: ext, url: destination))
        }
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
                let url = fileURL(appending: "\(name).\(ext)", to: customMarksDirectory)
                try? FileManager.default.removeItem(at: url)
            }
        }
        invalidateCache(for: key)
        if peekCustomIndex() == nil {
            scheduleCustomIndexBuild()
        } else {
            noteCustomMarkFiles(removedBases: namesToRemove, added: nil)
        }
    }

    /// Bust the render cache so marks reload on the next draw.
    public static func invalidateCache(for providerKey: String) {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // A custom-mark import is proof that the marks directory changed, so the
        // pinned bundle gets re-resolved too: it may have been resolved before
        // the bundle existed, and that stale pin is what leaves every bundled
        // mark drawing as a fallback for the rest of the process.
        stateLock.lock()
        bundleGeneration &+= 1
        cachedBundle = nil
        missingBundledKeys = missingBundledKeys.filter { !bundledMissMatches($0, providerKey: key) }
        let customKeys = customImageCacheKeys.filter { customCacheKeyMatches($0, providerKey: key) }
        customImageCacheKeys.subtract(customKeys)
        for cacheKey in customKeys {
            customImageCache.removeObject(forKey: cacheKey as NSString)
        }
        candidateURLCache.removeAll()
        stateLock.unlock()
        standardCache.removeObject(forKey: key as NSString)
        templateCache.removeObject(forKey: key as NSString)
        for style in MarkStyle.allCases {
            menuBarCache.removeObject(forKey: "\(key)|\(style.rawValue)" as NSString)
            menuBarCache.removeObject(forKey: "\(key)|\(style.rawValue)|dark" as NSString)
            menuBarCache.removeObject(forKey: "\(key)|\(style.rawValue)|light" as NSString)
        }
    }

    private static func customImageCacheKey(providerKey: String, isDarkMode: Bool, iconHint: String?) -> NSString {
        let hint = iconHint?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return "\(providerKey)|\(hint)|\(isDarkMode ? "dark" : "light")" as NSString
    }

    private static func cachedCustom(providerKey: String, iconHint: String?, isDarkMode: Bool) -> NSImage? {
        customImageCache.object(forKey: customImageCacheKey(providerKey: providerKey, isDarkMode: isDarkMode, iconHint: iconHint))
    }

    /// Decode a custom file from the in-memory snapshot.  A missing snapshot
    /// schedules one background listing and returns nil.  It does not list
    /// the directory on the caller, which is the menu-bar path.
    private static func loadCustom(providerKey: String, iconHint: String?, isDarkMode: Bool, startedAt generation: UInt64) -> NSImage? {
        let cacheKey = customImageCacheKey(providerKey: providerKey, isDarkMode: isDarkMode, iconHint: iconHint)
        if let cached = customImageCache.object(forKey: cacheKey) { return cached }
        guard let url = memoryCustomMarkURL(providerKey: providerKey, isDarkMode: isDarkMode) else { return nil }
        guard let image = NSImage(contentsOf: url) else { return nil }
        let mode = customMarkMode(for: providerKey)
        image.isTemplate = (mode == .template)
        guard rememberCustomImage(image, providerKey: providerKey, iconHint: iconHint, isDarkMode: isDarkMode, startedAt: generation) else {
            return nil
        }
        return image
    }

    private static func memoryCustomMarkURL(providerKey: String, isDarkMode: Bool) -> URL? {
        guard let index = peekCustomIndex() else {
            scheduleCustomIndexBuild()
            return nil
        }
        if isDarkMode, let dark = darkMarkURL(providerKey: providerKey, index: index) {
            return dark
        }
        return primaryMarkURL(providerKey: providerKey, index: index)
    }

    private static func currentCacheGeneration() -> UInt64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return bundleGeneration
    }

    /// Keep a custom-mark bitmap only when `startedAt` is still the cache
    /// generation.  An import that lands mid-decode must not have its clear
    /// undone by the late store.
    @discardableResult
    private static func rememberCustomImage(_ image: NSImage, providerKey: String, iconHint: String?, isDarkMode: Bool, startedAt generation: UInt64) -> Bool {
        let cacheKey = customImageCacheKey(providerKey: providerKey, isDarkMode: isDarkMode, iconHint: iconHint)
        stateLock.lock()
        guard generation == bundleGeneration else {
            stateLock.unlock()
            return false
        }
        customImageCache.setObject(image, forKey: cacheKey)
        customImageCacheKeys.insert(cacheKey as String)
        stateLock.unlock()
        return true
    }

    /// A pool row's cache key is `platform:pool|<hint>|light`.  Invalidating
    /// `platform` has to drop that row, every hint, and the platform key itself.
    private static func customCacheKeyMatches(_ cacheKey: String, providerKey: String) -> Bool {
        let parts = cacheKey.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 2 else { return false }
        let appearance = String(parts[parts.count - 1])
        guard appearance == "light" || appearance == "dark" else { return false }
        let base = String(parts[0])
        return base == providerKey || base.hasPrefix(providerKey + ":")
    }

    /// Bundled-miss keys look like `provider|v2|style|appearance` or
    /// `provider:pool|hint|v2|style|appearance`.  The stem is the first component.
    private static func bundledMissMatches(_ cacheKey: String, providerKey: String) -> Bool {
        guard let stem = cacheKey.split(separator: "|", maxSplits: 1).first else { return false }
        let base = String(stem)
        return base == providerKey || base.hasPrefix(providerKey + ":")
    }

    /// Test seam: put a bitmap where a pool row's custom fallback would sit.
    static func cacheCustomImageForTesting(_ image: NSImage, providerKey: String, isDarkMode: Bool, iconHint: String? = nil) {
        rememberCustomImage(image, providerKey: providerKey, iconHint: iconHint, isDarkMode: isDarkMode, startedAt: currentCacheGeneration())
    }

    /// Drop the snapshot so a test can prove a cold load does not list.
    static func discardCustomIndexForTesting() {
        stateLock.lock()
        customIndex = nil
        customIndexBuildQueued = true
        stateLock.unlock()
    }

    static func allowCustomIndexBuildsForTesting() {
        stateLock.lock()
        customIndexBuildQueued = false
        stateLock.unlock()
    }

    /// Result of asking the in-memory custom-mark snapshot about a stored path.
    enum CustomMarkPresence {
        case unknown
        case present
        case absent
    }

    private struct CustomMarkIndex: Equatable {
        var files: [String: [String: URL]] = [:]
        var paths: Set<String> = []

        func url(base: String) -> URL? {
            guard let exts = files[base] else { return nil }
            for ext in PlatformLogoImage.customMarkExtensions {
                if let url = exts[ext] { return url }
            }
            return nil
        }

        func contains(path: String) -> Bool {
            let url = URL(fileURLWithPath: path)
            let variants = [
                url.path,
                url.standardizedFileURL.path,
                url.resolvingSymlinksInPath().path,
            ]
            for variant in variants where paths.contains(variant) {
                return true
            }
            return false
        }
    }

    private static let customMarkExtensions = ["png", "svg", "jpg", "jpeg", "pdf"]

    /// List the custom-mark directory once and publish the snapshot.  A newer
    /// rebuild that starts while this one is listing wins, so an import cannot
    /// be overwritten by a stale listing.
    static func rebuildCustomMarkIndex() {
        stateLock.lock()
        customIndexGeneration &+= 1
        let generation = customIndexGeneration
        stateLock.unlock()
        let listed = listCustomMarkFiles()
        var index = CustomMarkIndex()
        for file in listed {
            let ext = file.pathExtension.lowercased()
            guard customMarkExtensions.contains(ext) else { continue }
            let base = file.deletingPathExtension().lastPathComponent.lowercased()
            if index.files[base]?[ext] == nil {
                index.files[base, default: [:]][ext] = file
            }
            index.paths.insert(file.path)
            index.paths.insert(file.standardizedFileURL.path)
            index.paths.insert(file.resolvingSymlinksInPath().path)
        }
        commitCustomIndex(index, generation: generation, dropDecodedMarks: true)
    }

    /// Insert or remove files in a snapshot that already exists.  Used by
    /// import and remove so a button action does not list the directory.
    private static func noteCustomMarkFiles(removedBases: [String], added: (base: String, ext: String, url: URL)?) {
        stateLock.lock()
        customIndexGeneration &+= 1
        let generation = customIndexGeneration
        var index = customIndex ?? CustomMarkIndex()
        stateLock.unlock()
        for base in removedBases {
            untrack(base: base, index: &index)
        }
        if let added {
            untrack(base: added.base, index: &index)
            track(url: added.url, base: added.base, ext: added.ext, index: &index)
        }
        // invalidateCache already dropped this provider's decoded marks.
        commitCustomIndex(index, generation: generation, dropDecodedMarks: false)
    }

    private static func commitCustomIndex(_ index: CustomMarkIndex, generation: UInt64, dropDecodedMarks: Bool) {
        stateLock.lock()
        guard generation == customIndexGeneration else {
            stateLock.unlock()
            return
        }
        let changed = customIndex != index
        customIndex = index
        if changed {
            customIndexEpoch &+= 1
            if dropDecodedMarks {
                customImageCache.removeAllObjects()
                customImageCacheKeys.removeAll()
            }
        }
        stateLock.unlock()
        guard changed else { return }
        menuBarCache.removeAllObjects()
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: marksDidResolve, object: nil)
        }
    }

    private static func track(url: URL, base: String, ext: String, index: inout CustomMarkIndex) {
        index.files[base, default: [:]][ext] = url
        index.paths.insert(url.path)
        index.paths.insert(url.standardizedFileURL.path)
        index.paths.insert(url.resolvingSymlinksInPath().path)
    }

    private static func untrack(base: String, index: inout CustomMarkIndex) {
        guard let exts = index.files.removeValue(forKey: base) else { return }
        for url in exts.values {
            index.paths.remove(url.path)
            index.paths.remove(url.standardizedFileURL.path)
            index.paths.remove(url.resolvingSymlinksInPath().path)
        }
    }

    private static func listCustomMarkFiles() -> [URL] {
        stateLock.lock()
        customMarkDirectoryListings += 1
        stateLock.unlock()
        return (try? FileManager.default.contentsOfDirectory(at: customMarksDirectory,
                                                             includingPropertiesForKeys: nil)) ?? []
    }

    private static func peekCustomIndex() -> CustomMarkIndex? {
        stateLock.lock()
        let index = customIndex
        stateLock.unlock()
        return index
    }

    private static func scheduleCustomIndexBuild() {
        stateLock.lock()
        if customIndex != nil || customIndexBuildQueued {
            stateLock.unlock()
            return
        }
        customIndexBuildQueued = true
        stateLock.unlock()
        DispatchQueue.global(qos: .utility).async {
            rebuildCustomMarkIndex()
            stateLock.lock()
            customIndexBuildQueued = false
            stateLock.unlock()
        }
    }

    private static func indexForLookup(allowingDisk: Bool, refreshing: Bool) -> CustomMarkIndex? {
        if refreshing {
            rebuildCustomMarkIndex()
            return peekCustomIndex()
        }
        if let index = peekCustomIndex() { return index }
        if allowingDisk {
            rebuildCustomMarkIndex()
            return peekCustomIndex()
        }
        scheduleCustomIndexBuild()
        return nil
    }

    private static func primaryMarkURL(providerKey: String, index: CustomMarkIndex) -> URL? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = key.contains(":") ? [key, platformKey(of: key)] : [key]
        for candidate in candidates {
            if let url = index.url(base: candidate) { return url }
        }
        return nil
    }

    private static func darkMarkURL(providerKey: String, index: CustomMarkIndex) -> URL? {
        let key = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = key.contains(":") ? [key, platformKey(of: key)] : [key]
        for candidate in candidates {
            if let url = index.url(base: "\(candidate)-dark") { return url }
        }
        return nil
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
        // A custom paint made before the snapshot exists must not stick.
        // The following status update reads the snapshot.
        if style != .custom || cachedImage(providerKey: key, style: .custom, isDarkMode: isDark) != nil {
            menuBarCache.setObject(img, forKey: cacheKey)
        }
        return img
    }

    /// Obvious, uniform fallback symbol when artwork cannot be resolved.
    /// Fleet-wide rule: never use lookalike SF symbols to disguise missing marks.
    public static func fallbackSymbolName(for providerKey: String) -> String {
        "questionmark.square.dashed"
    }

    /// Delay before re-probing a mark that failed to load, by attempt number:
    /// the first three tries come fast (a bundle that lands seconds after the
    /// first draw should not leave placeholder glyphs lingering), then five
    /// seconds for the install/update window, then once a minute so a mark
    /// that appears later — a custom import, a late-mounted bundle — still
    /// heals without a relaunch.
    public static func missingMarkRetryDelay(forAttempt attempt: Int) -> UInt64 {
        if attempt < 3 { return 1_000_000_000 }
        return attempt < 12 ? 5_000_000_000 : 60_000_000_000
    }
}

/// The menu bar's own accent behaviour, kept apart from the mark loader.
///
/// Owner report 2026-10-06: switching the accent from green to maroon changed
/// the settings button and nothing else — the menu bar stayed grey.  The cause
/// was not a missing code path but `isTemplate`: macOS discards a template
/// image's pixels and repaints it in the menu bar's own tint, so the accent
/// could never arrive no matter what colour was selected.
///
/// That template behaviour is *correct* for a monochrome mark — it is what makes
/// one asset legible on both a light and a dark menu bar — so it stays the
/// default.  What is new is the option to paint a colour mark in the accent
/// instead, which is what "Colour" menu-bar style has always implied and never
/// delivered.
public enum MenuBarAccent {
    /// Whether a colour mark in the menu bar should wear the app accent.
    /// Defaults on: the owner's expectation is that choosing an accent changes
    /// the accent-coloured things, and the menu bar is the most visible one.
    public static var isEnabled: Bool {
        get {
            // Absent means the pre-existing default, so an installed app that
            // never had this key behaves as it did before.
            UserDefaults.standard.object(forKey: "menuBarAccentTint") as? Bool ?? true
        }
        set { UserDefaults.standard.set(newValue, forKey: "menuBarAccentTint") }
    }

    /// Draw `image`'s silhouette in the accent colour.
    ///
    /// Returns nil when there is nothing to tint, so the caller keeps the
    /// original rather than dropping the mark.  Deliberately *not* a template
    /// image afterwards: a template is what swallowed the accent in the first
    /// place.
    public static func tinted(_ image: NSImage?, isDark: Bool) -> NSImage? {
        guard let image else { return nil }
        let choice = AccentChoice.current
        let tint = NSColor(codecapsHex: isDark ? choice.darkHex : choice.lightHex)

        let size = image.size
        let out = NSImage(size: size)
        out.lockFocus()
        // The mark first, as a mask.
        image.draw(in: NSRect(origin: .zero, size: size),
                   from: .zero, operation: .sourceOver, fraction: 1.0)
        // Then the accent through that mask only, so the silhouette survives and
        // the transparent background stays transparent.
        tint.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        out.unlockFocus()
        out.isTemplate = false
        return out
    }
}

extension NSColor {
    /// Builds a colour from the `0xRRGGBB` values the accent table stores.
    convenience init(codecapsHex value: UInt32) {
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green: CGFloat((value >> 8) & 0xFF) / 255,
                  blue: CGFloat(value & 0xFF) / 255,
                  alpha: 1)
    }
}
