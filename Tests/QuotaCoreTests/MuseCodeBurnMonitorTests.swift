import XCTest
@testable import QuotaCore

final class MuseCodeBurnMonitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func report(total: Int, contributor: Int,
                        standardModel: String = "muse-wonder-1.0") -> MuseCodeSessionReport {
        var models = [MuseCodeModelUsage(modelId: "muse-spark-1.3-contributor",
                                          tokens: contributor, segmentCount: 1, sessionCount: 1)]
        if total > contributor {
            models.append(MuseCodeModelUsage(modelId: standardModel, tokens: total - contributor,
                                              segmentCount: 1, sessionCount: 1))
        }
        let window = MuseCodeWindowUsage(windowMinutes: 90, totalTokens: total,
                                          contributorTokens: contributor,
                                          contributorShare: total > 0 ? Double(contributor) / Double(total) : nil,
                                          activeSessions: 1, models: models)
        return MuseCodeSessionReport(generatedAt: now, windows: [window])
    }

    func testBurnFiresOverThresholdWithStandardModelsPresent() {
        let alert = MuseCodeBurnMonitor.evaluateBurn(
            report: report(total: 5_000_000, contributor: 4_000_000),
            thresholdTokens: MuseCodeBurnMonitor.defaultThresholdTokens)
        let burn = try? XCTUnwrap(alert)
        XCTAssertNotNil(burn)
        XCTAssertEqual(burn?.totalTokens, 5_000_000)
        XCTAssertEqual(burn?.contributorShare, 0.8)
        XCTAssertEqual(burn?.standardModels.map(\.modelId), ["muse-wonder-1.0"])
        XCTAssertTrue(burn?.body.contains("muse-wonder-1.0") == true,
                      "the warning names the standard models present")
        XCTAssertTrue(burn?.body.contains("1,000,000") == true,
                      "the warning carries the standard model's token count")
    }

    func testBurnSuppressedAtFullContributorShare() {
        let report = report(total: 9_000_000, contributor: 9_000_000)
        XCTAssertNil(MuseCodeBurnMonitor.evaluateBurn(
            report: report, thresholdTokens: MuseCodeBurnMonitor.defaultThresholdTokens))
        XCTAssertNil(MuseCodeBurnMonitor.evaluateContributor(report: report))
        XCTAssertEqual(MuseCodeBurnMonitor.status(report: report, issue: nil,
                                                   thresholdTokens: 4_000_000),
                       .allContributor(totalTokens: 9_000_000))
    }

    func testBurnSuppressedBelowThresholdButContributorFindingStillFires() {
        let report = report(total: 3_000_000, contributor: 2_000_000)
        XCTAssertNil(MuseCodeBurnMonitor.evaluateBurn(
            report: report, thresholdTokens: MuseCodeBurnMonitor.defaultThresholdTokens),
                     "below the threshold the combined burn rule stays silent")
        let contributor = MuseCodeBurnMonitor.evaluateContributor(report: report)
        XCTAssertNotNil(contributor,
                        "the contributor finding is its own event, not a side effect of the burn rule")
        XCTAssertEqual(contributor?.standardModels.map(\.modelId), ["muse-wonder-1.0"])
        XCTAssertEqual(MuseCodeBurnMonitor.status(report: report, issue: nil,
                                                   thresholdTokens: 4_000_000),
                       .belowThreshold(totalTokens: 3_000_000))
    }

    func testBurnSuppressedExactlyAtThreshold() {
        let report = report(total: 4_000_000, contributor: 3_000_000)
        XCTAssertNil(MuseCodeBurnMonitor.evaluateBurn(
            report: report, thresholdTokens: 4_000_000),
                     "exceeds is strict: exactly at the threshold has not exceeded it")
    }

    func testStatusForMissingAndEmptyReports() {
        XCTAssertEqual(MuseCodeBurnMonitor.status(report: nil, issue: "missing",
                                                   thresholdTokens: 4_000_000),
                       .storeUnavailable)
        XCTAssertEqual(MuseCodeBurnMonitor.status(report: report(total: 0, contributor: 0),
                                                   issue: nil, thresholdTokens: 4_000_000),
                       .noActivity)
    }

    func testWarningStatusCarriesTheBurnAlert() {
        let report = report(total: 5_000_000, contributor: 4_000_000)
        guard case .warning(let alert) = MuseCodeBurnMonitor.status(
            report: report, issue: nil, thresholdTokens: 4_000_000) else {
            return XCTFail("an over-threshold mixed window is a warning state")
        }
        XCTAssertEqual(alert.totalTokens, 5_000_000)
    }
}
