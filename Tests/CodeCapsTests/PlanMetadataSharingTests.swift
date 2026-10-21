import XCTest
import QuotaCore
@testable import CodeCaps

@MainActor
final class PlanMetadataSharingTests: XCTestCase {
    func testSettingsSaveUpdatesHandoffAndWidgetWithoutReplacingDetectedPlan() async {
        let suite = "com.jays.codecaps.plan-sharing." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        let window = QuotaWindow(id: "local-mac:openai:primary", provider: "openai", label: "Quota",
                                 remainingPercent: 42, planName: "Plus", occurredAt: ISO8601DateFormatter().string(from: Date()))
        model.injectLocalHistorySourceForTests([window])
        model.injectForTests(sections: QuotaResponse(generatedAt: "", windows: [window]).platformSections())
        var handoff: [QuotaWindow] = []
        var widget: [QuotaWindow] = []
        model.handoffWriteForTesting = { handoff = $0 }
        model.widgetWriteForTesting = { widget = $0 }
        model.setCustomInfo(for: "openai", info: PlatformCustomInfo(planName: "Pro", costUsd: "$200"))
        await model.planMetadataExportTaskForTesting?.value
        XCTAssertEqual(handoff.first?.planName, "Plus")
        XCTAssertEqual(handoff.first?.planMetadata?.userPlanName, "Pro")
        XCTAssertEqual(widget.first?.planMetadata?.userCostUsd, "$200")
        var remote = window
        remote.id = "remote"
        remote.planMetadata = PlanMetadata(detectedPlanName: "Team", customInfo: nil, providerKey: "openai")
        XCTAssertEqual(model.exportedWindows([remote], locallyProduced: false).first?.planMetadata, remote.planMetadata)
    }
    func testRapidSettingsEditsPublishOnlyTheLatestValues() async {
        let suite = "com.jays.codecaps.plan-debounce." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        var writes: [[QuotaWindow]] = []
        model.handoffWriteForTesting = { writes.append($0) }
        model.setCustomInfo(for: "openai", info: .init(planName: "P"))
        model.setCustomInfo(for: "openai", info: .init(planName: "Pro"))
        await model.planMetadataExportTaskForTesting?.value
        XCTAssertEqual(writes.count, 1)
        XCTAssertEqual(writes.first?.first?.planMetadata?.userPlanName, "Pro")
        model.stop()
    }

    func testSettingsReversionGetsNewPersistedRevisionAndEmptyValuesStillExport() async throws {
        let suite = "com.jays.codecaps.plan-revision." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        model.setCustomInfo(for: "openai", info: .init(planName: "A"))
        let first = try XCTUnwrap(model.exportedWindows([]).first?.planMetadata?.userUpdatedAt)
        model.setCustomInfo(for: "openai", info: .init(planName: "B"))
        model.setCustomInfo(for: "openai", info: .init(planName: "A"))
        let last = try XCTUnwrap(model.exportedWindows([]).first?.planMetadata?.userUpdatedAt)
        XCTAssertGreaterThan(last, first)
        let reopened = MonitorModel(defaults: defaults)
        reopened.skipsSnapshotIOForTesting = true
        XCTAssertEqual(reopened.exportedWindows([]).first?.planMetadata?.userUpdatedAt, last)
        model.setCustomInfo(for: "openai", info: .init())
        let cleared = try XCTUnwrap(model.exportedWindows([]).first)
        XCTAssertNil(cleared.planMetadata?.userPlanName)
        XCTAssertNotNil(cleared.planMetadata?.userUpdatedAt)
        XCTAssertNil(cleared.remainingPercent)
        model.stop()
        reopened.stop()
    }

    func testSettingsOnlyProviderExportsUnknownQuotaAndHonorsLocalOff() async {
        let suite = "com.jays.codecaps.plan-only." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        var handoff: [QuotaWindow] = []
        model.handoffWriteForTesting = { handoff = $0 }
        model.setCustomInfo(for: "github-copilot", info: PlatformCustomInfo(planName: "Pro"))
        await model.planMetadataExportTaskForTesting?.value
        XCTAssertEqual(handoff.count, 1)
        XCTAssertNil(handoff.first?.remainingPercent)
        XCTAssertTrue(handoff.first?.remainingUnknown == true)
        XCTAssertEqual(handoff.first?.planMetadata?.userPlanName, "Pro")
        defaults.set(false, forKey: "localEnabled")
        let disabled = MonitorModel(defaults: defaults)
        disabled.skipsSnapshotIOForTesting = true
        XCTAssertTrue(disabled.exportedWindows([]).isEmpty)
    }

}
