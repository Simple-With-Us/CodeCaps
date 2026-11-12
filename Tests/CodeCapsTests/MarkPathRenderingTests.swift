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
}
