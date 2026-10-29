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

    func testAnEmptyLocalCopyDoesNotHideItsReturningReading() {
        let local = [window("local-mac:xai:unknown")]
        var pushed = window("xai:unknown")
        pushed.remainingPercent = 73
        pushed.remainingUnknown = false
        let adopted = QuotaLocalScope.adoptedOwnPush([pushed], localWindows: local)
        XCTAssertEqual(adopted.map(\.remainingPercent), [73])
    }

    func testALocalReadingStillOwnsItsProviderAcrossDistinctWindowIds() {
        var local = window("local-mac:xai:weekly")
        local.remainingPercent = 81
        local.remainingUnknown = false
        var pushed = window("xai:subscription")
        pushed.remainingPercent = 23
        pushed.remainingUnknown = false
        XCTAssertTrue(QuotaLocalScope.adoptedOwnPush([pushed], localWindows: [local]).isEmpty)
    }

    func testOnlyAnAdoptedReadingReplacesItsExactEmptyLocalCopy() {
        let empty = window("local-mac:xai:unknown")
        let distinct = window("local-mac:xai:plan-metadata")
        var reading = window("xai:unknown")
        reading.remainingPercent = 73
        reading.remainingUnknown = false
        XCTAssertEqual(QuotaLocalScope.localWindowsForMerge([empty, distinct], adopted: [reading]).map(\.id),
                       [distinct.id])
        XCTAssertEqual(QuotaLocalScope.localWindowsForMerge([empty], adopted: []).map(\.id), [empty.id])
        XCTAssertEqual(QuotaLocalScope.localWindowsForMerge([empty], adopted: [window("xai:unknown")]).map(\.id), [empty.id])
        var localReading = empty
        localReading.remainingPercent = 81
        localReading.remainingUnknown = false
        XCTAssertEqual(QuotaLocalScope.localWindowsForMerge([localReading], adopted: [reading]).map(\.remainingPercent), [81])
    }

    func testLegacyProducerlessOwnPushSplitsAdoptsAndReplacesItsEmptyCopy() {
        let local = window("local-mac:xai:unknown")
        var legacyPush = window("local-mac:xai:unknown")
        legacyPush.remainingPercent = 73
        legacyPush.remainingUnknown = false
        let split = FleetOrigin.split([legacyPush], host: "injected-host", localWindows: [local])
        XCTAssertEqual(split.ownPush.count, 1)
        XCTAssertTrue(split.groups.isEmpty)
        let adopted = QuotaLocalScope.adoptedOwnPush(split.ownPush, localWindows: [local])
        XCTAssertEqual(adopted.map(\.remainingPercent), [73])
        let merged = QuotaLocalScope.localWindowsForMerge([local], adopted: adopted) + adopted
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.remainingPercent, 73)
        XCTAssertNil(merged.first?.producerInstanceId)
    }
}
