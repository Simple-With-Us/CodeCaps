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
}
