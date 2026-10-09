import XCTest
@testable import CodeCaps
import QuotaCore

@MainActor
final class SourceRefreshTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "com.jays.codecaps.refresh.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func historyURL() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("codecaps-refresh-\(UUID().uuidString).jsonl")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func codex(_ remaining: Double, at date: Date, account: String = "account-a",
                       source: String = "Codex Session Files") -> QuotaWindow {
        QuotaWindow(id: "local-mac:openai:primary", provider: "Codex", providerKey: "openai",
                    label: "5h", remainingPercent: remaining,
                    occurredAt: ISO8601DateFormatter().string(from: date), source: source,
                    accountKey: account)
    }

    func testDefaultCadencesAndIndependentPreferencesPersist() {
        let settings = defaults()
        let model = MonitorModel(defaults: settings)
        model.skipsSnapshotIOForTesting = true
        XCTAssertTrue(model.providerChecksEnabled)
        XCTAssertTrue(model.sessionFileChecksEnabled)
        XCTAssertEqual(model.providerCheckCadence, .five)
        XCTAssertEqual(model.sessionFileCadence, .one)

        model.providerCheckCadence = .fifteen
        model.sessionFileCadence = .three
        model.setProviderChecksEnabled(false)
        model.setSessionFileChecksEnabled(false)
        let restored = MonitorModel(defaults: settings)
        XCTAssertFalse(restored.providerChecksEnabled)
        XCTAssertFalse(restored.sessionFileChecksEnabled)
        XCTAssertEqual(restored.providerCheckCadence, .fifteen)
        XCTAssertEqual(restored.sessionFileCadence, .three)
    }

    func testUnchangedFilePollDoesNotInvokeProviderOrFleet() async {
        let settings = defaults()
        settings.set(false, forKey: SourceRefreshPreference.providerEnabled)
        let savedHistory = historyURL()
        let model = MonitorModel(defaults: settings, burnRateHistoryURL: savedHistory)
        model.skipsSnapshotIOForTesting = true
        let fixed = Date()
        let result = LocalQuotaResult(windows: [codex(60, at: fixed)])
        var fileReads = 0
        var providerReads = 0
        var serverReads = 0
        var handoffWrites = 0
        var widgetWrites = 0
        model.sessionAccountIDForTesting = { "account-a" }
        model.sessionFileReadForTesting = { fileReads += 1; return result }
        model.localReadForTesting = { providerReads += 1; return nil }
        model.serverFetchForTesting = { serverReads += 1; return QuotaResponse(generatedAt: "") }
        model.handoffWriteForTesting = { _ in handoffWrites += 1 }
        model.widgetWriteForTesting = { _ in widgetWrites += 1 }

        model.refreshSessionFiles()
        await model.sessionFileTaskForTesting?.value
        let first = model.response
        let firstSampleCount = BurnRateMonitor.loadSamples(historyURL: savedHistory).count
        model.refreshSessionFiles()
        await model.sessionFileTaskForTesting?.value

        XCTAssertEqual(fileReads, 2)
        XCTAssertEqual(providerReads, 0)
        XCTAssertEqual(serverReads, 0)
        XCTAssertEqual(model.response, first)
        XCTAssertEqual(firstSampleCount, 1)
        XCTAssertEqual(BurnRateMonitor.loadSamples(historyURL: savedHistory).count, firstSampleCount)
        XCTAssertEqual(handoffWrites, 1)
        XCTAssertEqual(widgetWrites, 1)
    }

    func testDisablingSessionChecksRejectsInFlightResult() async {
        let settings = defaults()
        settings.set(false, forKey: SourceRefreshPreference.providerEnabled)
        let model = MonitorModel(defaults: settings, burnRateHistoryURL: historyURL())
        model.skipsSnapshotIOForTesting = true
        let gate = RefreshGate()
        model.sessionAccountIDForTesting = { "account-a" }
        model.sessionFileReadForTesting = {
            await gate.pause()
            return LocalQuotaResult(windows: [self.codex(50, at: Date())])
        }
        model.refreshSessionFiles()
        await gate.waitUntilEntered()
        let pending = model.sessionFileTaskForTesting
        model.setSessionFileChecksEnabled(false)
        await gate.open()
        await pending?.value
        XCTAssertFalse(model.sessionFileChecksEnabled)
        XCTAssertTrue(model.response.windows.isEmpty)
    }

    func testAccountSwitchRejectsInFlightSessionReading() async {
        let settings = defaults()
        settings.set(false, forKey: SourceRefreshPreference.providerEnabled)
        let model = MonitorModel(defaults: settings, burnRateHistoryURL: historyURL())
        model.skipsSnapshotIOForTesting = true
        let gate = RefreshGate()
        var currentAccount = "account-a"
        model.sessionAccountIDForTesting = { currentAccount }
        model.sessionFileReadForTesting = {
            await gate.pause()
            return LocalQuotaResult(windows: [self.codex(50, at: Date(), account: "account-a")])
        }
        model.refreshSessionFiles()
        await gate.waitUntilEntered()
        currentAccount = "account-b"
        await gate.open()
        await model.sessionFileTaskForTesting?.value
        XCTAssertTrue(model.response.windows.isEmpty)
    }

    func testMasterLocalSwitchClearsFileOnlyDisplay() async {
        let settings = defaults()
        settings.set(false, forKey: SourceRefreshPreference.providerEnabled)
        let model = MonitorModel(defaults: settings, burnRateHistoryURL: historyURL())
        model.skipsSnapshotIOForTesting = true
        model.sessionAccountIDForTesting = { "account-a" }
        model.sessionFileReadForTesting = {
            LocalQuotaResult(windows: [self.codex(60, at: Date())])
        }
        model.refreshSessionFiles()
        await model.sessionFileTaskForTesting?.value
        XCTAssertEqual(model.response.windows.count, 1)
        model.setLocalEnabled(false)
        XCTAssertTrue(model.response.windows.isEmpty)
    }

    func testDisablingFleetPullClearsDisplayWhenProviderChecksOff() async {
        let settings = defaults()
        settings.set(false, forKey: SourceRefreshPreference.providerEnabled)
        settings.set(false, forKey: SourceRefreshPreference.sessionEnabled)
        settings.set(true, forKey: "serverEnabled")
        let model = MonitorModel(defaults: settings)
        model.skipsSnapshotIOForTesting = true
        var accountReads = 0
        model.sessionAccountIDForTesting = { accountReads += 1; return "account-a" }
        model.serverFetchForTesting = {
            let own = QuotaWindow(id: "own:anthropic:5h", provider: "Claude", providerKey: "anthropic",
                                  label: "5h", remainingPercent: 50,
                                  occurredAt: ISO8601DateFormatter().string(from: Date()), source: "CodeCaps",
                                  producerInstanceId: QuotaPublisher.producerInstanceId)
            return QuotaResponse(generatedAt: "test", windows: [own])
        }
        model.refresh()
        await model.refreshTaskForTesting?.value
        XCTAssertEqual(accountReads, 0, "server-only refresh must not read local Codex auth")
        XCTAssertFalse(model.response.windows.isEmpty)
        model.disableServerPull()
        XCTAssertTrue(model.response.windows.isEmpty)
    }

    func testFleetFallbackWindowIsPublishedOnce() async throws {
        let settings = defaults()
        settings.set(true, forKey: "serverEnabled")
        let model = MonitorModel(defaults: settings, burnRateHistoryURL: historyURL())
        model.skipsSnapshotIOForTesting = true
        let iso = ISO8601DateFormatter().string(from: Date())
        let local = QuotaWindow(id: "anthropic:5h", provider: "Claude", providerKey: "anthropic",
                                label: "5h", remainingPercent: 80, occurredAt: iso, source: "Claude")
        let otherMac = QuotaWindow(id: "other:anthropic:5h", provider: "Claude", providerKey: "anthropic",
                                   label: "5h", remainingPercent: 22, occurredAt: iso, source: "CodeCaps",
                                   producerInstanceId: "other-mac-instance", machine: "kitchen-mac")
        let fleet = QuotaWindow(id: "muse:weekly", provider: "Muse", providerKey: "muse-assist",
                                label: "Weekly", remainingPercent: 40, occurredAt: iso,
                                source: "muse-collector",
                                producerInstanceId: "vm-collector-9f3a", machine: "quota-vm")
        model.localResultForTesting = LocalQuotaResult(windows: [local])
        model.serverFetchForTesting = {
            QuotaResponse(generatedAt: "test", windows: [otherMac, fleet])
        }
        var published: [[QuotaWindow]] = []
        model.widgetWriteForTesting = { published.append($0) }

        model.refresh()
        await model.refreshTaskForTesting?.value

        let windows = try XCTUnwrap(published.last)
        XCTAssertEqual(windows.filter { $0.canonicalProviderKey == "muse-assist" }.count, 1,
                       "a fleet-fallback window is already in the merged list and must not be written again")
        XCTAssertEqual(windows.filter { $0.id == "other:anthropic:5h" }.count, 1,
                       "a real other-Mac window is not the fallback duplicate and stays in the cache")
        XCTAssertEqual(windows.filter { $0.id == "anthropic:5h" }.count, 1)
    }

    func testCodexReconciliationRequiresAccountAndNewerEvent() {
        let instant = Date(timeIntervalSince1970: 1_700_000_000)
        let http = codex(60, at: instant, source: "Codex")
        let tie = codex(50, at: instant)
        let newer = codex(45, at: instant.addingTimeInterval(60))
        let wrongAccount = codex(25, at: instant.addingTimeInterval(120), account: "account-b")
        XCTAssertEqual(MonitorModel.reconcileLocalWindows(provider: [http], session: [tie]).first, http)
        XCTAssertEqual(MonitorModel.reconcileLocalWindows(provider: [http], session: [newer]).first, newer)
        XCTAssertEqual(MonitorModel.reconcileLocalWindows(provider: [http], session: [wrongAccount]).first, http)
    }
}

private actor RefreshGate {
    private var entered = false
    private var entryWaiter: CheckedContinuation<Void, Never>?
    private var exitWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        entryWaiter?.resume()
        entryWaiter = nil
        await withCheckedContinuation { exitWaiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entryWaiter = $0 }
    }

    func open() {
        exitWaiter?.resume()
        exitWaiter = nil
    }
}
