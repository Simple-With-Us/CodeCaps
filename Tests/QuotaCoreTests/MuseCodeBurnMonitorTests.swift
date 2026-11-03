import XCTest
@testable import QuotaCore

final class MuseCodeBurnMonitorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A reading whose window totals `total` tokens, `contributor` of them
    /// on a contributor session; the rest, when any, sit on one standard
    /// session, which is what the burn rule's presence test reads.
    private func report(total: Int, contributor: Int,
                        standardModel: String = "muse-wonder-1.0") -> MuseCodeSessionReport {
        var models: [MuseCodeModelUsage] = []
        var observations: [MuseCodeSessionObservation] = []
        if contributor > 0 {
            models.append(MuseCodeModelUsage(modelId: "muse-spark-1.3-contributor",
                                              tokens: contributor, segmentCount: 1, sessionCount: 1))
            observations.append(MuseCodeSessionObservation(
                sessionId: "s-contributor", snapshotId: "snap-c",
                modelId: "muse-spark-1.3-contributor", totalTokens: contributor,
                segmentKey: "seg-c", observedAt: now))
        }
        if total > contributor {
            models.append(MuseCodeModelUsage(modelId: standardModel, tokens: total - contributor,
                                              segmentCount: 1, sessionCount: 1))
            observations.append(MuseCodeSessionObservation(
                sessionId: "s-standard", snapshotId: "snap-s",
                modelId: standardModel, totalTokens: total - contributor,
                segmentKey: "seg-s", observedAt: now))
        }
        let window = MuseCodeWindowUsage(windowMinutes: 90, totalTokens: total,
                                          contributorTokens: contributor,
                                          contributorShare: total > 0 ? Double(contributor) / Double(total) : nil,
                                          activeSessions: observations.count, models: models)
        return MuseCodeSessionReport(generatedAt: now, windows: [window],
                                       latestObservations: observations,
                                       currentModelObservations: observations.map(MuseCodeSessionModelObservation.init))
    }

    func testBurnFiresOverThresholdWithStandardSessionPresent() {
        let alert = MuseCodeBurnMonitor.evaluateBurn(
            report: report(total: 5_000_000, contributor: 4_000_000),
            thresholdTokens: MuseCodeBurnMonitor.defaultThresholdTokens)
        let burn = try? XCTUnwrap(alert)
        XCTAssertNotNil(burn)
        XCTAssertEqual(burn?.totalTokens, 5_000_000)
        XCTAssertEqual(burn?.standardSessions.map(\.sessionId), ["s-standard"])
        XCTAssertEqual(burn?.standardSessions.map(\.modelId), ["muse-wonder-1.0"])
        XCTAssertTrue(burn?.body.contains("s-standard") == true,
                      "the warning names the standard session present")
        XCTAssertTrue(burn?.body.contains("muse-wonder-1.0") == true,
                      "the warning names the standard model present")
    }

    func testBurnSuppressedOverThresholdWithNoStandardSessions() {
        let report = report(total: 9_000_000, contributor: 9_000_000)
        XCTAssertNil(MuseCodeBurnMonitor.evaluateBurn(
            report: report, thresholdTokens: MuseCodeBurnMonitor.defaultThresholdTokens),
                     "a heavy window with zero standard-model sessions does not fire, however it is shared")
        XCTAssertEqual(MuseCodeBurnMonitor.status(report: report, issue: nil,
                                                   thresholdTokens: 4_000_000),
                       .allContributor(totalTokens: 9_000_000))
    }

    func testBurnSuppressedBelowThresholdWithStandardSessionPresent() {
        let report = report(total: 3_000_000, contributor: 2_000_000)
        XCTAssertNil(MuseCodeBurnMonitor.evaluateBurn(
            report: report, thresholdTokens: MuseCodeBurnMonitor.defaultThresholdTokens),
                     "below the threshold the combined burn rule stays silent; the standard session is the detector kind's event, not this one's")
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
            return XCTFail("an over-threshold window with a standard session is a warning state")
        }
        XCTAssertEqual(alert.totalTokens, 5_000_000)
    }
    func testHistoricalStandardTokensDoNotSatisfyCurrentPresenceWhenHeadModelIsNil() {
        let historical = report(total: 5_000_000, contributor: 4_000_000)
        let current = MuseCodeSessionReport(generatedAt: now, windows: historical.windows,
            latestObservations: historical.latestObservations,
            currentModelObservations: [.init(sessionId: "s-standard", modelId: nil, observedAt: now)])
        XCTAssertNil(MuseCodeBurnMonitor.evaluateBurn(report: current, thresholdTokens: 4_000_000))
        XCTAssertTrue(MuseCodeBurnMonitor.standardSessions(in: current).isEmpty)
        XCTAssertEqual(MuseCodeBurnMonitor.status(report: current, issue: nil, thresholdTokens: 4_000_000),
                       .currentModelsUnknown(totalTokens: 5_000_000))
    }

}
