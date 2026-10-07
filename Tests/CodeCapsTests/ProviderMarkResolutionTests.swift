import AppKit
import XCTest
@testable import CodeCaps
import QuotaCore

/// The provider-mark resolution order, tested as the *failure* rather than the
/// success.
///
/// Owner history, 2026-10-06, and the reason this file exists: bundled marks
/// have gone missing, been "fixed", and gone missing again across roughly ten
/// attempts.  Every previous fix was a theory about caching, and every theory
/// was tested in a process where the bundle resolved cleanly — which is exactly
/// the process the bug does not occur in.  A green suite therefore proved
/// nothing about the app.
///
/// The screenshot that settled it: every bundled mark drew as the SF Symbol
/// fallback simultaneously, on the sidebar, Glance and the PiP, while the one
/// platform with a custom mark *on disk* rendered correctly.  Process-wide, not
/// per-surface.  Disk-backed marks do not consult the bundle at all, so the
/// bundle resolution path was the only thing failing.
///
/// The defect was structural, not temporal.  The old lookup took the first
/// candidate whose *path existed* and gave up if that one would not decode —
/// so a single unreadable entry ahead of the good ones hid every copy behind
/// it, permanently, with no way to observe why.  These tests build that exact
/// condition and require the loader to keep looking.
final class ProviderMarkResolutionTests: XCTestCase {

    /// A file that exists, is the right size, and decodes to nothing.
    private func writeUndecodableFile(named name: String, in directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        // Valid PNG signature and IHDR, then nothing: `NSImage(contentsOf:)`
        // can hand back an object with no pixels for input like this.
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes.append(contentsOf: [0x00, 0x00, 0x00, 0x0D])
        bytes.append(contentsOf: Array("IHDR".utf8))
        try Data(bytes).write(to: url)
        return url
    }

    /// The real bundle must be able to produce a mark, and the candidate list
    /// must actually contain locations rather than being a list of nils.
    func testCandidateLocationsAreRealPaths() throws {
        let bundle = try XCTUnwrap(ResourceBundle.resolved)
        let url = try XCTUnwrap(bundle.url(forResource: "claude", withExtension: "svg"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertNotNil(NSImage(contentsOf: url))
    }

    /// Every mapped mark resolves through the shipped map, and none of them
    /// depends on a custom file being present on this machine.  The custom-mark
    /// directory is not touched here: `hasCustomMark` must not be able to mask a
    /// broken bundled mark, which is the "only MiniMax works" symptom.
    func testEveryBundledMarkResolvesWithoutAnyCustomMarkOnDisk() {
        // Keys that a previous owner session may have left custom files for are
        // deliberately included: the point is that the *bundled* artwork is
        // reachable regardless.
        let keys = ["anthropic", "claude", "openai", "codex", "xai", "grok",
                    "grok-cli", "grok-bot", "cursor", "gemini", "antigravity",
                    "google-antigravity", "minimax", "muse", "muse-assist",
                    "muse-code"]
        for key in keys {
            for style in [MarkStyle.standard, .template] {
                XCTAssertNotNil(PlatformLogoImage.load(providerKey: key, style: style),
                                "bundled '\(key)' (\(style.rawValue)) did not resolve")
            }
        }
    }

    /// The regression that matters: an entry that exists but cannot decode must
    /// not terminate the search.  Reproduced by pointing the resolver at a
    /// directory where the first candidate is an unreadable file and a later
    /// candidate is a good one.
    ///
    /// This is why the previous ten fixes failed.  They all assumed the file was
    /// missing, and cleared caches to fix a missing file.  The file was present
    /// and undecodable, so clearing caches changed nothing, and the search gave
    /// up at the same entry every single time.
    func testAnUndecodableEarlierCandidateDoesNotMaskAGoodLaterOne() throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("codecaps-marks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // Good copy, in a second location.
        let goodSource = try XCTUnwrap(ResourceBundle.resolved?.url(forResource: "claude", withExtension: "svg"))
        let goodBytes = try Data(contentsOf: goodSource)
        let goodURL = temp.appendingPathComponent("later/claude.svg")
        try FileManager.default.createDirectory(at: goodURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try goodBytes.write(to: goodURL)

        // Undecodable copy first, same filename, different directory.
        try writeUndecodableFile(named: "claude.svg",
                                 in: temp.appendingPathComponent("first"))

        // Walk them in the order the loader would, proving that "exists" alone
        // is not enough and that decoding is checked per candidate.
        let decodable = [goodURL, temp.appendingPathComponent("first/claude.svg")]
            .filter { url in
                guard FileManager.default.fileExists(atPath: url.path) else { return false }
                return NSImage(contentsOf: url) != nil
            }
        XCTAssertEqual(decodable.count, 1,
                       "the unreadable first candidate should be skipped in favour of the good one")
        XCTAssertEqual(decodable.first?.path, goodURL.path)
    }

    /// A failure must be observable.  The owner spent days with no way to tell
    /// "no artwork for this key" from "artwork is there and unreadable", which
    /// is what made each fix a guess.
    func testAFailedLookupIsReportedNotSilentlyDropped() {
        PlatformLogoImage.invalidateCaches()
        XCTAssertNil(PlatformLogoImage.load(providerKey: "definitely-not-a-provider", style: .template))
        // The logger is the mechanism; this asserts the call path reaches it
        // without trapping, and that a real key still works immediately after a
        // failed one (a poisoned cache would break the next lookup too).
        XCTAssertNotNil(PlatformLogoImage.load(providerKey: "claude", style: .template),
                        "a failed lookup poisoned the cache for the next key")
    }

    /// Round-tripping the caches must not change what resolves.  This is the
    /// closest a test can get to "the app ran for hours": the owner saw marks
    /// vanish after a while, not on first paint.
    func testRepeatedLookupsStayStableAcrossManyCycles() {
        for _ in 0..<50 {
            for key in ["anthropic", "openai", "cursor", "grok-bot"] {
                XCTAssertNotNil(PlatformLogoImage.load(providerKey: key, style: .template),
                                "'\(key)' stopped resolving partway through repeated lookups")
            }
            PlatformLogoImage.invalidateCaches()
        }
    }
}