import XCTest
@testable import QuotaCore

final class PlanDetailsDedupeTests: XCTestCase {
    private func window(_ id: String, producer: String? = nil) -> QuotaWindow {
        QuotaWindow(id: id, provider: "xai", providerKey: "xai", label: "Plan Details",
                    remainingUnknown: true, occurredAt: "2026-10-24T07:00:00Z",
                    source: "test", producerInstanceId: producer)
    }

    func testALocalPlanDetailsWindowAndItsOwnPushSurviveOnce() {
        let local = [window("local-mac:xai:plan-metadata")]
        let split = FleetOrigin.split([window("xai:plan-metadata", producer: "this-mac")], host: "this-mac")
        let adopted = QuotaLocalScope.adoptedOwnPush(split.ownPush, localWindows: local)
        XCTAssertEqual((local + adopted).count, 1)
    }

    func testADifferentWindowUnderTheSameProviderSurvives() {
        let local = [window("local-mac:xai:plan-metadata")]
        let own = [window("xai:plan-metadata"), window("xai:subscription")]
        let adopted = QuotaLocalScope.adoptedOwnPush(own, localWindows: local)
        XCTAssertEqual(adopted.map(\.id), ["xai:subscription"])
    }

    func testAnotherProducersSameIdWindowSurvives() {
        let local = [window("local-mac:xai:plan-metadata")]
        let split = FleetOrigin.split([
            window("xai:plan-metadata", producer: "this-mac"),
            window("xai:plan-metadata", producer: "other-mac")
        ], host: "this-mac")
        let adopted = QuotaLocalScope.adoptedOwnPush(split.ownPush, localWindows: local)
        XCTAssertTrue(adopted.isEmpty)
        XCTAssertEqual(split.groups.flatMap(\.windows).map(\.producerInstanceId), ["other-mac"])
        let response = QuotaResponse(generatedAt: "", windows: local + split.groups.flatMap(\.windows))
        XCTAssertEqual(response.platformSections().first(where: { $0.providerKey == "xai" })?.windows.count, 2)
    }
}
