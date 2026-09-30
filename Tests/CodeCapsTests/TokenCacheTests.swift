import Foundation
import Security
import XCTest
@testable import CodeCaps

/// `TokenCache` over fake Keychain calls.  Nothing here reaches the real
/// Keychain, `TokenStore.shared`, or any panel on the owner's screen.
private let server = "https://usage.example.com/api/quota"
private let service = "com.jays.agent-bar.mac.read-token"
private let secret = "tok_live_0123456789abcdef"

final class TokenCacheTests: XCTestCase {
    // MARK: Cache

    func testCacheHitMakesNoSecondKeychainRead() async {
        let keychain = FakeKeychain(stored: secret)
        let cache = keychain.cache()
        for _ in 0..<10 {
            let token = await cache.token(server: server, service: service)
            XCTAssertEqual(token, secret)
        }
        XCTAssertEqual(keychain.readCount, 1)
        let status = await cache.status(server: server, service: service)
        XCTAssertEqual(status, .cached)
    }

    /// Each token is its own entry, so the Read Token and the Ingest Token are
    /// each read once, and a new endpoint is read once too.
    func testEachTokenIsReadOncePerLaunch() async {
        let keychain = FakeKeychain(stored: secret)
        let cache = keychain.cache()
        let sync = "com.jays.agent-bar.mac.sync-token"
        for _ in 0..<3 {
            _ = await cache.token(server: server, service: service)
            _ = await cache.token(server: server, service: sync)
            _ = await cache.token(server: "https://other.example.com", service: service)
        }
        XCTAssertEqual(keychain.readCount, 3)
    }

    // MARK: Single-flight

    /// Every request that arrives while the first read runs waits for that
    /// same read instead of starting its own.
    func testConcurrentRequestsShareOneRead() async throws {
        let keychain = FakeKeychain(stored: secret, holdReads: true)
        let cache = keychain.cache()
        let first = Task { await cache.token(server: server, service: service) }
        try await waitUntil { keychain.readCount == 1 }
        let joiners = (0..<8).map { _ in
            Task { await cache.token(server: server, service: service) }
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let midway = await cache.status(server: server, service: service)
        XCTAssertEqual(midway, .reading)
        keychain.releaseReads()
        let firstToken = await first.value
        XCTAssertEqual(firstToken, secret)
        for joiner in joiners {
            let token = await joiner.value
            XCTAssertEqual(token, secret)
        }
        XCTAssertEqual(keychain.readCount, 1)
    }

    // MARK: Failure

    /// A failed read marks the token unavailable — the Re-Authorize Saved
    /// Token state — and no later request asks the Keychain again.
    func testFailedReadNeedsReauthorizationAndIsNeverRetried() async {
        let keychain = FakeKeychain(stored: nil, readStatus: errSecAuthFailed)
        let cache = keychain.cache()
        let firstToken = await cache.token(server: server, service: service)
        XCTAssertNil(firstToken)
        await withTaskGroup(of: String?.self) { group in
            for _ in 0..<20 { group.addTask { await cache.token(server: server, service: service) } }
            for await token in group { XCTAssertNil(token) }
        }
        XCTAssertEqual(keychain.readCount, 1)
        let status = await cache.status(server: server, service: service)
        XCTAssertEqual(status, .unavailable)
        let state = SavedTokenState.resolve(hasSavedFlag: true, silentReadSucceeded: status == .cached)
        XCTAssertTrue(state.needsReauthorization)
    }

    /// A read parked behind a panel returns at its bound, and nothing queues a
    /// second call behind it.
    func testTimedOutReadIsNotRetried() async {
        let keychain = FakeKeychain(stored: secret, holdReads: true)
        let cache = keychain.cache(silentRead: 0.05)
        let started = Date()
        let firstToken = await cache.token(server: server, service: service)
        XCTAssertNil(firstToken)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        for _ in 0..<5 {
            let token = await cache.token(server: server, service: service)
            XCTAssertNil(token)
        }
        XCTAssertEqual(keychain.readCount, 1)
        let status = await cache.status(server: server, service: service)
        XCTAssertEqual(status, .unavailable)
        keychain.releaseReads()
    }

    /// If somebody answers the panel after the bound, the token that read
    /// brings back is kept — still without another Keychain call.
    func testReadAnsweredAfterItsBoundIsKept() async throws {
        let keychain = FakeKeychain(stored: secret, holdReads: true)
        let cache = keychain.cache(silentRead: 0.05)
        let early = await cache.token(server: server, service: service)
        XCTAssertNil(early)
        keychain.releaseReads()
        try await waitUntil { await cache.status(server: server, service: service) == .cached }
        let token = await cache.token(server: server, service: service)
        XCTAssertEqual(token, secret)
        XCTAssertEqual(keychain.readCount, 1)
    }

    // MARK: Save, re-authorize, delete

    func testSaveRefreshesTheCacheWithoutARead() async throws {
        let keychain = FakeKeychain(stored: "old-token")
        let cache = keychain.cache()
        try await cache.save(secret, server: server, service: service)
        let token = await cache.token(server: server, service: service)
        XCTAssertEqual(token, secret)
        XCTAssertEqual(keychain.readCount, 0)
        XCTAssertEqual(keychain.operations, ["delete \(service)", "add \(service)"])
        XCTAssertEqual(keychain.stored, secret)
    }

    /// Saving after a failure clears the Re-Authorize state and replaces the
    /// cached answer, with no retry of the failed read.
    func testSaveAfterAFailureMakesTheTokenReadable() async throws {
        let keychain = FakeKeychain(stored: nil, readStatus: errSecAuthFailed)
        let cache = keychain.cache()
        _ = await cache.token(server: server, service: service)
        try await cache.save(secret, server: server, service: service)
        let token = await cache.token(server: server, service: service)
        XCTAssertEqual(token, secret)
        XCTAssertEqual(keychain.readCount, 1)
    }

    /// A delete an older build's item refuses stops the save: no add, and no
    /// in-place update that would keep that item's access list.  The token
    /// already held stays held.
    func testRefusedDeleteFailsTheSaveAndKeepsTheCache() async {
        let keychain = FakeKeychain(stored: "old-token", deleteStatus: errSecInvalidOwnerEdit)
        let cache = keychain.cache()
        _ = await cache.token(server: server, service: service)
        do {
            try await cache.save(secret, server: server, service: service)
            XCTFail("a refused delete must fail the save")
        } catch {
            XCTAssertEqual(error as? TokenStore.Failure,
                           .write(status: errSecInvalidOwnerEdit, service: service))
        }
        XCTAssertEqual(keychain.operations, ["read \(service)", "delete \(service)"])
        let token = await cache.token(server: server, service: service)
        XCTAssertEqual(token, "old-token")
        XCTAssertEqual(keychain.readCount, 1)
    }

    func testReauthorizeHoldsTheTokenAndStopsSilentReads() async {
        let keychain = FakeKeychain(stored: secret, readStatus: errSecAuthFailed)
        let cache = keychain.cache()
        let silent = await cache.token(server: server, service: service)
        XCTAssertNil(silent)
        keychain.setReadStatus(nil)
        let authorized = await cache.readAllowingInteraction(server: server, service: service)
        XCTAssertEqual(authorized, secret)
        for _ in 0..<5 {
            let token = await cache.token(server: server, service: service)
            XCTAssertEqual(token, secret)
        }
        XCTAssertEqual(keychain.readFlags, [false, true])
    }

    func testFailedReauthorizeLeavesTheTokenUnavailable() async {
        let keychain = FakeKeychain(stored: nil, readStatus: errSecItemNotFound)
        let cache = keychain.cache()
        _ = await cache.token(server: server, service: service)
        let authorized = await cache.readAllowingInteraction(server: server, service: service)
        XCTAssertNil(authorized)
        let status = await cache.status(server: server, service: service)
        XCTAssertEqual(status, .unavailable)
        _ = await cache.token(server: server, service: service)
        XCTAssertEqual(keychain.readFlags, [false, true])
    }

    func testDeleteLeavesNothingToRead() async throws {
        let keychain = FakeKeychain(stored: secret)
        let cache = keychain.cache()
        _ = await cache.token(server: server, service: service)
        try await cache.delete(server: server, service: service)
        let token = await cache.token(server: server, service: service)
        XCTAssertNil(token)
        XCTAssertEqual(keychain.readCount, 1)
        XCTAssertNil(keychain.stored)
    }

    // MARK: Whose items

    /// Claude Code's saved login, or any other app's item, is refused before
    /// any Keychain call is made.
    func testNeverTouchesAnotherAppsItem() async {
        let keychain = FakeKeychain(stored: secret)
        let cache = keychain.cache()
        let claude = "Claude Code-credentials"
        let silent = await cache.token(server: server, service: claude)
        XCTAssertNil(silent)
        let interactive = await cache.readAllowingInteraction(server: server, service: claude)
        XCTAssertNil(interactive)
        do { try await cache.save(secret, server: server, service: claude); XCTFail("save must refuse") } catch {}
        do { try await cache.delete(server: server, service: claude); XCTFail("delete must refuse") } catch {}
        XCTAssertEqual(keychain.operations, [])
    }

    // MARK: Logs

    /// Every path logs something, and nothing it logs carries the token.
    func testTokensNeverReachTheLog() async throws {
        let keychain = FakeKeychain(stored: secret, holdReads: true)
        let sink = LogSink()
        let cache = keychain.cache(silentRead: 0.05, log: { sink.append($0) })
        _ = await cache.token(server: server, service: service) // times out
        keychain.releaseReads()
        try await waitUntil { await cache.status(server: server, service: service) == .cached }
        try await cache.save(secret, server: server, service: service)
        _ = await cache.readAllowingInteraction(server: server, service: service)
        try await cache.delete(server: server, service: service)
        keychain.setDeleteStatus(errSecInvalidOwnerEdit)
        do {
            try await cache.save(secret, server: server, service: service)
        } catch {
            XCTAssertFalse((error as? LocalizedError)?.errorDescription?.contains(secret) ?? false)
        }

        let lines = sink.lines
        XCTAssertGreaterThanOrEqual(lines.count, 6, "\(lines)")
        for line in lines {
            XCTAssertFalse(line.contains(secret), line)
            XCTAssertFalse(line.contains(server), line)
        }
    }

    // MARK: Helpers

    private func waitUntil(timeout: TimeInterval = 3,
                           _ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !(await condition()) {
            guard Date() < deadline else { return XCTFail("condition not met within \(timeout)s") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

/// One generic-password item held in memory, answering the three calls the
/// way the Keychain would.
private final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var item: String?
    private var readStatus: OSStatus?
    private var deleteStatus: OSStatus?
    private var log: [String] = []
    private var flags: [Bool] = []
    private let gate: DispatchSemaphore?

    init(stored: String?, readStatus: OSStatus? = nil, deleteStatus: OSStatus? = nil, holdReads: Bool = false) {
        item = stored
        self.readStatus = readStatus
        self.deleteStatus = deleteStatus
        gate = holdReads ? DispatchSemaphore(value: 0) : nil
    }

    var readCount: Int { locked { flags.count } }
    var readFlags: [Bool] { locked { flags } }
    var operations: [String] { locked { log } }
    var stored: String? { locked { item } }

    func setReadStatus(_ status: OSStatus?) { locked { readStatus = status } }
    func setDeleteStatus(_ status: OSStatus?) { locked { deleteStatus = status } }

    /// Lets every held read, and every later one, finish.
    func releaseReads() {
        for _ in 0..<32 { gate?.signal() }
    }

    func cache(silentRead: Double = 3,
               log: @escaping @Sendable (String) -> Void = { _ in }) -> TokenCache {
        TokenCache(calls: calls, bounds: .init(silentRead: silentRead, interactiveRead: 3, write: 3), log: log)
    }

    private var calls: KeychainCalls {
        KeychainCalls(
            copyData: { service, _, allowInteraction in
                self.locked {
                    self.flags.append(allowInteraction)
                    self.log.append("read \(service)")
                }
                self.gate?.wait()
                return self.locked {
                    if let status = self.readStatus { return (status, nil) }
                    guard let item = self.item else { return (errSecItemNotFound, nil) }
                    return (errSecSuccess, Data(item.utf8))
                }
            },
            delete: { service, _ in
                self.locked {
                    self.log.append("delete \(service)")
                    if let status = self.deleteStatus { return status }
                    guard self.item != nil else { return errSecItemNotFound }
                    self.item = nil
                    return errSecSuccess
                }
            },
            add: { service, _, data in
                self.locked {
                    self.log.append("add \(service)")
                    guard self.item == nil else { return errSecDuplicateItem }
                    self.item = String(data: data, encoding: .utf8)
                    return errSecSuccess
                }
            })
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class LogSink: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ line: String) {
        lock.lock()
        stored.append(line)
        lock.unlock()
    }
}
