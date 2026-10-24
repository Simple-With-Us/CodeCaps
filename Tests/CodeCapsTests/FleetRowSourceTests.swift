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

    // MARK: - The file poll rebuild

    /// This Mac's live quota data, measured on Oct 23, 2026.
    ///
    /// The local snapshot holds one xAI window, the plan details, which
    /// carries no reading, and the Grok reading this Mac does have.  The
    /// fleet carries this Mac's own live SuperGrok Heavy reading under the
    /// xAI key, this Mac's own copies of two periods that ended, this Mac's
    /// own copy of the plan details, and the old collector's copies of the
    /// same live period.
    private struct Live {
        let local: LocalQuotaResult
        let server: QuotaResponse

        /// The producer identity of the old collector, the only fleet window
        /// that is not this Mac's own push.
        static let collector = "Mac.Jays.Services"
    }

    private func liveData(now: Date) -> Live {
        let iso = ISO8601DateFormatter()
        let producer = QuotaPublisher.producerInstanceId
        let machine = QuotaPublisher.machineName
        let day: TimeInterval = 86_400
        let collector = Live.collector

        // This Mac's only local xAI window:  the plan details, which carries
        // no reading, so it does not make this Mac a reader of xAI.
        let planDetails = QuotaWindow(
            id: "local-mac:xai:plan-metadata",
            provider: "xai",
            providerKey: "xai",
            label: "Plan Details",
            remainingUnknown: true,
            occurredAt: iso.string(from: now.addingTimeInterval(-60)),
            source: "CodeCaps Settings",
            producerInstanceId: producer,
            machine: machine
        )
        // The Grok reading this Mac does have.
        let grok = QuotaWindow(
            id: "local-mac:grok:subscription",
            provider: "Grok",
            providerKey: "grok",
            label: "1w window",
            remainingPercent: 89,
            resetAt: iso.string(from: now.addingTimeInterval(6 * day)),
            window: "1w",
            occurredAt: iso.string(from: now.addingTimeInterval(-60)),
            source: "Grok",
            producerInstanceId: producer,
            machine: machine
        )
        // This Mac's own live SuperGrok Heavy reading, under the xAI key.
        let live = QuotaWindow(
            id: "grok:subscription",
            provider: "grok",
            providerKey: "xai",
            label: "1w window",
            remainingPercent: 89,
            resetAt: iso.string(from: now.addingTimeInterval(6 * day)),
            window: "7d",
            occurredAt: iso.string(from: now.addingTimeInterval(-60)),
            source: "codecaps",
            producerInstanceId: producer,
            machine: machine
        )
        // This Mac's own copies of two periods that ended.
        let endedOne = QuotaWindow(
            id: "xai-subscription",
            provider: "xai",
            providerKey: "xai",
            label: "1w window",
            remainingPercent: 0,
            resetAt: iso.string(from: now.addingTimeInterval(-2 * day)),
            window: "1w",
            occurredAt: iso.string(from: now.addingTimeInterval(-6 * day)),
            source: "codecaps",
            producerInstanceId: producer,
            machine: machine
        )
        let endedTwo = QuotaWindow(
            id: "xai:subscription",
            provider: "xai",
            providerKey: "xai",
            label: "1w window",
            remainingPercent: 0,
            resetAt: iso.string(from: now.addingTimeInterval(-2 * day)),
            window: "7d",
            occurredAt: iso.string(from: now.addingTimeInterval(-5 * day)),
            source: "codecaps",
            producerInstanceId: producer,
            machine: machine
        )
        // This Mac's own copy of the plan details, coming back from the fleet.
        let planDetailsCopy = QuotaWindow(
            id: "xai:plan-metadata",
            provider: "xai",
            providerKey: "xai",
            label: "Plan Details",
            remainingUnknown: true,
            occurredAt: iso.string(from: now.addingTimeInterval(-60)),
            source: "codecaps",
            producerInstanceId: producer,
            machine: machine
        )
        // The old collector's copies:  two that ended, and the same live
        // period this Mac reads, fresh and resetting with it.
        let collectorEndedOne = QuotaWindow(
            id: "xai:subscription",
            provider: "xai",
            providerKey: "xai",
            label: "7-day window",
            remainingPercent: 65,
            resetAt: iso.string(from: now.addingTimeInterval(-10 * day)),
            window: "weekly",
            occurredAt: iso.string(from: now.addingTimeInterval(-11 * day)),
            source: "cli-chat-proxy.grok.com",
            producerInstanceId: "grok-bot-box",
            machine: "grok-bot-box"
        )
        let collectorEndedTwo = QuotaWindow(
            id: "xai:subscription",
            provider: "xai",
            providerKey: "xai",
            label: "7-day window",
            remainingPercent: 91,
            resetAt: iso.string(from: now.addingTimeInterval(-2 * day)),
            window: "weekly",
            occurredAt: iso.string(from: now.addingTimeInterval(-8 * day)),
            source: "cli-chat-proxy.grok.com",
            producerInstanceId: "grok-bot-vm",
            machine: "grok-bot-vm"
        )
        let collectorLive = QuotaWindow(
            id: "xai:subscription",
            provider: "xai",
            providerKey: "xai",
            label: "7-day window",
            remainingPercent: 89,
            resetAt: iso.string(from: now.addingTimeInterval(6 * day)),
            window: "weekly",
            occurredAt: iso.string(from: now.addingTimeInterval(-15 * 60)),
            source: "cli-chat-proxy.grok.com",
            producerInstanceId: collector,
            machine: collector
        )

        return Live(
            local: LocalQuotaResult(windows: [planDetails, grok]),
            server: QuotaResponse(generatedAt: iso.string(from: now),
                                  windows: [live, endedOne, endedTwo, planDetailsCopy,
                                            collectorEndedOne, collectorEndedTwo, collectorLive])
        )
    }

    private func defaults() -> UserDefaults {
        let suite = "com.jays.codecaps.fleetrowsource." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "serverEnabled")
        defaults.set("https://usage.jays.services/api/quota-windows", forKey: "endpoint")
        return defaults
    }

    /// The file poll rebuilds the local state every minute and overwrites the
    /// response the server refresh merged, so the row has to survive it.
    ///
    /// Owner, Oct 23 2026:  the xAI row read no allowance at all, and the
    /// rebuild was the path that put it back that way a minute after the
    /// refresh had fixed it.  The rebuild counted the local plan details as a
    /// local reading of xAI, which held the fleet's live reading out of the
    /// row exactly as the refresh had stopped doing.
    func testTheFilePollKeepsTheFleetsLiveReadingInTheXAIRow() async throws {
        let live = liveData(now: Date())
        let defaults = defaults()

        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        model.localReadForTesting = { live.local }
        model.serverFetchForTesting = { live.server }

        // The server refresh merges the fleet's live reading into the row.
        model.refresh()
        await model.refreshTaskForTesting?.value

        // The file poll then rebuilds the local state, and it overwrites that
        // merged response with its own.
        var fileReads = 0
        model.sessionFileReadForTesting = {
            fileReads += 1
            return live.local
        }
        model.refreshSessionFiles()
        await model.sessionFileTaskForTesting?.value
        XCTAssertEqual(fileReads, 1, "the file poll ran and rebuilt the local state")

        let section = model.response.platformSections(now: model.now)
            .first(where: { $0.providerKey == "xai" })
        XCTAssertNotNil(section, "the xAI row is present")
        let row = section?.windows ?? []
        let readings = row.filter { $0.remainingPercent != nil }
        XCTAssertEqual(readings.count, 1,
                       "the rebuild keeps the one live reading in the row")
        XCTAssertEqual(readings.first?.remainingPercent, 89,
                       "the reading is the live SuperGrok Heavy allowance")
        XCTAssertEqual(ResetAlarmCadence.periodSeconds(token: readings.first?.window.window,
                                                        label: readings.first?.window.label ?? ""),
                       7 * 86_400,
                       "the reading is the weekly window")
        XCTAssertFalse(row.contains { $0.remainingPercent == 0 },
                       "a copy of a period that ended is not in the row")
        XCTAssertFalse(row.contains { $0.window.producerInstanceId == Live.collector },
                       "the old collector's copy of the same period is not in the row")
    }

    /// The widget's cache publishes one xAI meter for the live period.
    ///
    /// The publisher's rule is a de-duplication rule:  for a provider this
    /// Mac has a window for, only this Mac's own copy is published, because
    /// another producer's copy of the same period is the stale one.  The
    /// collector's fresh copy of the live SuperGrok Heavy period carries the
    /// same allowance and the same reset as this Mac's own reading, so
    /// publishing it too would put a second meter for one period on the
    /// widget, and the two are not collapsed by the widget's per cadence
    /// selection, because one is a seven day window and the other a weekly
    /// one.
    func testTheWidgetSnapshotKeepsOneXAIWindowForTheLivePeriod() async throws {
        let live = liveData(now: Date())
        let defaults = defaults()

        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        model.localReadForTesting = { live.local }
        model.serverFetchForTesting = { live.server }
        var published: [[QuotaWindow]] = []
        model.widgetWriteForTesting = { published.append($0) }

        model.refresh()
        await model.refreshTaskForTesting?.value

        // The file poll republishes the snapshot after it rebuilds the row.
        model.sessionFileReadForTesting = { live.local }
        model.refreshSessionFiles()
        await model.sessionFileTaskForTesting?.value

        let windows = try XCTUnwrap(published.last, "the widget's cache was written")
        let xai = windows.filter { $0.canonicalProviderKey == "xai" }
        let readings = xai.filter { $0.remainingPercent != nil }
        XCTAssertEqual(readings.count, 1,
                       "the widget's cache holds one xAI reading")
        XCTAssertEqual(readings.first?.remainingPercent, 89,
                       "the reading is the live SuperGrok Heavy allowance")
        XCTAssertFalse(xai.contains { $0.producerInstanceId == Live.collector },
                       "the old collector's copy of the same period is not in the widget's cache")
        XCTAssertFalse(xai.contains { $0.remainingPercent == 0 },
                       "a copy of a period that ended is not in the widget's cache")
    }

    /// A window that carries no reading does not claim its provider.
    ///
    /// This Mac's plan details are its own push coming back, and they named the
    /// provider key, so the provider key was taken out of the fleet fallback
    /// and the row was left with no reading at all while the fleet carried a
    /// live one.  Owner 2026-10-23: the Antigravity rows read "unavailable"
    /// beside a live fleet reading for the same provider.
    func testTheFleetsLiveReadingReachesARowThisMacHoldsOnlyPlanDetailsFor() async throws {
        let iso = ISO8601DateFormatter()
        let now = Date()
        let producer = QuotaPublisher.producerInstanceId
        let machine = QuotaPublisher.machineName

        // This Mac's only Antigravity window:  the plan details, which carry
        // no reading, so it does not make this Mac a reader of Antigravity.
        let planDetails = QuotaWindow(
            id: "local-mac:google-antigravity:plan-metadata",
            provider: "Antigravity",
            providerKey: "google-antigravity",
            label: "Plan Details",
            remainingUnknown: true,
            occurredAt: iso.string(from: now.addingTimeInterval(-60)),
            source: "CodeCaps Settings",
            producerInstanceId: producer,
            machine: machine
        )
        // The same plan details coming back from the fleet:  this Mac's own
        // push, with no reading, under the same provider key.
        let planDetailsCopy = QuotaWindow(
            id: "google-antigravity:plan-metadata",
            provider: "Antigravity",
            providerKey: "google-antigravity",
            label: "Plan Details",
            remainingUnknown: true,
            occurredAt: iso.string(from: now.addingTimeInterval(-60)),
            source: "codecaps",
            producerInstanceId: producer,
            machine: machine
        )
        // Another machine's live reading of the same provider.
        let fleetReading = QuotaWindow(
            id: "google-antigravity:weekly",
            provider: "Antigravity",
            providerKey: "google-antigravity",
            label: "7-day window",
            remainingPercent: 100,
            resetAt: iso.string(from: now.addingTimeInterval(6 * 86_400)),
            window: "weekly",
            occurredAt: iso.string(from: now.addingTimeInterval(-60)),
            source: "cli-chat-proxy.grok.com",
            producerInstanceId: "grok-bot-box",
            machine: "grok-bot-box"
        )

        let defaults = defaults()
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        model.localReadForTesting = { LocalQuotaResult(windows: [planDetails]) }
        model.serverFetchForTesting = {
            QuotaResponse(generatedAt: iso.string(from: now),
                          windows: [planDetailsCopy, fleetReading])
        }

        model.refresh()
        await model.refreshTaskForTesting?.value

        let merged = model.response.windows.filter { $0.canonicalProviderKey == "google-antigravity" }
        XCTAssertEqual(merged.filter { $0.id.hasSuffix("plan-metadata") }.count, 1,
                       "local plan details and their own returning push are one payload")
        let readings = merged.filter { $0.remainingPercent != nil }
        XCTAssertEqual(readings.count, 1,
                       "the fleet's live reading reaches the row")
        XCTAssertEqual(readings.first?.remainingPercent, 100,
                       "the reading is the fleet's live one")
        XCTAssertEqual(readings.first?.producerInstanceId, "grok-bot-box",
                       "the reading is the fleet's, not this Mac's plan details")

        // The file poll rebuilds the row and overwrites the merged response, so
        // the same rule has to hold on that path too.
        model.sessionFileReadForTesting = { LocalQuotaResult(windows: [planDetails]) }
        model.refreshSessionFiles()
        await model.sessionFileTaskForTesting?.value

        let rebuilt = model.response.windows.filter { $0.canonicalProviderKey == "google-antigravity" }
        XCTAssertEqual(rebuilt.filter { $0.id.hasSuffix("plan-metadata") }.count, 1,
                       "the file poll also keeps one plan-details payload")
        XCTAssertEqual(rebuilt.filter { $0.remainingPercent != nil }.count, 1,
                       "the file poll keeps the fleet's live reading in the row")
    }
    /// xAI plan metadata survives normalization, so both paths really merge
    /// a local copy with its own returning push rather than only the push.
    func testBothMergePathsDedupePlanMetadataThatSurvivesNormalization() async throws {
        for carriesReading in [false, true] {
            let iso = ISO8601DateFormatter()
            let now = Date()
            let producer = QuotaPublisher.producerInstanceId
            let machine = QuotaPublisher.machineName
            let suffix = carriesReading ? "unknown" : "plan-metadata"
            let local = QuotaWindow(id: "local-mac:xai:\(suffix)", provider: "xai",
                                    providerKey: "xai", label: "Plan Details", remainingUnknown: true,
                                    occurredAt: iso.string(from: now), source: "CodeCaps Settings",
                                    producerInstanceId: producer, machine: machine)
            var pushed = local
            pushed.id = "xai:\(suffix)"
            if carriesReading {
                pushed.remainingPercent = 73
                pushed.remainingUnknown = false
            }
            var foreign = pushed
            foreign.id = "xai:foreign-reading"
            foreign.remainingPercent = 11
            foreign.remainingUnknown = false
            foreign.producerInstanceId = "other-mac"
            foreign.machine = "other-mac"
            let server = QuotaResponse(generatedAt: iso.string(from: now), windows: [pushed, foreign])
            let model = MonitorModel(defaults: defaults())
            model.skipsSnapshotIOForTesting = true
            model.localReadForTesting = { LocalQuotaResult(windows: [local]) }
            model.serverFetchForTesting = { server }
            model.refresh()
            await model.refreshTaskForTesting?.value
            func assertMerge(_ path: String, file: StaticString = #filePath, line: UInt = #line) {
                XCTAssertEqual(model.localWindows.filter { $0.id == local.id }.count, 1,
                               "\(path): the local fixture survives normalization", file: file, line: line)
                let merged = model.response.windows.filter { $0.canonicalProviderKey == "xai" }
                if carriesReading {
                    let readings = merged.filter { $0.hasReading }
                    XCTAssertEqual(readings.map(\.remainingPercent), [73],
                                   "\(path): the own reading wins before foreign fallback", file: file, line: line)
                    XCTAssertEqual(readings.first?.producerInstanceId, producer, file: file, line: line)
                } else {
                    XCTAssertEqual(merged.filter { $0.id.hasSuffix("plan-metadata") }.count, 1,
                                   "\(path): two metadata copies dedupe to one", file: file, line: line)
                }
            }
            assertMerge("refresh")
            model.sessionFileReadForTesting = { LocalQuotaResult(windows: [local]) }
            model.refreshSessionFiles()
            await model.sessionFileTaskForTesting?.value
            assertMerge("file poll")
        }
    }

}
