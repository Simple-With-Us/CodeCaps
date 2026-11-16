import AppKit
@testable import CodeCaps
import XCTest

/// Row rendering used to build file URLs with the unhinted
/// `appendingPathComponent`, which sandbox-checks every component, and it did
/// that from SwiftUI `body` / `ForEach`.  These tests pin the replacement:
/// explicit directory hints, one directory snapshot, and no second probe for
/// a mark that is already known.
final class MarkPathRenderingTests: XCTestCase {
    func testFileURLHintDoesNotTreatAnExistingDirectoryAsAFileCheck() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codecaps-hint-\(UUID().uuidString)", isDirectory: true)
        let directory = root.appendingPathComponent("CustomMarks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The directory exists.  A file hint must still report a non-directory
        // URL, which is only possible when the append skipped the stat that
        // the unhinted API performs.
        let file = PlatformLogoImage.fileURL(appending: "CustomMarks", to: root)
        XCTAssertFalse(file.hasDirectoryPath)
        XCTAssertEqual(file.lastPathComponent, "CustomMarks")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        let hintedDirectory = PlatformLogoImage.directoryURL(appending: "CustomMarks", to: root)
        XCTAssertTrue(hintedDirectory.hasDirectoryPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: hintedDirectory.path))
    }

    func testMissingBundledMarkIsProbedOnceUntilRefresh() {
        let key = "missing-mark-\(UUID().uuidString)"
        let hint = "not-a-real-file"
        PlatformLogoImage.invalidateCaches()
        let before = PlatformLogoImage.bundledCandidateProbes
        XCTAssertNil(PlatformLogoImage.load(providerKey: key, iconHint: hint, style: .template))
        let afterFirst = PlatformLogoImage.bundledCandidateProbes
        XCTAssertGreaterThan(afterFirst, before)
        XCTAssertNil(PlatformLogoImage.load(providerKey: key, iconHint: hint, style: .template))
        XCTAssertNil(PlatformLogoImage.cachedImage(providerKey: key, iconHint: hint, style: .template))
        XCTAssertEqual(PlatformLogoImage.bundledCandidateProbes, afterFirst,
                       "a second row update must reuse the miss instead of probing again")
        XCTAssertNil(PlatformLogoImage.load(providerKey: key, iconHint: hint, style: .template, refreshing: true))
        XCTAssertGreaterThan(PlatformLogoImage.bundledCandidateProbes, afterFirst,
                             "a scheduled retry is allowed to probe again")
    }

    func testCachedBundledMarkDoesNotProbe() {
        if PlatformLogoImage.cachedImage(providerKey: "claude", style: .standard) == nil {
            XCTAssertNotNil(PlatformLogoImage.load(providerKey: "claude", style: .standard))
        }
        if PlatformLogoImage.cachedImage(providerKey: "claude", style: .template, isDarkMode: true) == nil {
            XCTAssertNotNil(PlatformLogoImage.load(providerKey: "claude", style: .template, isDarkMode: true))
        }
        let before = PlatformLogoImage.bundledCandidateProbes
        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: "claude", style: .standard))
        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: "claude", style: .template, isDarkMode: true))
        XCTAssertEqual(PlatformLogoImage.bundledCandidateProbes, before)
    }

    func testCustomMarkLookupsReuseOneDirectorySnapshot() {
        PlatformLogoImage.rebuildCustomMarkIndex()
        let before = PlatformLogoImage.customMarkDirectoryListings
        for _ in 0..<25 {
            _ = PlatformLogoImage.hasCustomMark(providerKey: "cursor")
            _ = PlatformLogoImage.customPrimaryMarkURL(providerKey: "cursor")
            _ = PlatformLogoImage.customDarkMarkURL(providerKey: "cursor")
            _ = PlatformLogoImage.cachedCustomPrimaryMarkURL(providerKey: "cursor")
            _ = PlatformLogoImage.cachedCustomDarkMarkURL(providerKey: "cursor")
            _ = PlatformLogoImage.storedCustomMarkPresence(atPath: "/tmp/codecaps-not-a-mark.png")
        }
        XCTAssertEqual(PlatformLogoImage.customMarkDirectoryListings, before)
    }

    func testCustomMarkExtensionOrderMatchesTheOldStatLoop() throws {
        let key = "precedence-\(UUID().uuidString)"
        let directory = PlatformLogoImage.customMarksDirectory
        let png = PlatformLogoImage.fileURL(appending: "\(key).png", to: directory)
        let svg = PlatformLogoImage.fileURL(appending: "\(key).svg", to: directory)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: png)
        try Data("svg".utf8).write(to: svg)
        defer {
            try? FileManager.default.removeItem(at: png)
            try? FileManager.default.removeItem(at: svg)
            PlatformLogoImage.rebuildCustomMarkIndex()
        }

        PlatformLogoImage.rebuildCustomMarkIndex()
        let resolved = PlatformLogoImage.customPrimaryMarkURL(providerKey: key)
        XCTAssertEqual(resolved?.standardizedFileURL, png.standardizedFileURL)
        XCTAssertEqual(resolved?.pathExtension, "png")
        XCTAssertTrue(PlatformLogoImage.hasCustomMark(providerKey: key))

        let listings = PlatformLogoImage.customMarkDirectoryListings
        XCTAssertEqual(PlatformLogoImage.customPrimaryMarkURL(providerKey: key)?.pathExtension, "png")
        XCTAssertTrue(PlatformLogoImage.hasCustomMark(providerKey: key))
        XCTAssertEqual(PlatformLogoImage.customMarkDirectoryListings, listings)
    }

    func testPoolKeyCustomMarkFallsBackToThePlatformFile() throws {
        let platform = "pool-\(UUID().uuidString)"
        let directory = PlatformLogoImage.customMarksDirectory
        let file = PlatformLogoImage.fileURL(appending: "\(platform).png", to: directory)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: file)
            PlatformLogoImage.rebuildCustomMarkIndex()
        }
        PlatformLogoImage.rebuildCustomMarkIndex()

        let poolKey = "\(platform):gemini"
        XCTAssertEqual(PlatformLogoImage.customPrimaryMarkURL(providerKey: poolKey)?.standardizedFileURL,
                       file.standardizedFileURL)
        XCTAssertTrue(PlatformLogoImage.hasCustomMark(providerKey: poolKey))
        XCTAssertNil(PlatformLogoImage.customDarkMarkURL(providerKey: poolKey))
    }

    /// A pool row that already cached the bundled fallback must drop that
    /// bitmap when the platform mark is imported.  `cachedImage` checks the
    /// pool key first, so a leftover entry hides the new file.
    func testPlatformInvalidationDropsPoolScopedCustomFallbacks() {
        let platform = "cc229-\(UUID().uuidString)"
        let pool = "\(platform):gemini"
        let other = "other-\(UUID().uuidString)"
        let prefixed = "\(platform)-extra"
        let image = NSImage(size: NSSize(width: 2, height: 2))
        PlatformLogoImage.cacheCustomImageForTesting(image, providerKey: pool, isDarkMode: false)
        PlatformLogoImage.cacheCustomImageForTesting(image, providerKey: pool, isDarkMode: true)
        PlatformLogoImage.cacheCustomImageForTesting(image, providerKey: platform, isDarkMode: false)
        PlatformLogoImage.cacheCustomImageForTesting(image, providerKey: other, isDarkMode: false)
        PlatformLogoImage.cacheCustomImageForTesting(image, providerKey: prefixed, isDarkMode: false)

        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: pool, style: .custom))
        PlatformLogoImage.invalidateCache(for: platform)

        XCTAssertNil(PlatformLogoImage.cachedImage(providerKey: pool, style: .custom, isDarkMode: false))
        XCTAssertNil(PlatformLogoImage.cachedImage(providerKey: pool, style: .custom, isDarkMode: true))
        XCTAssertNil(PlatformLogoImage.cachedImage(providerKey: platform, style: .custom))
        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: other, style: .custom))
        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: prefixed, style: .custom))
    }

    /// The snapshot stores the URL `contentsOfDirectory` returned.  Rebuilding
    /// that URL from the lowercased base misses a mixed-case file on a
    /// case-sensitive volume.
    func testCustomMarkURLKeepsTheOnDiskFilenameCase() throws {
        let directory = PlatformLogoImage.customMarksDirectory
        let name = "Cc229Case-\(UUID().uuidString.prefix(8)).PNG"
        let file = directory.appendingPathComponent(name, isDirectory: false)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: file)
        defer {
            try? FileManager.default.removeItem(at: file)
            PlatformLogoImage.rebuildCustomMarkIndex()
        }
        PlatformLogoImage.rebuildCustomMarkIndex()

        let key = file.deletingPathExtension().lastPathComponent.lowercased()
        XCTAssertEqual(PlatformLogoImage.customPrimaryMarkURL(providerKey: key)?.lastPathComponent, name)
    }

    func testWarmImportDoesNotListTheMarkDirectory() throws {
        PlatformLogoImage.rebuildCustomMarkIndex()
        let before = PlatformLogoImage.customMarkDirectoryListings
        let key = "import-list-\(UUID().uuidString)"
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(key)-src.png", isDirectory: false)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            PlatformLogoImage.removeCustomMark(providerKey: key)
            PlatformLogoImage.rebuildCustomMarkIndex()
        }

        let stored = PlatformLogoImage.importCustomMark(from: source, providerKey: key)
        XCTAssertEqual(PlatformLogoImage.customMarkDirectoryListings, before)
        XCTAssertEqual(PlatformLogoImage.customPrimaryMarkURL(providerKey: key)?.standardizedFileURL,
                       stored?.standardizedFileURL)

        PlatformLogoImage.removeCustomMark(providerKey: key)
        XCTAssertEqual(PlatformLogoImage.customMarkDirectoryListings, before)
        XCTAssertNil(PlatformLogoImage.customPrimaryMarkURL(providerKey: key))
    }

    func testCustomLoadDoesNotListWhileTheIndexIsCold() {
        PlatformLogoImage.discardCustomIndexForTesting()
        defer { PlatformLogoImage.allowCustomIndexBuildsForTesting() }
        let before = PlatformLogoImage.customMarkDirectoryListings
        _ = PlatformLogoImage.load(providerKey: "cursor", style: .custom)
        XCTAssertEqual(PlatformLogoImage.customMarkDirectoryListings, before)
    }

    /// A bundled fallback stored for `.custom` is resolved with the manifest
    /// hint.  A later hint must not reuse that bitmap, and invalidating the
    /// platform still drops a hinted pool key.
    func testCustomFallbackCacheIncludesTheManifestHint() {
        let key = "hint-\(UUID().uuidString)"
        let pool = "\(key):gemini"
        let image = NSImage(size: NSSize(width: 2, height: 2))
        PlatformLogoImage.cacheCustomImageForTesting(image, providerKey: key, isDarkMode: false, iconHint: "old")
        PlatformLogoImage.cacheCustomImageForTesting(image, providerKey: pool, isDarkMode: true, iconHint: "star")

        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: key, iconHint: "old", style: .custom))
        XCTAssertNil(PlatformLogoImage.cachedImage(providerKey: key, iconHint: "new", style: .custom))

        PlatformLogoImage.invalidateCache(for: key)
        XCTAssertNil(PlatformLogoImage.cachedImage(providerKey: key, iconHint: "old", style: .custom))
        XCTAssertNil(PlatformLogoImage.cachedImage(providerKey: pool, iconHint: "star", style: .custom, isDarkMode: true))
    }

    /// The mini panel asks for a template mark on a dark fill.  The popover
    /// asks for the colour mark.  A miss on one key must not blank the other,
    /// and it must not be stored as an image the row can keep drawing.
    func testTemplateMissDoesNotBlankThePopoverMarkOrCacheThePlaceholder() {
        defer { PlatformLogoImage.invalidateCaches() }
        PlatformLogoImage.invalidateCaches()
        PlatformLogoImage.recordBundledMissForTesting(providerKey: "claude", style: .template, isDarkMode: true)
        let before = PlatformLogoImage.bundledCandidateProbes

        XCTAssertNil(PlatformLogoImage.load(providerKey: "claude", style: .template, isDarkMode: true))
        XCTAssertNil(PlatformLogoImage.cachedImage(providerKey: "claude", style: .template, isDarkMode: true))
        XCTAssertEqual(PlatformLogoImage.bundledCandidateProbes, before,
                       "the dark mini-panel key stays a miss until a catalog wave, without another probe")

        XCTAssertNotNil(PlatformLogoImage.load(providerKey: "claude", style: .standard, isDarkMode: false),
                        "the popover's colour mark uses a different cache key and must still resolve")
        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: "claude", style: .standard, isDarkMode: false))
        XCTAssertNil(PlatformLogoImage.cachedImage(providerKey: "claude", style: .template, isDarkMode: true),
                     "a colour hit must not invent a bitmap for the style that missed")
    }

    /// Preload is what runs at launch, off the main thread.  A miss a row
    /// recorded first has to be replaced, for both the panel's template key
    /// and the popover's colour key, including Antigravity's pool id.
    func testPreloadReplacesNegativeMissesForBothSurfaces() {
        defer { PlatformLogoImage.invalidateCaches() }
        PlatformLogoImage.invalidateCaches()
        let minimax = NSImage(size: NSSize(width: 2, height: 2))
        PlatformLogoImage.cacheCustomImageForTesting(minimax, providerKey: "minimax", isDarkMode: true)
        PlatformLogoImage.recordBundledMissForTesting(providerKey: "claude", style: .template, isDarkMode: true)
        PlatformLogoImage.recordBundledMissForTesting(providerKey: "cursor", style: .template, isDarkMode: true)
        PlatformLogoImage.recordBundledMissForTesting(providerKey: "google-antigravity:gemini", style: .standard, isDarkMode: false)

        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: "minimax", style: .custom, isDarkMode: true))
        XCTAssertNil(PlatformLogoImage.cachedImage(providerKey: "claude", style: .template, isDarkMode: true))
        XCTAssertNil(PlatformLogoImage.cachedImage(providerKey: "google-antigravity:gemini", style: .standard))

        PlatformLogoImage.preloadBundledMarks()

        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: "claude", style: .template, isDarkMode: true))
        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: "claude", style: .standard, isDarkMode: false))
        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: "cursor", style: .template, isDarkMode: true))
        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: "google-antigravity:gemini", style: .standard, isDarkMode: false))
        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: "google-antigravity:gemini", style: .template, isDarkMode: true))
        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: "minimax", style: .custom, isDarkMode: true))
        XCTAssertNil(PlatformLogoImage.cachedImage(providerKey: "not-a-provider", style: .standard),
                     "the dashed placeholder is not cached as a mark")
    }

    /// A published wave drops misses recorded on the previous epoch, so a
    /// row does not keep '?' until its own backoff fires.
    func testPublishedCatalogDropsANegativeMiss() {
        defer { PlatformLogoImage.invalidateCaches() }
        PlatformLogoImage.invalidateCaches()
        PlatformLogoImage.recordBundledMissForTesting(providerKey: "grok", style: .template, isDarkMode: true)
        let before = PlatformLogoImage.bundledCandidateProbes
        XCTAssertNil(PlatformLogoImage.load(providerKey: "grok", style: .template, isDarkMode: true))
        XCTAssertEqual(PlatformLogoImage.bundledCandidateProbes, before)

        // A preload in an earlier test may still have a coalesced note
        // queued.  Deliver it before arming this expectation, or the bump
        // belongs to that wave and this wait hangs.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        let epoch = PlatformLogoImage.markCatalogEpoch
        let posted = expectation(forNotification: PlatformLogoImage.marksDidResolve, object: nil)
        PlatformLogoImage.publishMarksResolved()
        XCTAssertGreaterThan(PlatformLogoImage.markCatalogEpoch, epoch)
        wait(for: [posted], timeout: 2)

        XCTAssertNotNil(PlatformLogoImage.load(providerKey: "grok", style: .template, isDarkMode: true))
        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: "grok", style: .template, isDarkMode: true))
        XCTAssertNotNil(PlatformLogoImage.load(providerKey: "grok", style: .standard, isDarkMode: false))
    }

    /// A pool row's bundled miss is cleared with the platform, the same way
    /// a pool-scoped custom fallback is.  Otherwise '?' stays after the
    /// platform mark is invalidated.
    func testPlatformInvalidationDropsPoolScopedBundledMisses() {
        defer { PlatformLogoImage.invalidateCaches() }
        PlatformLogoImage.invalidateCaches()
        PlatformLogoImage.recordBundledMissForTesting(providerKey: "google-antigravity:gemini",
                                                      style: .template, isDarkMode: true)
        let before = PlatformLogoImage.bundledCandidateProbes
        XCTAssertNil(PlatformLogoImage.load(providerKey: "google-antigravity:gemini",
                                            style: .template, isDarkMode: true))
        XCTAssertEqual(PlatformLogoImage.bundledCandidateProbes, before)

        PlatformLogoImage.invalidateCache(for: "google-antigravity")

        XCTAssertNotNil(PlatformLogoImage.load(providerKey: "google-antigravity:gemini",
                                               style: .template, isDarkMode: true))
        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: "google-antigravity:gemini",
                                                      style: .template, isDarkMode: true))
    }

    /// While the resource bundle cannot be resolved, a failed probe must not
    /// become a sticky miss.  The next probe has to look again.
    func testUnresolvedBundleIsNotRememberedAsAMiss() {
        defer { PlatformLogoImage.invalidateCaches() }
        PlatformLogoImage.invalidateCaches()
        PlatformLogoImage.bundleUnavailableForTesting = true
        defer { PlatformLogoImage.bundleUnavailableForTesting = false }

        let before = PlatformLogoImage.bundledCandidateProbes
        XCTAssertNil(PlatformLogoImage.load(providerKey: "xai", style: .template, isDarkMode: true))
        let mid = PlatformLogoImage.bundledCandidateProbes
        XCTAssertGreaterThan(mid, before)
        XCTAssertNil(PlatformLogoImage.cachedImage(providerKey: "xai", style: .template, isDarkMode: true))
        XCTAssertNil(PlatformLogoImage.load(providerKey: "xai", style: .template, isDarkMode: true))
        XCTAssertGreaterThan(PlatformLogoImage.bundledCandidateProbes, mid,
                             "a failure before the bundle is reachable must be probed again")

        PlatformLogoImage.bundleUnavailableForTesting = false
        XCTAssertNotNil(PlatformLogoImage.load(providerKey: "xai", style: .template, isDarkMode: true))
        XCTAssertNotNil(PlatformLogoImage.load(providerKey: "xai", style: .standard, isDarkMode: false))
    }

    /// Custom style falls back to the bundled colour mark.  A miss on that
    /// fallback must not stick in the custom cache as a placeholder, and a
    /// later decode has to show up on the memory-only read the row uses.
    func testCustomStylePicksUpTheBundledFallbackAfterAMiss() {
        defer { PlatformLogoImage.invalidateCaches() }
        XCTAssertFalse(PlatformLogoImage.hasCustomMark(providerKey: "kimi"),
                       "kimi must not have an on-disk custom mark for this test")
        PlatformLogoImage.invalidateCaches()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        PlatformLogoImage.recordBundledMissForTesting(providerKey: "kimi", style: .standard, isDarkMode: false)
        XCTAssertNil(PlatformLogoImage.load(providerKey: "kimi", style: .custom))
        XCTAssertNil(PlatformLogoImage.cachedImage(providerKey: "kimi", style: .custom))

        PlatformLogoImage.publishMarksResolved()
        XCTAssertNotNil(PlatformLogoImage.load(providerKey: "kimi", style: .custom))
        XCTAssertNotNil(PlatformLogoImage.cachedImage(providerKey: "kimi", style: .custom))
    }
}
