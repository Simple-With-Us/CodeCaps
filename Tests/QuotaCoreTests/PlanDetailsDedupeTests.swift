import XCTest
@testable import QuotaCore

/// This Mac's own plan-details window exists twice in a merged response:
/// the local copy (`local-mac:xai:plan-metadata`) and its own push coming
/// back from the server (`xai:plan-metadata`).  Both name the same payload,
/// so the section merge must keep exactly one.
final class PlanDetailsDedupeTests: XCTestCase {
    private func planDetails(id: String) -> QuotaWindow {
        QuotaWindow(id: id, provider: "xai", providerKey: "xai", label: "Plan details",
                    remainingUnknown: true, occurredAt: "2026-10-24T07:00:00Z", source: "test")
    }

    func testALocalPlanDetailsWindowAndItsOwnPushSurviveOnce() {
        let response = QuotaResponse(generatedAt: "2026-10-24T07:01:00Z",
                                     windows: [planDetails(id: "local-mac:xai:plan-metadata"),
                                               planDetails(id: "xai:plan-metadata")],
                                     skipModelTypes: [])
        let sections = response.platformSections(now: Date(timeIntervalSince1970: 1_761_328_860))
        let planWindows = sections.flatMap(\.windows).map(\.window).filter { $0.id.hasSuffix("plan-metadata") }
        XCTAssertEqual(planWindows.count, 1,
                       "the local copy and its own push are one payload, not two rows: \(planWindows.map(\.id))")
    }

    /// The prefix stripping must not merge genuinely different windows:
    /// another machine's reading carries its own id and stays.
    func testADifferentWindowUnderTheSameProviderSurvives() {
        let response = QuotaResponse(generatedAt: "2026-10-24T07:01:00Z",
                                     windows: [planDetails(id: "local-mac:xai:plan-metadata"),
                                               planDetails(id: "xai:plan-metadata"),
                                               planDetails(id: "xai:subscription")],
                                     skipModelTypes: [])
        let sections = response.platformSections(now: Date(timeIntervalSince1970: 1_761_328_860))
        let ids = sections.flatMap(\.windows).map(\.window).map(\.id)
        XCTAssertTrue(ids.contains("xai:subscription"), "an unrelated window is untouched: \(ids)")
        XCTAssertEqual(ids.filter { $0.hasSuffix("plan-metadata") }.count, 1)
    }
}
