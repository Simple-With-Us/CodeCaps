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

    func testDropsFailedRequestsFromThirdPartyProviderAPIs() {
        // Control: the same failed-request event against our own host is kept.
        XCTAssertFalse(SentryTelemetry.isThirdPartyFailedRequest(
            url: "https://codecaps.simplewithus.com/api/v2/ingest", exceptionTypes: ["HTTPClientError"]))
        XCTAssertTrue(SentryTelemetry.isThirdPartyFailedRequest(
            url: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus",
            exceptionTypes: ["HTTPClientError"]))
        XCTAssertTrue(SentryTelemetry.isThirdPartyFailedRequest(
            url: "https://api.anthropic.com/api/oauth/usage", exceptionTypes: ["HTTPClientError"]))
        // A real exception that merely carries a provider URL is not dropped.
        XCTAssertFalse(SentryTelemetry.isThirdPartyFailedRequest(
            url: "https://api2.cursor.sh/x", exceptionTypes: ["DecodingError"]))
        // A look-alike host is not a suffix match.
        XCTAssertFalse(SentryTelemetry.isThirdPartyFailedRequest(
            url: "https://notcursor.sh/x", exceptionTypes: ["HTTPClientError"]))
    }
}
