import XCTest
@testable import CodeCaps
import QuotaCore

/// The exhausted alert and the at-cap line have to agree on one threshold.
///
/// The shared rule spends a window at or below half a point remaining, and the
/// interface rounds that to zero percent, so a window reading 0.4% draws
/// "At cap" on the card.  The alert path used its own zero test, so the owner
/// saw "At cap" and never received the "Quota Exhausted" notification
/// (Kody review 2026-10-21).
///
/// The Mac's alert path lives inside a large `MonitorModel`, so the rule it
/// reads is pinned by reading the source, the way the phone's own companion
/// model is pinned in `CompanionModelTests`.
final class ExhaustionCapRuleTests: XCTestCase {
    private static var monitorModelURL: URL? {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/CodeCapsTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/CodeCaps/MonitorModel.swift")
    }

    private static var settingsViewsURL: URL? {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/CodeCaps/SettingsViews.swift")
    }

    private func read(_ url: URL?) throws -> String {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("The source file is not present at \(url?.path ?? "")")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The Mac's exhausted alert fires on the shared rule.
    func testTheMacAlertFiresOnTheSharedRuleRatherThanOnZero() throws {
        let source = try read(Self.monitorModelURL)
        XCTAssertTrue(
            source.contains("if !QuotaCapRule.isAtCap(remainingPercent: remaining)"),
            "the Mac's exhausted alert must read the shared cap rule, so it fires at the same threshold as the at-cap line"
        )
        XCTAssertFalse(
            source.contains("if remaining > 0 {"),
            "a local zero test here left the Mac quiet while the card said 'At cap'"
        )
    }

    /// The settings copy names the threshold the app actually uses, so it
    /// cannot drift back to "zero remaining" and describe a rule the app no
    /// longer follows.
    func testTheSettingsCopyNamesTheSharedThreshold() throws {
        let source = try read(Self.settingsViewsURL)
        XCTAssertFalse(
            source.contains("Quota Exhausted fires at zero remaining"),
            "the copy has to describe the threshold the app uses, not the one it used to use"
        )
        XCTAssertTrue(
            source.contains("QuotaCapRule.spentThreshold"),
            "the copy must quote the shared threshold itself, so a change to the rule cannot leave the copy behind"
        )
        XCTAssertTrue(
            source.contains(".formatted(.number.precision(.fractionLength(0...1)))"),
            "the threshold is a Double, so a plain interpolation would print 1.0% once the rule reaches a whole number"
        )
    }

    /// The rule itself spends a window at or below the threshold and calls a
    /// larger reading headroom, whichever surface asks.
    func testTheSharedRuleIsTheOneBothSurfacesAsk() {
        XCTAssertTrue(QuotaCapRule.isAtCap(remainingPercent: 0.4))
        XCTAssertTrue(QuotaCapRule.isAtCap(remainingPercent: 0))
        XCTAssertFalse(QuotaCapRule.isAtCap(remainingPercent: 0.6))
        XCTAssertFalse(QuotaCapRule.isAtCap(remainingPercent: nil))
        // The reading decides, and the provider's own word is the fallback
        // for a window that reports no figure at all.
        XCTAssertTrue(QuotaCapRule.isExhausted(remainingPercent: 0.4, providerSaysExhausted: false))
        XCTAssertFalse(QuotaCapRule.isExhausted(remainingPercent: 50, providerSaysExhausted: true))
        XCTAssertTrue(QuotaCapRule.isExhausted(remainingPercent: nil, providerSaysExhausted: true))
        XCTAssertFalse(QuotaCapRule.isExhausted(remainingPercent: nil, providerSaysExhausted: false))
    }
}
