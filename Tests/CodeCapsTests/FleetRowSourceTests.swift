import XCTest
@testable import CodeCaps
import QuotaCore

/// A provider this Mac does not read locally is filled by the fleet.
///
/// The xAI row is the case that broke:  this Mac reads no xAI quota of its
/// own, so the fleet fills the row, and the fleet carried this Mac's own live
/// SuperGrok Heavy reading under the xAI key.  The merge counted the
/// plan-details window as a local reading and held that live reading out of
/// the row, and the own-push exemption let the copies of two ended periods in
/// beside it, so the row read two windows at zero percent with a due caption
/// (owner, 2026-10-23).
///
/// This drives the real merge, so the row is read rather than argued about.
@MainActor
final class FleetRowSourceTests: XCTestCase {
    func testTheFleetLiveReadingReachesARowThisMacDoesNotReadLocally() async throws {
        let iso = ISO8601DateFormatter()
        let now = Date()
        let producer = QuotaPublisher.producerInstanceId

        func fleetWindow(_ id: String, percent: Double, resetIn: TimeInterval, observedAgo: TimeInterval) -> QuotaWindow {
            QuotaWindow(
                id: id,
                provider: "xAI",
                providerKey: "xai",
                label: "7-day window",
                remainingPercent: percent,
                resetAt: iso.string(from: now.addingTimeInterval(resetIn)),
                window: "weekly",
                occurredAt: iso.string(from: now.addingTimeInterval(-observedAgo)),
                source: "codecaps",
                producerInstanceId: producer
            )
        }

        // All this Mac has for xAI is the plan details, which carry no reading.
        let planDetails = QuotaWindow(
            id: "local-mac:xai:plan-metadata",
            provider: "xAI",
            providerKey: "xai",
            label: "Plan Details",
            remainingUnknown: true,
            occurredAt: iso.string(from: now.addingTimeInterval(-60)),
            source: "CodeCaps Settings"
        )

        // The fleet carries this Mac's own live SuperGrok Heavy reading under
        // the xAI key, and this Mac's copies of two periods that ended.
        let live = fleetWindow("grok:subscription", percent: 89, resetIn: 6 * 86_400, observedAgo: 60)
        let endedOne = fleetWindow("xai-subscription", percent: 0, resetIn: -86_400, observedAgo: 6 * 86_400)
        let endedTwo = fleetWindow("xai:subscription", percent: 0, resetIn: -86_400, observedAgo: 5 * 86_400)

        let local = LocalQuotaResult(windows: [planDetails])
        let payload = QuotaResponse(generatedAt: iso.string(from: now), windows: [live, endedOne, endedTwo])

        let suite = "com.jays.codecaps.fleetrowsource." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "serverEnabled")
        defaults.set("https://usage.jays.services/api/quota-windows", forKey: "endpoint")

        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        model.setSessionFileChecksEnabled(false)
        model.localReadForTesting = { local }
        model.serverFetchForTesting = { payload }

        model.refresh()
        await model.refreshTaskForTesting?.value

        let section = model.response.platformSections(now: model.now)
            .first(where: { $0.providerKey == "xai" })
        XCTAssertNotNil(section, "the xAI row is present")

        let readings = section?.windows.filter { $0.remainingPercent != nil } ?? []
        XCTAssertEqual(readings.count, 1,
                       "the row carries the one live reading, not the copies of ended periods")
        XCTAssertEqual(readings.first?.remainingPercent, 89,
                       "the reading is the live SuperGrok Heavy allowance")
        XCTAssertEqual(readings.first?.window.window, "weekly",
                       "the reading is the weekly window")
    }
}
