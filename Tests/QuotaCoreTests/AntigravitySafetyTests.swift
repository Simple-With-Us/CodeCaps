import Foundation
import XCTest
@testable import QuotaCore

/// Locks in the background-safety rule for the Antigravity quota handoff:
/// CodeCaps may only ever spawn the npm `antigravity-usage` reader with its
/// own saved login, must never spawn a sign-in-capable CLI such as the
/// retired CC-234 `agy` bridge or a look-alike wrapper, and must surface a
/// consent need instead.
final class AntigravitySafetyTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_789_000_000)

    func testCLIKindClassifiesBridgeReaderAndUnknown() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }

        let bridge = try writeExecutable("""
            #!/usr/bin/env python3
            # Temporary CC-234 quota bridge: forwards `quota` to `agy`.
            import subprocess
            """, at: root.appendingPathComponent("bridge"))
        let npm = try installNpmReader(in: root)
        let garbage = try writeExecutable("""
            #!/bin/sh
            echo hello
            """, at: root.appendingPathComponent("garbage"))

        XCTAssertEqual(LocalQuotaReader.antigravityCLIKind(at: bridge), .agyBridge)
        XCTAssertEqual(LocalQuotaReader.antigravityCLIKind(at: npm), .npmReader)
        XCTAssertEqual(LocalQuotaReader.antigravityCLIKind(at: garbage), .unknown)
        XCTAssertEqual(LocalQuotaReader.antigravityCLIKind(at: root.appendingPathComponent("missing").path), .unknown)
    }

    func testLookAlikeWrapperOutsidePackageDirectoryIsNotAReader() throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // Marker text can be copied; only an executable that resolves into an
        // antigravity-usage package directory counts as the npm reader.
        let wrapper = try writeExecutable("""
            #!/usr/bin/env node
            // antigravity-usage CLI entry point
            """, at: root.appendingPathComponent("bin/antigravity-usage"))
        XCTAssertEqual(LocalQuotaReader.antigravityCLIKind(at: wrapper), .unknown)
    }

    func testRunnerNeverSpawnsSignInCapableBridge() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writeExecutable("""
            #!/usr/bin/env python3
            # Temporary CC-234 quota bridge: forwards `quota` to `agy`.
            """, at: root.appendingPathComponent(".local/bin/antigravity-usage"))

        let runner = LocalQuotaReader.makeAntigravityRunner(homeDirectory: root) { _, _, _ in
            XCTFail("background refresh must never spawn a sign-in-capable CLI")
            return Data()
        }
        do {
            _ = try await runner()
            XCTFail("expected an interactiveSignInRequired failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("interactiveSignInRequired"), "unexpected error: \(error)")
        }
    }

    func testRunnerNeverSpawnsLookAlikeWrapper() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try writeExecutable("""
            #!/usr/bin/env node
            // antigravity-usage CLI entry point
            """, at: root.appendingPathComponent(".local/bin/antigravity-usage"))

        let runner = LocalQuotaReader.makeAntigravityRunner(homeDirectory: root) { _, _, _ in
            XCTFail("background refresh must never spawn a look-alike wrapper")
            return Data()
        }
        do {
            _ = try await runner()
            XCTFail("expected an interactiveSignInRequired failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("interactiveSignInRequired"), "unexpected error: \(error)")
        }
    }

    func testRunnerSpawnsNpmReaderOnlyWithSavedLogin() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try installNpmReader(in: root)
        let support = root.appendingPathComponent("Library/Application Support/antigravity-usage")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: support.appendingPathComponent("tokens.json"))

        let calls = Locked<Int>(0)
        let runner = LocalQuotaReader.makeAntigravityRunner(homeDirectory: root) { path, arguments, home in
            XCTAssertEqual(arguments, ["quota", "--json", "--refresh"])
            XCTAssertEqual(home.standardizedFileURL, root.standardizedFileURL)
            XCTAssertTrue(path.hasSuffix(".local/bin/antigravity-usage"))
            calls.withLock { $0 += 1 }
            return Data("{\"models\": []}".utf8)
        }
        _ = try await runner()
        XCTAssertEqual(calls.withLock { $0 }, 1)
    }

    func testRunnerRefusesNpmReaderWithoutSavedLogin() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try installNpmReader(in: root)

        let runner = LocalQuotaReader.makeAntigravityRunner(homeDirectory: root) { _, _, _ in
            XCTFail("no saved login means nothing may be spawned")
            return Data()
        }
        do {
            _ = try await runner()
            XCTFail("expected an interactiveSignInRequired failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("interactiveSignInRequired"), "unexpected error: \(error)")
        }
    }

    func testCoordinatorSharesConcurrentRunsAndCachesSuccess() async {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let clock = Locked<Date>(t0)
        let coordinator = AntigravityRunCoordinator(minimumInterval: 300, date: { clock.withLock { $0 } })
        let runs = Locked<Int>(0)
        let started = Gate()
        let release = Gate()
        let joined = Gate()
        // Registration itself is the join proof: the coordinator reports each
        // caller outside its lock, so no sleep decides when caller two arrives.
        coordinator.onRegister = { joinedRun in if joinedRun { joined.open() } }
        let operation: @Sendable () async throws -> Data = {
            runs.withLock { $0 += 1 }
            started.open()
            await release.wait()
            clock.withLock { $0 = $0.addingTimeInterval(5) }  // the fetch takes 5s
            return Data("ok".utf8)
        }

        // The second caller provably arrives while the first fetch is still
        // blocked: `joined` opens only when perform sees the in-flight run, so
        // sharing is decided by the coordinator, never by timing or luck.
        async let first = coordinator.perform(now: t0, operation: operation)
        await started.wait()
        async let second = coordinator.perform(now: t0, operation: operation)
        await joined.wait()
        release.open()
        let firstOutcome = await first
        let secondOutcome = await second
        let fetchedAt = t0.addingTimeInterval(5)

        XCTAssertEqual(runs.withLock { $0 }, 1, "concurrent callers must share one CLI run")
        for outcome in [firstOutcome, secondOutcome] {
            guard case .fetched(let data, at: let at) = outcome else { return XCTFail("expected fetched, got \(outcome)") }
            XCTAssertEqual(data, Data("ok".utf8))
            XCTAssertEqual(at, fetchedAt, "a fetch is stamped when it completes, not when it was asked for")
        }

        let cached = await coordinator.perform(now: t0.addingTimeInterval(60), operation: operation)
        XCTAssertEqual(runs.withLock { $0 }, 1, "a fresh success must be served from memory within the interval")
        guard case .cached(let data, at: let at) = cached else { return XCTFail("expected cached, got \(cached)") }
        XCTAssertEqual(data, Data("ok".utf8))
        XCTAssertEqual(at, fetchedAt, "cached data must keep its real fetch time")

        _ = await coordinator.perform(now: t0.addingTimeInterval(310), operation: operation)
        XCTAssertEqual(runs.withLock { $0 }, 2, "an expired cache must trigger a fresh run")
    }

    func testJoinerCancellationLeavesTheSharedRunAlive() async {
        let t0 = Date(timeIntervalSince1970: 2_000)
        let clock = Locked<Date>(t0)
        let coordinator = AntigravityRunCoordinator(minimumInterval: 300, date: { clock.withLock { $0 } })
        let started = Gate()
        let release = Gate()
        let joined = Gate()
        coordinator.onRegister = { joinedRun in if joinedRun { joined.open() } }
        let runs = Locked<Int>(0)
        let operation: @Sendable () async throws -> Data = {
            runs.withLock { $0 += 1 }
            started.open()
            // Cancellation-aware: if the shared task is cancelled (the defect
            // this test guards), the wait ends and the operation throws
            // instead of completing as if nothing happened.
            try await withTaskCancellationHandler {
                await release.wait()
            } onCancel: {
                release.open()
            }
            try Task.checkCancellation()
            return Data("ok".utf8)
        }

        async let first = coordinator.perform(now: t0, operation: operation)
        await started.wait()
        let joiner = Task { await coordinator.perform(now: t0, operation: operation) }
        await joined.wait()  // the joiner provably shares the blocked run
        joiner.cancel()
        release.open()

        let firstOutcome = await first
        guard case .fetched(let data, at: _) = firstOutcome else { return XCTFail("expected fetched, got \(firstOutcome)") }
        XCTAssertEqual(data, Data("ok".utf8), "a joining caller's cancellation must not kill the shared run")
        _ = await joiner.value

        let cached = await coordinator.perform(now: t0.addingTimeInterval(60), operation: operation)
        guard case .cached = cached else { return XCTFail("the completed run must still be cached, got \(cached)") }
        XCTAssertEqual(runs.withLock { $0 }, 1, "no second CLI run may appear")
    }

    func testOwnerCancellationStopsTheSharedRunAndCachesNothing() async {
        let t0 = Date(timeIntervalSince1970: 3_000)
        let coordinator = AntigravityRunCoordinator(minimumInterval: 300, date: { t0 })
        let started = Gate()
        let runs = Locked<Int>(0)
        let operation: @Sendable () async throws -> Data = {
            let n = runs.withLock { $0 += 1; return $0 }
            started.open()
            // The first run stands in for a long CLI invocation: it completes
            // only when its task is cancelled, never by timing out the test.
            if n == 1 { try await Task.sleep(nanoseconds: 600_000_000_000) }
            return Data("ok".utf8)
        }

        let owner = Task { await coordinator.perform(now: t0, operation: operation) }
        await started.wait()
        owner.cancel()
        let outcome = await owner.value
        guard case .failed = outcome else { return XCTFail("expected failure after owner cancel, got \(outcome)") }

        let second = await coordinator.perform(now: t0.addingTimeInterval(1), operation: operation)
        guard case .fetched = second else { return XCTFail("expected a fresh run after the cancelled owner, got \(second)") }
        XCTAssertEqual(runs.withLock { $0 }, 2, "a cancelled owner leaves nothing cached; the next call reruns")
    }

    func testStaleJoinerBookkeepingCannotShrinkANewRun() async {
        let t0 = Date(timeIntervalSince1970: 4_000)
        let coordinator = AntigravityRunCoordinator(minimumInterval: 0, date: { t0 })
        let startedA = Gate()
        let releaseA = Gate()
        let startedB = Gate()
        let releaseB = Gate()
        let joinedA = Gate()
        let joinedB = Gate()
        let joinerParked = Gate()
        let holdJoiner = Gate()
        let runs = Locked<Int>(0)
        let joinedCount = Locked<Int>(0)
        coordinator.onRegister = { joinedRun in
            guard joinedRun else { return }
            let n = joinedCount.withLock { $0 += 1; return $0 }
            if n == 1 { joinedA.open() } else { joinedB.open() }
        }
        let parkedCount = Locked<Int>(0)
        coordinator.beforeBookkeeping = { isOwner in
            guard !isOwner else { return }
            let n = parkedCount.withLock { $0 += 1; return $0 }
            if n == 1 {
                joinerParked.open()
                await holdJoiner.wait()
            }
        }
        let operation: @Sendable () async throws -> Data = {
            let n = runs.withLock { $0 += 1; return $0 }
            if n == 1 {
                startedA.open()
                await releaseA.wait()
                return Data("ok-A".utf8)
            }
            startedB.open()
            await releaseB.wait()
            try Task.checkCancellation()
            return Data("ok-B".utf8)
        }

        let ownerA = Task { await coordinator.perform(now: t0, operation: operation) }
        await startedA.wait()
        let joinerA = Task { await coordinator.perform(now: t0, operation: operation) }
        await joinedA.wait()
        releaseA.open()
        // The old joiner's outcome has arrived but it is parked before its
        // bookkeeping; the owner drains and clears the run meanwhile.
        await joinerParked.wait()
        let outcomeA = await ownerA.value
        guard case .fetched = outcomeA else { return XCTFail("expected fetched, got \(outcomeA)") }

        let ownerB = Task { await coordinator.perform(now: t0, operation: operation) }
        await startedB.wait()
        let joinerB = Task { await coordinator.perform(now: t0, operation: operation) }
        await joinedB.wait()

        // The stale joiner now runs its bookkeeping against the new run's
        // counters; it must not shrink them.
        holdJoiner.open()
        _ = await joinerA.value

        // With the counter shrunk, this cancellation would look like the last
        // waiter leaving and would kill the new run under its owner.
        joinerB.cancel()
        releaseB.open()
        let outcomeB = await ownerB.value
        guard case .fetched(let data, at: _) = outcomeB else {
            return XCTFail("stale joiner bookkeeping let a joiner cancel the new run, got \(outcomeB)")
        }
        XCTAssertEqual(data, Data("ok-B".utf8))
        _ = await joinerB.value
        XCTAssertEqual(runs.withLock { $0 }, 2, "the new run must complete exactly once")
    }

    func testJoinerCancellationReturnsPromptly() async {
        let t0 = Date(timeIntervalSince1970: 5_000)
        let coordinator = AntigravityRunCoordinator(minimumInterval: 0, date: { t0 })
        let started = Gate()
        let release = Gate()
        let joined = Gate()
        coordinator.onRegister = { joinedRun in if joinedRun { joined.open() } }
        let operation: @Sendable () async throws -> Data = {
            started.open()
            await release.wait()
            return Data("ok".utf8)
        }

        async let owner = coordinator.perform(now: t0, operation: operation)
        await started.wait()
        let joiner = Task { await coordinator.perform(now: t0, operation: operation) }
        await joined.wait()
        joiner.cancel()
        // The joiner returns at once; awaiting the shared run here would hang
        // until release opens, which this test never does before the check.
        let joinerOutcome = await joiner.value
        guard case .failed(let error) = joinerOutcome, error is CancellationError else {
            return XCTFail("a cancelled joiner must return promptly with CancellationError, got \(joinerOutcome)")
        }

        release.open()
        let ownerOutcome = await owner
        guard case .fetched(let data, at: _) = ownerOutcome else { return XCTFail("expected fetched, got \(ownerOutcome)") }
        XCTAssertEqual(data, Data("ok".utf8), "the shared run still completes for the remaining caller")
    }

    func testCoordinatorNeverCachesOutputTheCallerRejects() async {
        let coordinator = AntigravityRunCoordinator(minimumInterval: 300)
        let runs = Locked<Int>(0)
        let operation: @Sendable () async throws -> Data = {
            runs.withLock { $0 += 1 }
            return Data("not json".utf8)
        }
        let t0 = Date(timeIntervalSince1970: 1_000)
        let first = await coordinator.perform(now: t0, operation: operation, isCacheable: { _ in false })
        guard case .fetched = first else { return XCTFail("expected fetched, got \(first)") }
        let second = await coordinator.perform(now: t0.addingTimeInterval(1), operation: operation, isCacheable: { _ in false })
        guard case .fetched = second else { return XCTFail("expected fetched, got \(second)") }
        XCTAssertEqual(runs.withLock { $0 }, 2, "rejected output must be fetched again, not served from memory")
    }

    func testCoordinatorNeverCachesFailure() async {
        let coordinator = AntigravityRunCoordinator(minimumInterval: 300)
        let runs = Locked<Int>(0)
        struct Boom: Error {}
        let operation: @Sendable () async throws -> Data = {
            runs.withLock { $0 += 1 }
            throw Boom()
        }
        let t0 = Date(timeIntervalSince1970: 1_000)
        let first = await coordinator.perform(now: t0, operation: operation)
        guard case .failed = first else { return XCTFail("expected failure, got \(first)") }
        let second = await coordinator.perform(now: t0.addingTimeInterval(1), operation: operation)
        guard case .failed = second else { return XCTFail("expected failure, got \(second)") }
        XCTAssertEqual(runs.withLock { $0 }, 2, "failures must never be cached")
    }

    func testMissingAntigravityLoginSurfacesConsentInsteadOfSpawning() async throws {
        let root = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try installNpmReader(in: root)

        let reader = LocalQuotaReader(
            homeDirectory: root,
            now: { self.observedAt },
            fetchJSON: { _ in throw URLError(.notConnectedToInternet) },
            // Exercise the real runner factory, but never the process-wide
            // coordinator: another reader's cached payload must not leak in.
            antigravityCoordinator: AntigravityRunCoordinator(minimumInterval: 0)
        )
        let result = await reader.read()
        XCTAssertTrue(result.consentNeeded.contains("google-antigravity"), "expected google-antigravity consent, got \(result.consentNeeded)")
        let issue = result.issues["google-antigravity"]
        XCTAssertNotNil(issue, "expected an Antigravity issue, got \(result.issues)")
        XCTAssertTrue(issue?.contains("sign-in") == true, "issue should explain the one-time sign-in: \(String(describing: issue))")
        XCTAssertFalse(result.windows.contains { $0.providerKey == "google-antigravity" && $0.remainingPercent != nil },
                       "consent-pending provider must not fabricate a reading")
    }

    // MARK: - Fixtures

    private func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-agtest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Lays out the npm global install shape: the real script inside a
    /// directory named `antigravity-usage`, with the bin entry a symlink to
    /// it, matching how npm/homebrew/nvm expose the package.
    @discardableResult
    private func installNpmReader(in home: URL) throws -> String {
        let packageFile = home.appendingPathComponent("lib/node_modules/antigravity-usage/dist/index.js")
        _ = try writeExecutable("""
            #!/usr/bin/env node
            // antigravity-usage CLI entry point
            """, at: packageFile)
        let link = home.appendingPathComponent(".local/bin/antigravity-usage")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: packageFile)
        return link.path
    }

    @discardableResult
    private func writeExecutable(_ contents: String, at url: URL) throws -> String {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }
}

/// Minimal locked box so tests can count calls from @Sendable closures.
/// A one-shot gate for deterministic concurrency tests: `wait()` suspends
/// until `open()` is called, however long that takes on a loaded machine.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in pending { waiter.resume() }
    }

    func wait() async {
        lock.lock()
        if isOpen {
            lock.unlock()
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            lock.unlock()
        }
    }
}

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
