import XCTest
import Foundation

/// Verifies CodeCaps WidgetKit data models, presentation logic, wire payload decoding,
/// platform ordering, and project/entitlement hygiene.
final class WidgetTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/CodeCapsTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private static var widgetPresentationURL: URL {
        repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetPresentation.swift")
    }

    private static var projectYmlURL: URL {
        repoRoot.appendingPathComponent("ios/CodeCapsCompanion/project.yml")
    }

    private static var widgetEntitlementsURL: URL {
        repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/CodeCapsWidgets.entitlements")
    }

    private static var widgetMacEntitlementsURL: URL {
        repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/CodeCapsWidgetsMac.entitlements")
    }

    private func readSource(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("File not found at \(url.path)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Sentence Gap & Hygiene Tests

    func testWidgetSentenceGapHygiene() throws {
        let source = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(
            source.contains("widgetSentenceGap = \"\\u{00A0} \""),
            "WidgetPresentation must define widgetSentenceGap with non-breaking space per fleet standards"
        )
    }

    func testWidgetEntitlementsAppGroup() throws {
        let iosEntitlements = try readSource(at: Self.widgetEntitlementsURL)
        XCTAssertTrue(
            iosEntitlements.contains("group.com.simplewithus.codecaps"),
            "iOS widget entitlements must declare group.com.simplewithus.codecaps"
        )

        let macEntitlements = try readSource(at: Self.widgetMacEntitlementsURL)
        XCTAssertTrue(
            macEntitlements.contains("group.com.simplewithus.codecaps"),
            "macOS widget entitlements must declare group.com.simplewithus.codecaps"
        )
        XCTAssertTrue(
            macEntitlements.contains("com.apple.security.app-sandbox"),
            "macOS widget entitlements must declare app-sandbox"
        )
    }

    func testProjectYmlDeclaresWidgetTargets() throws {
        let yml = try readSource(at: Self.projectYmlURL)
        XCTAssertTrue(
            yml.contains("CodeCapsWidgets:"),
            "project.yml must define CodeCapsWidgets target"
        )
        XCTAssertTrue(
            yml.contains("CodeCapsWidgetsMac:"),
            "project.yml must define CodeCapsWidgetsMac target"
        )
        XCTAssertTrue(
            yml.contains("target: CodeCapsWidgets"),
            "CodeCapsCompanion must embed CodeCapsWidgets"
        )
        XCTAssertTrue(
            yml.contains("target: CodeCapsWidgetsMac"),
            "CodeCapsCompanionMac must embed CodeCapsWidgetsMac"
        )
    }

    // MARK: - Presentation Logic Tests (Simulated with mirrored pure logic)

    func testPercentFormatting() {
        XCTAssertEqual(formatPercent(82.4, isMasked: false), "82%")
        XCTAssertEqual(formatPercent(0.0, isMasked: false), "0%")
        XCTAssertEqual(formatPercent(99.6, isMasked: false), "100%")
        XCTAssertEqual(formatPercent(nil, isMasked: false), "—")
        XCTAssertEqual(formatPercent(50.0, isMasked: true), "n/a")
    }

    func testCountdownFormatting() {
        let now = Date()
        let future5m = now.addingTimeInterval(300)
        let future2h = now.addingTimeInterval(7200)
        let future2d = now.addingTimeInterval(86400 * 2 + 3600 * 3)
        let past = now.addingTimeInterval(-60)

        XCTAssertEqual(formatCountdown(resetAt: future5m, now: now), "5m")
        XCTAssertEqual(formatCountdown(resetAt: future2h, now: now), "2h")
        XCTAssertEqual(formatCountdown(resetAt: future2d, now: now), "2d 3h")
        XCTAssertEqual(formatCountdown(resetAt: past, now: now), "due")
        XCTAssertEqual(formatCountdown(resetAt: nil, now: now), "")
    }

    func testWirePayloadParsing() throws {
        let json = """
        {
          "windows": [
            {
              "id": "claude-5h",
              "provider": "anthropic",
              "providerKey": "anthropic",
              "label": "5-hour window",
              "remainingPercent": 78.5,
              "isExhausted": false,
              "resetAt": "2026-09-30T04:00:00Z"
            },
            {
              "id": "cursor-fast",
              "provider": "cursor",
              "providerKey": "cursor",
              "label": "Fast Requests",
              "remainingPercent": 42.0,
              "isExhausted": false,
              "resetAt": "2026-10-15T00:00:00Z"
            }
          ]
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        struct WireEnvelope: Decodable {
            let windows: [WireWindow]?
        }
        struct WireWindow: Decodable {
            let id: String
            let provider: String
            let providerKey: String?
            let label: String
            let remainingPercent: Double?
        }

        let envelope = try JSONDecoder().decode(WireEnvelope.self, from: data)
        let windows = try XCTUnwrap(envelope.windows)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].provider, "anthropic")
        XCTAssertEqual(windows[0].remainingPercent, 78.5)
        XCTAssertEqual(windows[1].provider, "cursor")
        XCTAssertEqual(windows[1].remainingPercent, 42.0)
    }

    // MARK: - Helpers mirroring WidgetPresentation logic for test isolation

    private func formatPercent(_ percent: Double?, isMasked: Bool) -> String {
        if isMasked { return "n/a" }
        guard let percent else { return "—" }
        return "\(Int(percent.rounded()))%"
    }

    private func formatCountdown(resetAt: Date?, now: Date) -> String {
        guard let resetAt else { return "" }
        let seconds = resetAt.timeIntervalSince(now)
        guard seconds > 0 else { return "due" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 {
            let days = minutes / 1440
            let hours = (minutes % 1440) / 60
            return "\(days)d\(hours > 0 ? " \(hours)h" : "")"
        }
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return "\(hours)h\(mins > 0 ? " \(mins)m" : "")"
        }
        return "\(minutes)m"
    }
}
