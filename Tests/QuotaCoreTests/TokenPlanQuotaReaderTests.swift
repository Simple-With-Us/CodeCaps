import Foundation
import XCTest
@testable import QuotaCore

final class TokenPlanQuotaReaderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAlibabaUsesOnlyReportedWindows() throws {
        let data = Data(#"{"per1MonthPercentage":0.4,"per1MonthResetTime":1800964800000,"hasQuotaData":true}"#.utf8)
        let window = try XCTUnwrap(TokenPlanQuotaParser.alibaba(data, now: now).first)
        XCTAssertEqual(window.remainingPercent, 60)
        XCTAssertEqual(window.label, "Monthly")
        XCTAssertNotNil(window.resetAt)
        XCTAssertEqual(TokenPlanQuotaParser.alibaba(data, now: now).count, 1)
        XCTAssertNil(window.absoluteLimit)
    }

    func testAlibabaMissingQuotaOrMalformedWindowDoesNotLookFull() {
        for raw in [
            #"{"hasQuotaData":false,"per1MonthPercentage":0}"#,
            #"{"per1MonthPercentage":true}"#,
            #"{"per1MonthPercentage":0,"per1MonthResetTime":1790000000000}"#,
            #"{"per1MonthPercentage":1.1}"#,
        ] {
            XCTAssertTrue(TokenPlanQuotaParser.alibaba(Data(raw.utf8), now: now).isEmpty)
        }
    }

    func testMiMoKeepsCreditsAndVendorPeriod() throws {
        let data = Data(#"{"object":"token_plan","period":{"start_at":"2026-09-21 23:59:59","end_at":"2027-09-21 23:59:59"},"quota":{"total_credits":4100000000,"used_credits":1025000000,"remaining_credits":3075000000}}"#.utf8)
        let window = try XCTUnwrap(TokenPlanQuotaParser.mimo(data, now: now))
        XCTAssertEqual(window.remainingPercent, 75)
        XCTAssertEqual(window.absoluteLimit, 4_100_000_000)
        XCTAssertEqual(window.periodStart, "2026-09-21T23:59:59Z")
        XCTAssertEqual(window.resetAt, "2027-09-21T23:59:59Z")
        XCTAssertEqual(window.quotaUnit, "credits")
    }

    func testMiMoRefusesInvalidCreditsAndExpiredCycle() {
        let data = Data(#"{"object":"token_plan","period":{"start_at":"2026-09-21 23:59:59","end_at":"2027-09-21 23:59:59"},"quota":{"total_credits":100,"used_credits":30,"remaining_credits":99}}"#.utf8)
        XCTAssertNil(TokenPlanQuotaParser.mimo(data, now: now))
        let exhausted = Data(#"{"object":"token_plan","period":{"start_at":"2026-09-21 23:59:59","end_at":"2027-09-21 23:59:59"},"quota":{"total_credits":100,"used_credits":120,"remaining_credits":0}}"#.utf8)
        XCTAssertEqual(TokenPlanQuotaParser.mimo(exhausted, now: now)?.status, .exhausted)
        XCTAssertNil(TokenPlanQuotaParser.mimo(exhausted, now: Date(timeIntervalSince1970: 2_000_000_000)))
    }

    func testMiMoRequestHostsAreFixedRegionalXiaomiOrigins() {
        let hosts = MiMoTokenPlanRegion.allCases.map { $0.quotaURL.host ?? "" }
        XCTAssertEqual(Set(hosts), [
            "token-plan-cn.xiaomimimo.com", "token-plan-sgp.xiaomimimo.com", "token-plan-ams.xiaomimimo.com",
        ])
        XCTAssertTrue(MiMoTokenPlanRegion.allCases.allSatisfy { $0.quotaURL.path == "/v1/platform/token_plan" })
    }

    func testTokenPlanLabelsAndFleetFallbackDoNotCreateAlwaysVisibleProviders() {
        let labels = [
            "alibaba-token-plan": "Alibaba Token Plan",
            "alibaba-coding-plan": "Alibaba Coding Plan",
            "mimo-token-plan": "Xiaomi MiMo Token Plan",
        ]
        let windows = labels.keys.sorted().map { key in
            QuotaWindow(id: key + ":sample", provider: key, providerKey: key,
                        label: "Quota", remainingPercent: 75, occurredAt: "2026-11-25T00:00:00Z")
        }
        for (key, label) in labels {
            XCTAssertEqual(quotaProviderLabel(key), label)
            XCTAssertFalse(expectedQuotaProviderKeys.contains(key))
        }
        let fallback = QuotaLocalScope.fleetFallback(fleet: windows, adopted: [], localProviders: [])
        XCTAssertEqual(Set(fallback.fallback.map(\.canonicalProviderKey)), Set(labels.keys))
        let withLocalRead = QuotaLocalScope.fleetFallback(
            fleet: windows, adopted: [], localProviders: ["mimo-token-plan"])
        XCTAssertEqual(Set(withLocalRead.fallback.map(\.canonicalProviderKey)), ["alibaba-token-plan", "alibaba-coding-plan"])
    }

    func testAlibabaCodingPlanUsesDistinctReportedRequestWindows() {
        let data = Data(#"{"instanceType":"pro","per5Hour":{"usedQuota":25,"totalQuota":100,"percentage":0.25,"resetTime":1800018000000},"perWeek":{},"perBillMonth":{"usedQuota":1010,"totalQuota":1000,"percentage":1.01}}"#.utf8)
        let windows = TokenPlanQuotaParser.alibabaCoding(data, now: now)
        XCTAssertEqual(windows.map(\.canonicalProviderKey), ["alibaba-coding-plan", "alibaba-coding-plan"])
        XCTAssertEqual(windows.map(\.label), ["5 hours", "Monthly"])
        XCTAssertEqual(windows.first?.remainingPercent, 75)
        XCTAssertEqual(windows.first?.absoluteRemaining, 75)
        XCTAssertEqual(windows.first?.absoluteLimit, 100)
        XCTAssertEqual(windows.first?.quotaUnit, "requests")
        XCTAssertNotNil(windows.first?.resetAt)
        XCTAssertEqual(windows.last?.status, .exhausted)
        XCTAssertNil(windows.last?.resetAt)
        XCTAssertTrue(TokenPlanQuotaParser.alibaba(data, now: now).isEmpty)
    }

    func testAlibabaCodingPlanRejectsMissingMalformedOrExpiredWindows() {
        for raw in [
            #"{}"#,
            #"{"per5HourPercentage":0.5}"#,
            #"{"per5Hour":{"usedQuota":true,"totalQuota":100}}"#,
            #"{"perWeek":{"usedQuota":1,"totalQuota":0}}"#,
            #"{"perWeek":{"usedQuota":1,"totalQuota":100,"resetTime":1790000000000}}"#,
            #"{"perBillMonth":{"usedQuota":9,"totalQuota":100,"resetTime":"invalid"}}"#,
        ] {
            XCTAssertTrue(TokenPlanQuotaParser.alibabaCoding(Data(raw.utf8), now: now).isEmpty)
        }
    }

    func testNewReadersAreOptInWithoutChangingExistingDefaults() {
        let prefs = QuotaReaderPreferences()
        XCTAssertFalse(prefs.isEnabled("alibaba-token-plan"))
        XCTAssertFalse(prefs.isEnabled("alibaba-coding-plan"))
        XCTAssertFalse(prefs.isEnabled("mimo-token-plan"))
        XCTAssertTrue(prefs.isEnabled("zcode"))
        XCTAssertTrue(QuotaReaderPreferences(enabledByReaderID: ["mimo-token-plan": true]).isEnabled("mimo-token-plan"))
    }
}
