import AppKit
@testable import CodeCaps
import XCTest

final class PlatformLogoTests: XCTestCase {
    func testGrokBotLogoLoadsAsTemplateForDarkModeInversion() {
        // Grok Bot should load as a template in both template and standard modes
        // so that it inverts between Light mode (dark sphere) and Dark mode (light sphere).
        let templateImage = PlatformLogoImage.load(providerKey: "grok-bot", style: .template)
        XCTAssertNotNil(templateImage, "Grok Bot template image should load successfully.")
        XCTAssertTrue(templateImage?.isTemplate == true, "Grok Bot template mark must have isTemplate == true.")

        let standardImage = PlatformLogoImage.load(providerKey: "grok-bot", style: .standard)
        XCTAssertNotNil(standardImage, "Grok Bot standard image should load successfully.")
        XCTAssertTrue(standardImage?.isTemplate == true, "Grok Bot standard mark must adapt to Dark mode as a template.")
    }

    func testStandardPreservesBrandColorForNonMonochromeMarks() {
        let claudeStandard = PlatformLogoImage.load(providerKey: "claude", style: .standard)
        XCTAssertNotNil(claudeStandard, "Claude standard mark should load.")
        XCTAssertFalse(claudeStandard?.isTemplate == true, "Claude standard mark must preserve full brand color.")

        let claudeTemplate = PlatformLogoImage.load(providerKey: "claude", style: .template)
        XCTAssertNotNil(claudeTemplate, "Claude template mark should load.")
        XCTAssertTrue(claudeTemplate?.isTemplate == true, "Claude template mark must have isTemplate == true.")
    }

    func testFallbackSymbolsAreDefined() {
        XCTAssertEqual(PlatformLogoImage.fallbackSymbolName(for: "grok-bot"), "bolt.badge.a")
        XCTAssertEqual(PlatformLogoImage.fallbackSymbolName(for: "grok"), "bolt")
        XCTAssertEqual(PlatformLogoImage.fallbackSymbolName(for: "unknown"), "gauge.with.dots.needle.50percent")
    }

    // MARK: - Resource bundle resolution

    private func makeBundleDir(in root: URL) throws -> URL {
        let bundleDir = root.appendingPathComponent("\(ResourceBundle.name).bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: bundleDir, withIntermediateDirectories: true)
        return bundleDir
    }

    /// The bug this guards: `Bundle.module` calls `fatalError` when the resource
    /// bundle is not in one of the two places it probes, and the app's first
    /// touch of it happens while building the menu bar icon during launch.  The
    /// resolver has to come back empty-handed instead.
    func testResolveReturnsNilRatherThanTrappingWhenNoBundleIsPresent() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codecaps-nores-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        XCTAssertNil(ResourceBundle.resolve(in: [empty]))
    }

    func testResolveFindsTheBundleAtTheAppRoot() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codecaps-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bundleDir = try makeBundleDir(in: root)

        XCTAssertEqual(ResourceBundle.resolve(in: [root])?.bundleURL.standardizedFileURL,
                       bundleDir.standardizedFileURL)
    }

    func testResolveSkipsRootsWithoutTheBundle() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codecaps-empty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let populated = empty.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: populated, withIntermediateDirectories: true)
        let bundleDir = try makeBundleDir(in: populated)

        XCTAssertEqual(ResourceBundle.resolve(in: [empty, populated])?.bundleURL.standardizedFileURL,
                       bundleDir.standardizedFileURL)
    }

    /// The decision that keeps a broken install from being a broken app: inside
    /// an installed `.app` the build directory that `Bundle.module` points at is
    /// gone, so the accessor must not be reached and the resolver answers nil.
    func testGeneratedAccessorIsRefusedInsideAnAppBundle() {
        XCTAssertFalse(ResourceBundle.mayUseGeneratedAccessor(
            appBundleURL: URL(fileURLWithPath: "/Users/jay/Applications/CodeCaps.app")))
    }

    /// A bare executable out of `.build` and the XCTest harness both still have
    /// that directory, so the accessor is the right -- and only -- way there.
    func testGeneratedAccessorIsAllowedForBareBuildDirectoryAndTestHarness() {
        XCTAssertTrue(ResourceBundle.mayUseGeneratedAccessor(
            appBundleURL: URL(fileURLWithPath: "/repo/.build/arm64-apple-macosx/debug")))
        XCTAssertTrue(ResourceBundle.mayUseGeneratedAccessor(
            appBundleURL: URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin")))
    }

    /// A missing bundle must cost a brand mark, not the whole process: the loader
    /// returns nil so `PlatformLogo` draws its SF Symbol fallback.
    func testLoadReturnsNilForAProviderWithNoMark() {
        XCTAssertNil(PlatformLogoImage.load(providerKey: "does-not-exist", style: .template))
        XCTAssertNil(PlatformLogoImage.menuBarImage(providerKey: "does-not-exist", style: .template))
    }

    // MARK: - Custom Mark Modes and Dark Variants

    private func createTestPNG() throws -> URL {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemRed.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        guard let tiffData = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiffData),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "PlatformLogoTests", code: 1, userInfo: nil)
        }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test-mark-\(UUID().uuidString).png")
        try pngData.write(to: url)
        return url
    }

    func testCustomMarkDefaultsToColorMode() {
        let key = "test-provider-\(UUID().uuidString.prefix(8))"
        XCTAssertEqual(PlatformLogoImage.customMarkMode(for: key), .color,
                       "Custom marks must default to .color mode to preserve original artwork.")
    }

    func testCustomMarkModePersistsAndBustsCache() {
        let key = "test-mode-\(UUID().uuidString.prefix(8))"
        PlatformLogoImage.setCustomMarkMode(.template, for: key)
        XCTAssertEqual(PlatformLogoImage.customMarkMode(for: key), .template)

        PlatformLogoImage.setCustomMarkMode(.color, for: key)
        XCTAssertEqual(PlatformLogoImage.customMarkMode(for: key), .color)
    }

    func testCustomMarkImportAndColorModeRendering() throws {
        let key = "test-import-\(UUID().uuidString.prefix(8))"
        let sourceURL = try createTestPNG()
        defer {
            try? FileManager.default.removeItem(at: sourceURL)
            PlatformLogoImage.removeCustomMark(providerKey: key)
        }

        // Import primary custom mark
        let imported = PlatformLogoImage.importCustomMark(from: sourceURL, providerKey: key)
        XCTAssertNotNil(imported)
        XCTAssertEqual(PlatformLogoImage.customPrimaryMarkURL(providerKey: key)?.standardizedFileURL,
                       imported?.standardizedFileURL)

        // Default mode is .color: custom logo must preserve full color (isTemplate == false)
        let colorLoaded = PlatformLogoImage.load(providerKey: key, style: .custom)
        XCTAssertNotNil(colorLoaded)
        XCTAssertFalse(colorLoaded?.isTemplate == true,
                       "In Color Version mode, custom marks must have isTemplate == false to prevent black tinting.")

        let colorMenuBar = PlatformLogoImage.menuBarImage(providerKey: key, size: 16, style: .custom)
        XCTAssertNotNil(colorMenuBar)
        XCTAssertFalse(colorMenuBar?.isTemplate == true,
                       "In Color Version mode, menu bar custom marks must have isTemplate == false.")

        // Switch to .template mode: custom logo must adapt as template (isTemplate == true)
        PlatformLogoImage.setCustomMarkMode(.template, for: key)
        let templateLoaded = PlatformLogoImage.load(providerKey: key, style: .custom)
        XCTAssertNotNil(templateLoaded)
        XCTAssertTrue(templateLoaded?.isTemplate == true,
                      "In Light/Dark Version mode, custom marks must have isTemplate == true.")

        let templateMenuBar = PlatformLogoImage.menuBarImage(providerKey: key, size: 16, style: .custom)
        XCTAssertNotNil(templateMenuBar)
        XCTAssertTrue(templateMenuBar?.isTemplate == true,
                      "In Light/Dark Version mode, menu bar custom marks must have isTemplate == true.")

        // Import Dark appearance variant
        let darkSourceURL = try createTestPNG()
        defer { try? FileManager.default.removeItem(at: darkSourceURL) }

        let darkImported = PlatformLogoImage.importCustomMark(from: darkSourceURL, providerKey: key, isDarkMode: true)
        XCTAssertNotNil(darkImported)
        XCTAssertEqual(PlatformLogoImage.customDarkMarkURL(providerKey: key)?.standardizedFileURL,
                       darkImported?.standardizedFileURL)

        // When isDarkMode is true, customMarkURL resolves dark variant
        XCTAssertEqual(PlatformLogoImage.customMarkURL(providerKey: key, isDarkMode: true)?.standardizedFileURL,
                       darkImported?.standardizedFileURL)
        // When isDarkMode is false, customMarkURL resolves primary variant
        XCTAssertEqual(PlatformLogoImage.customMarkURL(providerKey: key, isDarkMode: false)?.standardizedFileURL,
                       imported?.standardizedFileURL)

        // Removing only the dark variant preserves the primary mark
        PlatformLogoImage.removeCustomMark(providerKey: key, isDarkMode: true)
        XCTAssertNil(PlatformLogoImage.customDarkMarkURL(providerKey: key))
        XCTAssertNotNil(PlatformLogoImage.customPrimaryMarkURL(providerKey: key))

        // Removing without dark flag removes all variants
        PlatformLogoImage.removeCustomMark(providerKey: key)
        XCTAssertNil(PlatformLogoImage.customPrimaryMarkURL(providerKey: key))
        XCTAssertNil(PlatformLogoImage.customDarkMarkURL(providerKey: key))
    }

    @MainActor
    func testMonitorModelCustomMarkIntegration() throws {
        let suite = "test-model-\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: suite) else {
            XCTFail("Failed to create test UserDefaults")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: suite) }

        let model = MonitorModel(defaults: testDefaults)
        let key = "test-provider-\(UUID().uuidString.prefix(8))"

        XCTAssertEqual(model.customMarkMode(for: key), .color)
        model.setCustomMarkMode(.template, for: key)
        XCTAssertEqual(model.customMarkMode(for: key), .template)

        let source = try createTestPNG()
        defer {
            try? FileManager.default.removeItem(at: source)
            model.clearCustomMark(for: key)
        }

        let saved = model.setCustomMark(at: source, for: key)
        XCTAssertNotNil(saved)
        XCTAssertEqual(model.markStyle(for: key), .custom)
        XCTAssertNotNil(model.customMarkURL(for: key, isDarkMode: false))

        let darkSource = try createTestPNG()
        defer { try? FileManager.default.removeItem(at: darkSource) }

        let darkSaved = model.setCustomMark(at: darkSource, for: key, isDarkMode: true)
        XCTAssertNotNil(darkSaved)
        XCTAssertNotNil(model.customMarkURL(for: key, isDarkMode: true))

        // Clearing dark removes dark path only
        model.clearCustomMark(for: key, isDarkMode: true)
        XCTAssertNil(model.customMarkURL(for: key, isDarkMode: true))
        XCTAssertNotNil(model.customMarkURL(for: key, isDarkMode: false))

        // Clearing all resets markStyle to .template
        model.clearCustomMark(for: key)
        XCTAssertNil(model.customMarkURL(for: key, isDarkMode: false))
        XCTAssertEqual(model.markStyle(for: key), .template)
    }
}
