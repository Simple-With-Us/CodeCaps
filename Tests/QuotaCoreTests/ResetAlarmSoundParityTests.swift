import XCTest
@testable import QuotaCore

/// The iOS companion cannot import `QuotaCore` -- `Package.swift` declares the
/// library for macOS only, and it reads the current user's home directory and
/// spawns helper processes, neither of which exists on iOS.  So
/// `ios/CodeCapsCompanion/App/Models/ResetAlarmSound.swift` is a hand-mirrored
/// copy, and the raw values are a wire contract: both apps persist a picked tone
/// under the App Group key `alarmSound`, so a value that exists on one platform
/// and not the other silently falls back to a different tone on the other.
///
/// That mirror is a drift hazard this test turns into a build failure.  It
/// reads the iOS source and compares the case list, the raw values, the picker
/// order, and the bundled-audio mapping against the canonical enum.
final class ResetAlarmSoundParityTests: XCTestCase {
    /// The mirrored iOS file, located relative to this test file so the check
    /// does not depend on the working directory.
    private static var iOSSourceURL: URL? {
        URL(fileURLWithPath: #filePath)          // Tests/QuotaCoreTests/…
            .deletingLastPathComponent()          // Tests/QuotaCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("ios/CodeCapsCompanion/App/Models/ResetAlarmSound.swift")
    }

    private func iOSSource() throws -> String {
        guard let url = Self.iOSSourceURL, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("iOS mirrored ResetAlarmSound.swift is not present in this checkout")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Pulls `case name = "raw"` pairs out of the mirrored enum body.
    private func iOSCases(in source: String) throws -> [String: String] {
        let pattern = #"case\s+(\w+)\s*=\s*"([^"]*)""#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(source.startIndex..., in: source)
        var found: [String: String] = [:]
        for match in regex.matches(in: source, range: range) {
            guard let nameRange = Range(match.range(at: 1), in: source),
                  let rawRange = Range(match.range(at: 2), in: source) else { continue }
            found[String(source[nameRange])] = String(source[rawRange])
        }
        return found
    }

    /// Extracts the case names of an array literal such as
    /// `[.systemDefault, .glass, ...]` that follows an `= [`.
    private func iOSPickerLiterals(in source: String, after marker: String) throws -> [String] {
        guard let markerRange = source.range(of: marker) else { return [] }
        let tail = String(source[markerRange.upperBound...])
        // Skip past the `[ResetAlarmSound]` type annotation to the literal itself.
        guard let open = tail.range(of: "= [") else { return [] }
        let body = String(tail[open.upperBound...])
        guard let close = body.range(of: "]") else { return [] }
        let names = String(body[..<close.lowerBound])
        let regex = try NSRegularExpression(pattern: #"\.(\w+)"#)
        return regex.matches(in: names, range: NSRange(names.startIndex..., in: names)).compactMap {
            Range($0.range(at: 1), in: names).map { String(names[$0]) }
        }
    }

    func testEveryCaseExistsOnBothSidesWithTheSameRawValue() throws {
        let iOS = try iOSCases(in: try iOSSource())
        XCTAssertFalse(iOS.isEmpty, "failed to parse any case out of the mirrored iOS enum")

        // Canonical side, keyed by case name so it lines up with what the mirror
        // parses: the mirror spells `case glass = "Glass"`, so the name is
        // `glass` and the raw value is `Glass`.
        let canonical = Dictionary(uniqueKeysWithValues:
            ResetAlarmSound.allCases.map { (String(describing: $0), $0.rawValue) })

        XCTAssertEqual(Set(iOS.keys), Set(canonical.keys),
                       "the iOS mirror and Sources/QuotaCore/ResetAlarmSound.swift have drifted on which cases exist")

        for (name, rawValue) in canonical {
            XCTAssertEqual(iOS[name], rawValue,
                           "raw value for .\(name) differs between macOS and the iOS mirror; "
                           + "the App Group alarmSound key is a wire contract, so they must match")
        }
    }

    func testPickerOrderMatches() throws {
        let iOSOrder = try iOSPickerLiterals(in: try iOSSource(), after: "defaultPickerOrder")
        XCTAssertFalse(iOSOrder.isEmpty, "failed to parse defaultPickerOrder from the mirrored iOS enum")
        XCTAssertEqual(iOSOrder, ResetAlarmSound.defaultPickerOrder.map { String(describing: $0) },
                       "picker order differs between macOS and the iOS mirror")
    }

    /// Every audible tone needs a bundled file on iOS, because
    /// `UNNotificationSound(named:)` resolves only the app's own audio there.
    /// The names are the join between the enum and the generated WAVs.
    func testEveryAudibleToneHasABundledAssetName() throws {
        for sound in ResetAlarmSound.allCases {
            if sound == .silent || sound == .systemDefault {
                XCTAssertNil(sound.bundledAssetName,
                             ".\(sound.rawValue) must not name a file: it is expressed without bundled audio")
            } else {
                XCTAssertNotNil(sound.bundledAssetName, ".\(sound.rawValue) is audible but has no bundled audio")
            }
        }
    }

    func testBundledAssetNamesMatchBetweenPlatforms() throws {
        let source = try iOSSource()
        for sound in ResetAlarmSound.allCases {
            guard let name = sound.bundledAssetName else { continue }
            XCTAssertTrue(source.contains("\"\(name)\""),
                          "the iOS mirror is missing the bundled asset mapping for .\(sound.rawValue)")
        }
        XCTAssertTrue(source.contains("bundledAssetExtension = \"\(ResetAlarmSound.bundledAssetExtension)\""),
                      "bundled audio extension differs between the two enums")
    }

    /// The generated files must actually exist, or the preview and the alert are
    /// both mute on iOS no matter what the enum claims.
    func testGeneratedAudioFilesExistForEveryMappedTone() throws {
        // …/App/Models/ResetAlarmSound.swift -> …/App/Resources
        let resourceDir = Self.iOSSourceURL?
            .deletingLastPathComponent()             // App/Models
            .deletingLastPathComponent()             // App
            .appendingPathComponent("Resources")
        guard let resourceDir, FileManager.default.fileExists(atPath: resourceDir.path) else {
            throw XCTSkip("iOS Resources directory is not present in this checkout")
        }
        for sound in ResetAlarmSound.allCases {
            guard let name = sound.bundledAssetName else { continue }
            let file = resourceDir
                .appendingPathComponent(name)
                .appendingPathExtension(ResetAlarmSound.bundledAssetExtension)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path),
                          "missing bundled tone \(file.lastPathComponent); run scripts/generate-alarm-sounds.py")
        }
    }
}
