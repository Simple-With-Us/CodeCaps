import Foundation
import QuotaCore
import XCTest
@testable import CodeCaps

@MainActor
final class SnapshotWriteDrainTests: XCTestCase {
    func testEmptyQueueDoesNotWait() async {
        let drained = await SnapshotWriteDrain.wait(for: nil, timeout: .seconds(2))
        XCTAssertTrue(drained)
    }

    func testMainActorCompletionRunsBeforeDrainReturns() async {
        var completed = false
        let chain = Task { @MainActor in
            await Task.yield()
            completed = true
        }
        let drained = await SnapshotWriteDrain.wait(for: chain, timeout: .seconds(2))
        XCTAssertTrue(drained)
        XCTAssertTrue(completed)
    }

    func testStopAndFlushWaitForRealQueuedFileAndMainActorCompletion() async throws {
        let name = "cc196-snapshot-tests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(false, forKey: "localEnabled")
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("snapshot.txt")
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        var completion = false
        model.enqueueSnapshotWrite({ try Data("ordered snapshot".utf8).write(to: file) },
                                   completion: { succeeded in completion = succeeded })
        model.stop()
        let drained = await model.flushSnapshotWrites()
        XCTAssertTrue(drained)
        XCTAssertTrue(completion)
        XCTAssertEqual(try String(contentsOf: file), "ordered snapshot")
    }

    func testFlushClosesQueueBeforeSuspendingAndPreservesPriorOrdering() async throws {
        let name = "cc196-closed-queue-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(false, forKey: "localEnabled")
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        var firstCompleted = false
        var lateCompleted = false
        model.enqueueSnapshotWrite({}, completion: { _ in firstCompleted = true })
        let drain = Task { @MainActor in await model.flushSnapshotWrites() }
        while !model.snapshotWritesClosedForTermination { await Task.yield() }
        model.enqueueSnapshotWrite({}, completion: { _ in lateCompleted = true })
        let drained = await drain.value
        XCTAssertTrue(drained)
        XCTAssertTrue(firstCompleted)
        XCTAssertFalse(lateCompleted)
    }

    func testRestartReopensAdmissionAndNextDrainWaitsForNewWrites() async throws {
        let name = "cc196-resume-queue-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.set(false, forKey: "localEnabled")
        defaults.set(false, forKey: SourceRefreshPreference.providerEnabled)
        defaults.set(false, forKey: SourceRefreshPreference.sessionEnabled)
        defer { defaults.removePersistentDomain(forName: name) }
        let model = MonitorModel(defaults: defaults)
        model.skipsSnapshotIOForTesting = true
        model.stop()
        let firstDrained = await model.flushSnapshotWrites()
        XCTAssertTrue(firstDrained)
        XCTAssertTrue(model.snapshotWritesClosedForTermination)
        model.start()
        XCTAssertFalse(model.snapshotWritesClosedForTermination)
        var resumedCompleted = false
        model.enqueueSnapshotWrite({}, completion: { _ in resumedCompleted = true })
        model.stop()
        let secondDrained = await model.flushSnapshotWrites()
        XCTAssertTrue(secondDrained)
        XCTAssertTrue(resumedCompleted)
    }

    func testDeadlineDoesNotJoinStuckWriteAndLateCompletionIsSafe() async {
        var release: CheckedContinuation<Void, Never>?
        var completed = false
        let chain = Task { @MainActor in
            await withCheckedContinuation { release = $0 }
            completed = true
        }
        while release == nil { await Task.yield() }
        let clock = ContinuousClock()
        let start = clock.now
        let drained = await SnapshotWriteDrain.wait(for: chain, timeout: .milliseconds(20))
        XCTAssertFalse(drained)
        XCTAssertLessThan(start.duration(to: clock.now), .seconds(1))
        XCTAssertFalse(completed)
        release?.resume()
        await chain.value
        XCTAssertTrue(completed)
    }
}

final class SnapshotTerminationIntegrationTests: XCTestCase {
    private func source(_ file: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/CodeCaps/" + file))
    }

    func testTerminationDefersReplyUntilAsyncFlushWithoutBlockingMainActor() throws {
        let delegate = try source("AppDelegate.swift")
        XCTAssertTrue(delegate.contains("func applicationShouldTerminate("))
        XCTAssertTrue(delegate.contains("snapshotFlushTask = Task { @MainActor in await model.flushSnapshotWrites() }"))
        XCTAssertTrue(delegate.contains("_ = await flush?.value"))
        XCTAssertFalse(delegate.contains("guard !snapshotTerminationPending"))
        XCTAssertTrue(delegate.contains("_ = await flush?.value\n            snapshotFlushTask = nil\n            sender.reply"))
        XCTAssertTrue(delegate.contains("sender.reply(toApplicationShouldTerminate: true)"))
        XCTAssertTrue(delegate.contains("return .terminateLater"))
        let model = try source("MonitorModel.swift")
        XCTAssertTrue(model.contains("timeout: Duration = .seconds(2)"))
        XCTAssertTrue(model.contains("await SnapshotWriteDrain.wait(for: chain, timeout: timeout)"))
        XCTAssertFalse(model.contains("group.wait("))
        XCTAssertFalse(model.contains("sem.wait("))
    }

    func testDisableQueuesRemovalAndWidgetUsesCompletionTimeOrder() throws {
        let model = try source("MonitorModel.swift")
        let disable = try XCTUnwrap(model.range(of: "func setLocalEnabled("))
        let next = try XCTUnwrap(model.range(of: "func setProviderChecksEnabled("))
        let block = String(model[disable.lowerBound..<next.lowerBound])
        XCTAssertTrue(block.contains("enqueueHandoffWrite(windows: nil)"))
        XCTAssertTrue(model.contains(".set(self.platformOrder, forKey: \"platformOrder\")"))
        XCTAssertFalse(model.contains("let order = platformOrder"))
    }
}
