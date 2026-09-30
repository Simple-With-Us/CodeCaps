import Foundation
import Security
import XCTest
@testable import CodeCaps

/// `TokenCache` over fake Keychain calls.  Nothing here reaches the real
/// Keychain, `TokenStore.shared`, or any panel on the owner's screen.
private let server = "https://usage.example.com/api/quota"
private let service = "com.jays.agent-bar.mac.read-token"
private let syncService = "com.jays.agent-bar.mac.sync-token"
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
        for _ in 0..<3 {
            _ = await cache.token(server: server, service: service)
            _ = await cache.token(server: server, service: syncService)
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

    /// A locked login Keychain at the first read looks like any other failure:
    /// its status cannot be told from a partition panel that was about to
    /// appear, so nothing retries it by itself.  Re-Authorize Saved Token is
    /// the way back.
    func testLockedKeychainAtFirstReadIsNotRetried() async {
        let keychain = FakeKeychain(stored: secret, readStatus: errSecInteractionNotAllowed)
        let cache = keychain.cache()
        for _ in 0..<5 {
            let token = await cache.token(server: server, service: service)
            XCTAssertNil(token)
        }
        XCTAssertEqual(keychain.readFlags, [false])
        keychain.setReadStatus(nil)
        let authorized = await cache.readAllowingInteraction(server: server, service: service)
        XCTAssertEqual(authorized, secret)
        XCTAssertEqual(keychain.readFlags, [false, true])
    }

    /// Re-Authorize Saved Token never asks the Keychain for a token this
    /// launch already holds — not after a successful read, and not after a
    /// save.
    func testReauthorizeWithAHeldTokenMakesNoKeychainRead() async throws {
        let keychain = FakeKeychain(stored: secret)
        let changes = ChangeCounter()
        let cache = keychain.cache(changed: { changes.bump() })
        _ = await cache.token(server: server, service: service)
        let afterRead = await cache.readAllowingInteraction(server: server, service: service)
        XCTAssertEqual(afterRead, secret)
        try await cache.save("newer-token", server: server, service: service)
        let afterSave = await cache.readAllowingInteraction(server: server, service: service)
        XCTAssertEqual(afterSave, "newer-token")
        XCTAssertEqual(keychain.readFlags, [false])
        XCTAssertEqual(changes.count, 0, "callers that wait for a token do not need telling")
    }

    /// The read parked behind a panel is answered after its bound.  The token
    /// is held, the model is told so its button clears at once, and pressing
    /// the button afterwards makes no second, interactive request.
    func testLateAnswerClearsTheStateAndNeedsNoInteractiveRead() async throws {
        let keychain = FakeKeychain(stored: secret, holdReads: true)
        let changes = ChangeCounter()
        let cache = keychain.cache(silentRead: 0.05, changed: { changes.bump() })
        let early = await cache.token(server: server, service: service)
        XCTAssertNil(early)
        keychain.releaseReads()
        try await waitUntil { changes.count == 1 }
        let authorized = await cache.readAllowingInteraction(server: server, service: service)
        XCTAssertEqual(authorized, secret)
        XCTAssertEqual(keychain.readFlags, [false])
    }

    /// Re-Authorize Saved Token waits for a silent read that is still running
    /// instead of starting a second Keychain request beside it.
    func testReauthorizeJoinsARunningSilentRead() async throws {
        let keychain = FakeKeychain(stored: secret, holdReads: true)
        let cache = keychain.cache()
        let silent = Task { await cache.token(server: server, service: service) }
        try await waitUntil { keychain.readCount == 1 }
        let reauthorize = Task { await cache.readAllowingInteraction(server: server, service: service) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(keychain.readCount, 1)
        keychain.releaseReads()
        let silentToken = await silent.value
        let reauthorizedToken = await reauthorize.value
        XCTAssertEqual(silentToken, secret)
        XCTAssertEqual(reauthorizedToken, secret)
        XCTAssertEqual(keychain.readFlags, [false])
    }

    /// The owner presses Re-Authorize Saved Token, then Forget while the panel
    /// is still open.  The read that comes back afterwards must not put the
    /// forgotten token back in memory.
    func testForgetDuringReauthorizeIsNotUndone() async throws {
        let keychain = FakeKeychain(stored: secret, readStatus: errSecAuthFailed)
        let cache = keychain.cache()
        _ = await cache.token(server: server, service: service)
        keychain.setReadStatus(nil)
        keychain.setHoldReads(true)
        let reauthorize = Task { await cache.readAllowingInteraction(server: server, service: service) }
        try await waitUntil { keychain.readCount == 2 }
        try await cache.delete(server: server, service: service)
        keychain.releaseReads()
        let revived = await reauthorize.value
        XCTAssertNil(revived)
        let status = await cache.status(server: server, service: service)
        XCTAssertEqual(status, .unavailable)
        let token = await cache.token(server: server, service: service)
        XCTAssertNil(token)
        XCTAssertNil(keychain.stored)
    }

    /// Likewise a save made while the panel is open is newer than that read.
    func testSaveDuringReauthorizeWins() async throws {
        let keychain = FakeKeychain(stored: "old-token", readStatus: errSecAuthFailed)
        let cache = keychain.cache()
        _ = await cache.token(server: server, service: service)
        keychain.setReadStatus(nil)
        keychain.setHoldReads(true)
        let reauthorize = Task { await cache.readAllowingInteraction(server: server, service: service) }
        try await waitUntil { keychain.readCount == 2 }
        try await cache.save(secret, server: server, service: service)
        keychain.releaseReads()
        _ = await reauthorize.value
        let token = await cache.token(server: server, service: service)
        XCTAssertEqual(token, secret)
    }

    // MARK: Writes that do not finish cleanly

    /// The delete went through and the add failed, so the Keychain holds
    /// nothing.  The cache must not keep claiming the old token: the next
    /// launch would find no item, and Re-Authorize could not bring one back.
    func testFailedAddAfterDeleteLeavesTheTokenUnavailable() async {
        let keychain = FakeKeychain(stored: "old-token", addStatus: errSecInteractionNotAllowed)
        let cache = keychain.cache()
        let held = await cache.token(server: server, service: service)
        XCTAssertEqual(held, "old-token")
        do {
            try await cache.save(secret, server: server, service: service)
            XCTFail("a failed add must fail the save")
        } catch {
            XCTAssertEqual(error as? TokenStore.Failure,
                           .write(status: errSecInteractionNotAllowed, service: service))
        }
        XCTAssertNil(keychain.stored)
        let status = await cache.status(server: server, service: service)
        XCTAssertEqual(status, .unavailable)
        let token = await cache.token(server: server, service: service)
        XCTAssertNil(token)
        XCTAssertEqual(keychain.readCount, 1, "nothing is read again to find out")
    }

    /// A save still running at its bound fails for the owner, and the token is
    /// unavailable meanwhile.  When the parked calls do finish, the Keychain
    /// holds the new token, and so does the cache.
    func testSaveThatOutlivesItsBoundIsKeptWhenItFinishes() async throws {
        let keychain = FakeKeychain(stored: "old-token", holdWrites: true)
        let changes = ChangeCounter()
        let cache = keychain.cache(write: 0.05, changed: { changes.bump() })
        _ = await cache.token(server: server, service: service)
        do {
            try await cache.save(secret, server: server, service: service)
            XCTFail("a save past its bound must fail")
        } catch {
            XCTAssertEqual(error as? TokenStore.Failure, .write(status: nil, service: service))
        }
        let midway = await cache.status(server: server, service: service)
        XCTAssertEqual(midway, .unavailable)
        keychain.releaseWrites()
        try await waitUntil { await cache.status(server: server, service: service) == .cached }
        let token = await cache.token(server: server, service: service)
        XCTAssertEqual(token, secret)
        XCTAssertEqual(keychain.stored, secret)
        XCTAssertEqual(changes.count, 1)
        XCTAssertEqual(keychain.readCount, 1)
    }

    /// A save that outlives its bound finishes after a newer one was asked
    /// for.  The newer save, which ran after it, is the one the cache keeps.
    func testNewerSaveBeatsALateOne() async throws {
        let keychain = FakeKeychain(stored: nil, holdWrites: true)
        let cache = keychain.cache(write: 0.05)
        do { try await cache.save("first-token", server: server, service: service); XCTFail("times out") } catch {}
        do { try await cache.save(secret, server: server, service: service); XCTFail("times out") } catch {}
        keychain.releaseWrites()
        try await waitUntil { await cache.status(server: server, service: service) == .cached }
        try await waitUntil { keychain.stored == secret }
        let token = await cache.token(server: server, service: service)
        XCTAssertEqual(token, secret)
        XCTAssertEqual(keychain.operations,
                       ["delete \(service)", "add \(service)", "delete \(service)", "add \(service)"])
    }

    /// Two saves asked for together run one after the other, each delete
    /// followed by its own add, and memory ends up holding what the Keychain
    /// holds.
    func testConcurrentSavesRunOneAfterTheOther() async throws {
        let keychain = FakeKeychain(stored: "old-token", slowWrites: true)
        let cache = keychain.cache()
        async let first: Void = cache.save("first-token", server: server, service: service)
        async let second: Void = cache.save("second-token", server: server, service: service)
        try await first
        try await second
        XCTAssertEqual(keychain.operations,
                       ["delete \(service)", "add \(service)", "delete \(service)", "add \(service)"])
        let token = await cache.token(server: server, service: service)
        XCTAssertEqual(token, keychain.stored)
        XCTAssertEqual(keychain.readCount, 0)
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

    /// A name that merely ends like one of ours is not ours, and a release
    /// build's names are not a `.dev` build's.
    func testOnlyExactOwnNamesAreTouched() async {
        let keychain = FakeKeychain(stored: secret)
        let dev = ["com.jays.agent-bar.mac.dev.read-token", "com.jays.agent-bar.mac.dev.sync-token"]
        let cache = keychain.cache(ownServices: Set(dev))
        for name in ["com.other.app.sync-token", "com.other.app.read-token", service, syncService,
                     "Claude Code-credentials", ""] {
            let silent = await cache.token(server: server, service: name)
            XCTAssertNil(silent, name)
            let interactive = await cache.readAllowingInteraction(server: server, service: name)
            XCTAssertNil(interactive, name)
            do { try await cache.save(secret, server: server, service: name); XCTFail("save must refuse \(name)") } catch {}
            do { try await cache.delete(server: server, service: name); XCTFail("delete must refuse \(name)") } catch {}
        }
        XCTAssertEqual(keychain.operations, [])
        let own = await cache.token(server: server, service: dev[0])
        XCTAssertEqual(own, secret)
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
/// way the Keychain would.  A read answers with what the item held when the
/// read began, even if it is held up afterwards.
private final class FakeKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var item: String?
    private var readStatus: OSStatus?
    private var deleteStatus: OSStatus?
    private var addStatus: OSStatus?
    private var log: [String] = []
    private var flags: [Bool] = []
    private var holdReads: Bool
    private let holdWrites: Bool
    private let slowWrites: Bool
    private let readGate = DispatchSemaphore(value: 0)
    private let writeGate = DispatchSemaphore(value: 0)

    init(stored: String?, readStatus: OSStatus? = nil, deleteStatus: OSStatus? = nil, addStatus: OSStatus? = nil,
         holdReads: Bool = false, holdWrites: Bool = false, slowWrites: Bool = false) {
        item = stored
        self.readStatus = readStatus
        self.deleteStatus = deleteStatus
        self.addStatus = addStatus
        self.holdReads = holdReads
        self.holdWrites = holdWrites
        self.slowWrites = slowWrites
    }

    var readCount: Int { locked { flags.count } }
    var readFlags: [Bool] { locked { flags } }
    var operations: [String] { locked { log } }
    var stored: String? { locked { item } }

    func setReadStatus(_ status: OSStatus?) { locked { readStatus = status } }
    func setDeleteStatus(_ status: OSStatus?) { locked { deleteStatus = status } }
    func setHoldReads(_ hold: Bool) { locked { holdReads = hold } }

    /// Lets every held read, and every later one, finish.
    func releaseReads() {
        locked { holdReads = false }
        for _ in 0..<32 { readGate.signal() }
    }

    /// Lets every held save or delete, and every later one, finish.
    func releaseWrites() {
        for _ in 0..<32 { writeGate.signal() }
    }

    func cache(silentRead: Double = 3,
               write: Double = 3,
               ownServices: Set<String> = [service, syncService],
               changed: @escaping @Sendable () -> Void = {},
               log: @escaping @Sendable (String) -> Void = { _ in }) -> TokenCache {
        TokenCache(calls: calls,
                   bounds: .init(silentRead: silentRead, interactiveRead: 3, write: write),
                   ownServices: ownServices,
                   changed: changed,
                   log: log)
    }

    private var calls: KeychainCalls {
        KeychainCalls(
            copyData: { service, _, allowInteraction in
                let (answer, hold): ((OSStatus, Data?), Bool) = self.locked {
                    self.flags.append(allowInteraction)
                    self.log.append("read \(service)")
                    let answer: (OSStatus, Data?)
                    if let status = self.readStatus {
                        answer = (status, nil)
                    } else if let item = self.item {
                        answer = (errSecSuccess, Data(item.utf8))
                    } else {
                        answer = (errSecItemNotFound, nil)
                    }
                    return (answer, self.holdReads)
                }
                if hold { self.readGate.wait() }
                return answer
            },
            delete: { service, _ in
                if self.holdWrites { self.writeGate.wait() }
                if self.slowWrites { Thread.sleep(forTimeInterval: 0.05) }
                return self.locked {
                    self.log.append("delete \(service)")
                    if let status = self.deleteStatus { return status }
                    guard self.item != nil else { return errSecItemNotFound }
                    self.item = nil
                    return errSecSuccess
                }
            },
            add: { service, _, data in
                if self.slowWrites { Thread.sleep(forTimeInterval: 0.05) }
                return self.locked {
                    self.log.append("add \(service)")
                    if let status = self.addStatus { return status }
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

private final class ChangeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
