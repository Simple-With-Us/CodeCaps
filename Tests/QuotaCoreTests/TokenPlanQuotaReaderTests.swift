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
        XCTAssertEqual(withLocalRead.fallback.map(\.canonicalProviderKey), ["alibaba-token-plan"])
    }

    func testNewReadersAreOptInWithoutChangingExistingDefaults() {
        let prefs = QuotaReaderPreferences()
        XCTAssertFalse(prefs.isEnabled("alibaba-token-plan"))
        XCTAssertFalse(prefs.isEnabled("mimo-token-plan"))
        XCTAssertTrue(prefs.isEnabled("zcode"))
        XCTAssertTrue(QuotaReaderPreferences(enabledByReaderID: ["mimo-token-plan": true]).isEnabled("mimo-token-plan"))
    }
}
