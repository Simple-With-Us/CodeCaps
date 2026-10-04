import XCTest
@testable import CodeCaps
import QuotaCore

@MainActor
final class DataModeTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suite = "com.jays.codecaps.data-mode." + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
        super.tearDown()
    }

    func testDisablingLocalReadInvalidatesPendingResult() async {
        let gate = AsyncGate()
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        model.localReadForTesting = {
            await gate.pause()
            return LocalQuotaResult(windows: [self.window("local")])
        }

        model.refresh()
        await gate.waitUntilEntered()
        let oldRefresh = model.refreshTaskForTesting
        model.setLocalEnabled(false)
        await gate.open()
        await oldRefresh?.value
        let localRefreshFinished = await waitForRefreshToFinish(model)
        XCTAssertTrue(localRefreshFinished, "replacement local-off refresh should finish")

        XCTAssertFalse(model.localEnabled)
        XCTAssertTrue(model.response.windows.isEmpty)
    }

    func testDisablingFleetPullInvalidatesPendingRemoteResult() async {
        defaults.set(false, forKey: "localEnabled")
        defaults.set(true, forKey: "serverEnabled")
        defaults.set("https://quota.example.test/api/quota-windows", forKey: "endpoint")
        let gate = AsyncGate()
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        model.serverFetchForTesting = {
            await gate.pause()
            return QuotaResponse(generatedAt: "test", windows: [self.window("remote", source: "fleet")])
        }

        model.refresh()
        await gate.waitUntilEntered()
        let oldRefresh = model.refreshTaskForTesting
        model.disableServerPull()
        await gate.open()
        await oldRefresh?.value
        let pullRefreshFinished = await waitForRefreshToFinish(model)
        XCTAssertTrue(pullRefreshFinished, "replacement pull-off refresh should finish")

        XCTAssertFalse(model.serverEnabled)
        XCTAssertTrue(model.response.windows.isEmpty)
        XCTAssertTrue(model.fleetWindowGroups.isEmpty)
    }

    func testDisablingPushDuringTokenReadPreventsPublication() async {
        let gate = AsyncGate()
        defaults.set(true, forKey: "syncEnabled")
        defaults.set("https://quota.example.test/api/ingest/usage", forKey: "syncEndpoint")
        defaults.set(true, forKey: "hasSavedSyncToken")
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        model.localResultForTesting = LocalQuotaResult(windows: [window("local")])
        model.syncTokenReadForTesting = {
            await gate.pause()
            return "test-token"
        }
        var published = 0
        model.pushForTesting = { _, _, _, _ in
            published += 1
            return QuotaPublishResult(statusCode: 200, count: 1, message: "sent")
        }

        model.refresh()
        await gate.waitUntilEntered()
        model.disableSync()
        await gate.open()
        await waitForRefreshToFinish(model)

        XCTAssertFalse(model.syncEnabled)
        XCTAssertEqual(published, 0)
    }

    func testManualPushDoesNotProbeLocalSourcesWhenReadersAreDisabled() async {
        defaults.set(false, forKey: "localEnabled")
        defaults.set(true, forKey: "syncEnabled")
        defaults.set("https://quota.example.test/api/ingest/usage", forKey: "syncEndpoint")
        let model = MonitorModel(defaults: defaults)
        var localReads = 0
        var published = 0
        model.localReadForTesting = {
            localReads += 1
            return LocalQuotaResult(windows: [self.window("local")])
        }
        model.pushForTesting = { _, _, _, _ in
            published += 1
            return QuotaPublishResult(statusCode: 200, count: 1, message: "sent")
        }

        let outcome = await model.testAndPushSync(token: "test-token")

        XCTAssertFalse(outcome.success)
        XCTAssertEqual(localReads, 0)
        XCTAssertEqual(published, 0)
    }

    func testSaveAndPushPublishesExactlyOnce() async throws {
        let model = MonitorModel(defaults: defaults)
        model.localResultForTesting = LocalQuotaResult(windows: [window("local")])
        model.syncTokenReadForTesting = { "test-token" }
        var published = 0
        model.pushForTesting = { windows, _, _, _ in
            published += 1
            return QuotaPublishResult(statusCode: 200, count: windows.count, message: "sent")
        }
        let endpoint = "https://quota.example.test/api/ingest/usage"

        try await model.saveSyncSettings(enabled: true, endpoint: endpoint, token: "", format: .usageMonitorV2)
        XCTAssertEqual(published, 0, "saving settings must not publish before the explicit Save & Push action")
        let outcome = await model.testAndPushSync(endpoint: endpoint, token: "test-token")

        XCTAssertTrue(outcome.success)
        XCTAssertEqual(outcome.message, "sent")
        XCTAssertEqual(published, 1)
    }

    func testSavingChangedPushSettingsCancelsPendingPublication() async throws {
        let gate = AsyncGate()
        defaults.set(true, forKey: "syncEnabled")
        defaults.set("https://quota.example.test/api/ingest/usage", forKey: "syncEndpoint")
        defaults.set(true, forKey: "hasSavedSyncToken")
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        model.localResultForTesting = LocalQuotaResult(windows: [window("local")])
        model.syncTokenReadForTesting = {
            await gate.pause()
            return "test-token"
        }
        var published = 0
        model.pushForTesting = { _, _, _, _ in
            published += 1
            return QuotaPublishResult(statusCode: 200, count: 1, message: "sent")
        }

        model.refresh()
        await gate.waitUntilEntered()
        try await model.saveSyncSettings(enabled: false,
                                         endpoint: "https://quota.example.test/api/ingest/usage",
                                         token: "",
                                         format: .usageMonitorV2)
        await gate.open()
        await waitForRefreshToFinish(model)

        XCTAssertFalse(model.syncEnabled)
        XCTAssertEqual(published, 0)
    }

    private func waitForRefreshToFinish(_ model: MonitorModel) async -> Bool {
        for _ in 0..<10_000 where model.isRefreshing {
            try? await Task.sleep(nanoseconds: 100_000)
        }
        return !model.isRefreshing
    }

    private func window(_ id: String, source: String? = nil) -> QuotaWindow {
        QuotaWindow(id: id, provider: "anthropic", providerKey: "anthropic", label: "5h",
                    remainingPercent: 50, occurredAt: ISO8601DateFormatter().string(from: Date()),
                    source: source)
    }
}

private actor AsyncGate {
    private var entered = false
    private var openState = false
    private var enteredWaiter: CheckedContinuation<Void, Never>?
    private var openWaiters: [CheckedContinuation<Void, Never>] = []

    func pause() async {
        entered = true
        enteredWaiter?.resume()
        enteredWaiter = nil
        guard !openState else { return }
        await withCheckedContinuation { continuation in
            openWaiters.append(continuation)
        }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { continuation in
            enteredWaiter = continuation
        }
    }

    func open() {
        openState = true
        let waiters = openWaiters
        openWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}
