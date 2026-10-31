import Foundation
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
        XCTAssertTrue(delegate.contains("_ = await model.flushSnapshotWrites()"))
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
