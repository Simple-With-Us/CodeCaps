import XCTest
@testable import CodeCaps

/// Pins DSN resolution only.  `SentryTelemetry.start()` is never called from
/// these tests — a missing or unsubstituted DSN must stay a no-op, and a
/// live DSN must never be invented here.
final class SentryTelemetryTests: XCTestCase {
    func testEmptyEnvironmentAndPlistSkipsInit() {
        XCTAssertNil(SentryTelemetry.resolvedDSN(environment: [:], plistValue: nil))
        XCTAssertNil(SentryTelemetry.resolvedDSN(environment: ["SENTRY_DSN": ""], plistValue: ""))
        XCTAssertNil(SentryTelemetry.resolvedDSN(environment: ["SENTRY_DSN": "   "], plistValue: "\n"))
    }

    func testUnsubstitutedBuildSettingCountsAsMissing() {
        XCTAssertNil(SentryTelemetry.resolvedDSN(
            environment: ["SENTRY_DSN": "$(SENTRY_DSN)"],
            plistValue: "$(SENTRY_DSN)"))
        XCTAssertNil(SentryTelemetry.usableDSN("$(SENTRY_DSN)"))
    }

    func testEnvironmentWinsOverPlist() {
        let dsn = SentryTelemetry.resolvedDSN(
            environment: ["SENTRY_DSN": "https://example.invalid/1"],
            plistValue: "https://example.invalid/plist")
        XCTAssertEqual(dsn, "https://example.invalid/1")
    }

    func testPlistIsUsedWhenEnvironmentIsEmpty() {
        let dsn = SentryTelemetry.resolvedDSN(
            environment: [:],
            plistValue: "  https://example.invalid/plist  ")
        XCTAssertEqual(dsn, "https://example.invalid/plist")
    }

    func testSurroundingWhitespaceIsTrimmed() {
        XCTAssertEqual(
            SentryTelemetry.usableDSN("\n https://example.invalid/2 \t"),
            "https://example.invalid/2")
    }

    func testFailedRequestCaptureCoversOnlyFirstPartyHosts() {
        let hosts = SentryTelemetry.firstPartyFailedRequestHosts
        XCTAssertTrue(hosts.contains("codecaps.simplewithus.com"))
        XCTAssertFalse(hosts.contains { $0.contains("cursor.sh") })
    }
}
