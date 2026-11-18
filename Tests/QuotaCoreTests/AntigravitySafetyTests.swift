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
        let coordinator = AntigravityRunCoordinator(minimumInterval: 300)
        let runs = Locked<Int>(0)
        let operation: @Sendable () async throws -> Data = {
            runs.withLock { $0 += 1 }
            try? await Task.sleep(nanoseconds: 50_000_000)
            return Data("ok".utf8)
        }

        let t0 = Date(timeIntervalSince1970: 1_000)
        async let a = coordinator.perform(now: t0, operation: operation)
        async let b = coordinator.perform(now: t0, operation: operation)
        async let c = coordinator.perform(now: t0, operation: operation)
        let outcomes = await [a, b, c]
        XCTAssertEqual(runs.withLock { $0 }, 1, "concurrent callers must share one CLI run")
        for outcome in outcomes {
            guard case .fetched(let data, at: let at) = outcome else { return XCTFail("expected fetched, got \(outcome)") }
            XCTAssertEqual(data, Data("ok".utf8))
            XCTAssertEqual(at, t0)
        }

        let cached = await coordinator.perform(now: t0.addingTimeInterval(60), operation: operation)
        XCTAssertEqual(runs.withLock { $0 }, 1, "a fresh success must be served from memory within the interval")
        guard case .cached(let data, at: let at) = cached else { return XCTFail("expected cached, got \(cached)") }
        XCTAssertEqual(data, Data("ok".utf8))
        XCTAssertEqual(at, t0, "cached data must keep its real fetch time")

        _ = await coordinator.perform(now: t0.addingTimeInterval(301), operation: operation)
        XCTAssertEqual(runs.withLock { $0 }, 2, "an expired cache must trigger a fresh run")
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
            fetchJSON: { _ in throw URLError(.notConnectedToInternet) }
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
