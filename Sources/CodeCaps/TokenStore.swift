import Foundation
import LocalAuthentication
import os
import Security

/// Tokens are scoped to their server URL and service domain and never stored in preferences.
///
/// Every call here goes through `TokenStore.shared`, a `TokenCache` that asks
/// the Keychain for a token's data at most once per launch.  `TokenCache`
/// explains why.
enum TokenStore {
    /// The identifier a build falls back to when `Bundle.main` has none — a
    /// test host, or the executable run straight out of `.build`.  It is the
    /// release identifier, so nothing about the installed app's items changes.
    static let defaultBundleIdentifier = "com.jays.agent-bar.mac"

    /// Keychain service names are derived from the running bundle identifier.
    /// The release app therefore keeps exactly `com.jays.agent-bar.mac.read-token`
    /// and `.sync-token`, while a `.dev` build reads and writes its own items
    /// and can never overwrite or forget the owner's.
    static func serviceName(suffix: String,
                            bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(trimmed.isEmpty ? defaultBundleIdentifier : trimmed).\(suffix)"
    }

    static let readService = serviceName(suffix: "read-token")
    static let syncService = serviceName(suffix: "sync-token")

    /// The two service names this build owns: its Read Token and its Ingest
    /// Token.  A `.dev` build's names differ from the release app's, so neither
    /// can reach the other's items.
    static var ownServices: Set<String> { [readService, syncService] }

    /// Whether `service` is exactly one of CodeCaps's own two items.  The store
    /// refuses every other name before any Keychain call is made, so nothing
    /// here can read, overwrite or delete Claude Code's saved login, another
    /// app's item, or a service that merely ends the same way.
    static func isOwnService(_ service: String) -> Bool {
        ownServices.contains(service)
    }

    /// Posted, on an arbitrary thread, when a token becomes available without
    /// any caller waiting for it: a read that was parked behind a panel came
    /// back after its bound, or a save that outlived its bound finished.  The
    /// model re-checks its saved-token state so the Re-Authorize button clears.
    static let tokenBecameAvailable = Notification.Name("CodeCapsTokenBecameAvailable")

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? defaultBundleIdentifier,
                                       category: "keychain")

    /// The app's one token cache.  Tests build their own over fake calls and
    /// never reach this one, so no test touches the real Keychain.
    static let shared = TokenCache(calls: .live, changed: {
        NotificationCenter.default.post(name: tokenBecameAvailable, object: nil)
    }, log: { message in
        // Status codes and service names only, at notice level so they persist
        // in the log store.  `TokenCache` never hands this a token.
        logger.notice("\(message, privacy: .public)")
    })

    /// The token this launch already holds, or — the first time it is asked
    /// for — one silent, bounded Keychain read.  A read that fails is not
    /// retried until the owner saves the token again or re-authorizes it.
    static func read(server: String, service: String = readService) async -> String? {
        await shared.token(server: server, service: service)
    }

    /// One read that lets macOS show its own authorization panel, so the owner
    /// can press Always Allow and put this build on the item's access list.
    /// Only ever reached from Re-Authorize Saved Token — never from the refresh
    /// loop, which must stay prompt-free.
    static func readAllowingInteraction(server: String, service: String = readService) async -> String? {
        await shared.readAllowingInteraction(server: server, service: service)
    }

    /// Replaces CodeCaps's own item with one created by this build, and holds
    /// the new token in memory so no read follows.
    static func save(_ token: String, server: String, service: String = readService) async throws {
        try await shared.save(token, server: server, service: service)
    }

    static func delete(server: String, service: String = readService) async throws {
        try await shared.delete(server: server, service: service)
    }

    /// Whether a save may add its fresh item after the delete before it.  A
    /// delete that removed the item, or found none, leaves room for a clean
    /// add.  Any other answer — `errSecInvalidOwnerEdit` from an item an older
    /// build wrote, for one — means the old item is still there, and the save
    /// stops there instead of updating that item in place: an in-place update
    /// keeps the old item's access and partition lists, which is exactly what
    /// makes a later launch's first read raise a panel.
    static func canAdd(afterDelete status: OSStatus) -> Bool {
        status == errSecSuccess || status == errSecItemNotFound
    }

    enum Failure: LocalizedError, Equatable {
        case read
        /// A save or delete that did not succeed.  `status` is the `OSStatus`
        /// macOS returned, or nil when the call was still running at its bound.
        case write(status: OSStatus?, service: String)

        var errorDescription: String? {
            switch self {
            // The old wording named the problem and left the owner with
            // nothing to do about it.  This one points at the button.
            case .read: return "The saved token is unavailable in Keychain.\u{00A0} Re-authorize it in Sources & Fleet, or paste it again."
            case let .write(status, service): return TokenStore.writeFailureMessage(status: status, service: service)
            }
        }
    }

    /// What the owner reads when a save or delete fails.  Every failure used to
    /// say "Unlock your login Keychain", including the ones a locked Keychain
    /// cannot cause, so the real status is named and only the locked case
    /// asks for an unlock.
    static func writeFailureMessage(status: OSStatus?, service: String) -> String {
        let gap = "\u{00A0} "
        guard let status else {
            return "Keychain did not answer within 30 seconds." + gap
                + "Look for a macOS Keychain panel behind other windows, answer it, and try again."
        }
        switch status {
        case errSecInteractionNotAllowed, errSecAuthFailed:
            return "Keychain could not save the token (error \(status))." + gap
                + "Unlock your login Keychain and try again."
        case errSecInvalidOwnerEdit, errSecDuplicateItem:
            return "An older build's saved token is in the way (Keychain error \(status))." + gap
                + "In Keychain Access, delete the item named \(service), then paste the token again."
        case errSecMissingEntitlement:
            return "This build cannot use the Keychain (error \(status))." + gap
                + "Reinstall CodeCaps with script/build_and_run.sh, then paste the token again."
        default:
            let detail = (SecCopyErrorMessageString(status, nil) as String?)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            let reason = detail.isEmpty || detail.hasSuffix(".") ? detail : detail + "."
            return "Keychain could not save the token (error \(status))."
                + (reason.isEmpty ? "" : gap + reason)
        }
    }
}

/// The three Keychain calls the token store makes, behind one seam so tests
/// can hand `TokenCache` fakes and never touch the real Keychain.  `account`
/// is the server URL a token belongs to.
struct KeychainCalls: Sendable {
    /// `SecItemCopyMatching` for one generic password's data.
    var copyData: @Sendable (_ service: String, _ account: String, _ allowInteraction: Bool) -> (status: OSStatus, data: Data?)
    /// `SecItemDelete` of one generic password.
    var delete: @Sendable (_ service: String, _ account: String) -> OSStatus
    /// `SecItemAdd` of one generic password, created by the running build.
    var add: @Sendable (_ service: String, _ account: String, _ data: Data) -> OSStatus

    static let live = KeychainCalls(
        copyData: { service, account, allowInteraction in
            var query = base(service, account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            if !allowInteraction {
                // Ask macOS not to prompt.  `LAContext.interactionNotAllowed`
                // covers LocalAuthentication UI for items with an access control
                // policy, and `kSecUseAuthenticationUIFail` (deprecated) covers
                // the login Keychain's unlock panel.  Neither suppresses the
                // legacy access-list or partition panel: on Sep 30 2026
                // securityd logged `ACL partition mismatch` and `displaying
                // keychain prompt` for a data read that carried both.  What
                // keeps that panel away is `TokenCache` — at most one of these
                // reads per token per launch — and saves that always create the
                // item from the running build, so its partition list carries
                // this build's team ID.
                let context = LAContext()
                context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext as String] = context
                query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
            }
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        },
        delete: { service, account in
            SecItemDelete(base(service, account) as CFDictionary)
        },
        add: { service, account, data in
            var item = base(service, account)
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            return SecItemAdd(item as CFDictionary, nil)
        })

    private static func base(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}

/// CodeCaps's two saved tokens, held in memory for one launch.
///
/// Board item 116f1cd8.  CodeCaps's items live in the file-based login
/// Keychain.  A data read of such an item is checked against the item's
/// access list and partition list, and when the running build's team ID is
/// missing from the partition list — an item written by a differently signed
/// build, for example — securityd puts up its own panel.  No query flag stops
/// it (see `KeychainCalls.live`).  The refresh loop used to make that read on
/// every refresh (every five minutes, plus the refreshes a reset alarm and
/// Settings trigger), so one such item could raise a panel each time and park
/// a thread behind every one of them.  So each token is read at most once:
///
/// - The first request makes one silent, bounded read.  Any request that
///   arrives while it runs waits for that same read.
/// - A token that was read, saved or re-authorized is handed out from memory
///   with no Keychain call at all, for the rest of the launch.  That includes
///   Re-Authorize Saved Token: a token already held is never asked for again.
/// - A read that fails or runs past its bound marks the token unavailable,
///   which Settings shows as Re-Authorize Saved Token.  Nothing retries on its
///   own, so the refresh loop can never queue a second call behind a panel
///   nobody has answered.  Only a save or Re-Authorize Saved Token asks the
///   Keychain again.  If the parked call does come back later with the token
///   — somebody answered that panel — it is taken, and `changed` fires so the
///   button clears at once.
/// - A locked login Keychain at the first read is treated like any other
///   failure.  A status code cannot tell a locked Keychain from a partition
///   panel that was about to appear, so a second silent read after an unlock
///   could raise the very panel this cache exists to avoid.  Re-Authorize
///   Saved Token is the one place macOS may show its unlock panel, and only
///   because the owner pressed it.
/// - A save deletes CodeCaps's own item and adds a fresh one, so the item is
///   always created by the running build and later launches read it silently.
///   Saves and deletes run one after another, in the order they were asked
///   for.  A save that fails after its delete went through, or that outlives
///   its bound, leaves the token unavailable rather than remembering a value
///   the Keychain no longer holds; one that finishes after its bound is taken
///   unless something newer has been asked for since.
///
/// The single-flight gate is per token and opens at the read's bound, not
/// when a stuck `SecItem` call finally returns, so one call parked behind a
/// panel cannot wedge the store.  Tokens never leave memory: none is logged,
/// and none is kept anywhere but here and its own Keychain item.
actor TokenCache {
    /// What this launch knows about one token.
    enum Status: Equatable, Sendable {
        /// Not asked for yet this launch.
        case unknown
        /// The one silent read is running.
        case reading
        /// Held in memory; the Keychain is not asked for it again.
        case cached
        /// The read failed or timed out, or the item was deleted.  Only a save
        /// or Re-Authorize Saved Token asks the Keychain again.
        case unavailable
    }

    /// How long each kind of call may take before its caller moves on.
    struct Bounds: Sendable {
        /// The silent read.  Never waits on a panel somebody is answering.
        var silentRead: Double = 3
        /// Re-Authorize Saved Token: long enough to read and answer the panel.
        var interactiveRead: Double = 60
        /// A save or delete the owner asked for.  macOS may show a panel, and
        /// a shorter bound failed before anyone could answer it.
        var write: Double = 30
    }

    private enum Outcome: Sendable {
        case token(String)
        case failed(OSStatus)
        case timedOut

        var token: String? {
            if case let .token(value) = self { return value }
            return nil
        }
    }

    /// How a save or delete ended.
    private enum WriteOutcome: Sendable {
        /// The Keychain now holds what was asked for.
        case done
        /// The Keychain refused and changed nothing; the old item is intact.
        case refused(OSStatus)
        /// A save's delete went through and its add did not: no item is left.
        case lostItem(OSStatus)
        /// The call was still running at its bound, so the Keychain's state is
        /// not known.
        case timedOut
    }

    private enum Entry {
        case reading(attempt: UInt64, Task<Void, Never>)
        case cached(String)
        case unavailable(attempt: UInt64)
    }

    private struct Key: Hashable {
        let service: String
        let server: String
    }

    private let calls: KeychainCalls
    private let bounds: Bounds
    private let ownServices: Set<String>
    private let changed: @Sendable () -> Void
    private let log: @Sendable (String) -> Void
    /// Saves and deletes run here one at a time, so a write that outlives its
    /// bound cannot interleave its delete and add with the next one's.
    private let writeQueue = DispatchQueue(label: "CodeCaps.TokenCache.writes", qos: .utility)
    private var entries: [Key: Entry] = [:]
    private var interactive: [Key: Task<Void, Never>] = [:]
    /// The newest save or delete asked for, per token.  A read or a late write
    /// that began before it is older than it and gives way.
    private var newestWrite: [Key: UInt64] = [:]
    private var writeTail: Task<Void, Never>?
    private var attempts: UInt64 = 0

    /// `ownServices` is the only set of service names this cache will touch.
    /// `changed` fires when a token becomes available with nobody waiting for
    /// it (see `TokenStore.tokenBecameAvailable`).
    init(calls: KeychainCalls,
         bounds: Bounds = Bounds(),
         ownServices: Set<String> = TokenStore.ownServices,
         changed: @escaping @Sendable () -> Void = {},
         log: @escaping @Sendable (String) -> Void) {
        self.calls = calls
        self.bounds = bounds
        self.ownServices = ownServices
        self.changed = changed
        self.log = log
    }

    func status(server: String, service: String) -> Status {
        switch entries[Key(service: service, server: server)] {
        case nil: return .unknown
        case .reading?: return .reading
        case .cached?: return .cached
        case .unavailable?: return .unavailable
        }
    }

    func token(server: String, service: String) async -> String? {
        guard ownServices.contains(service) else { return nil }
        let key = Key(service: service, server: server)
        switch entries[key] {
        case let .cached(token)?:
            return token
        case .unavailable?:
            return nil
        case let .reading(_, running)?:
            await running.value
            return cachedToken(key)
        case nil:
            let attempt = nextAttempt()
            // Nothing suspends between creating the task and recording it, so
            // the task cannot reach this actor before the entry is in place.
            let running = Task { await self.silentRead(key, attempt: attempt) }
            entries[key] = .reading(attempt: attempt, running)
            await running.value
            return cachedToken(key)
        }
    }

    func readAllowingInteraction(server: String, service: String) async -> String? {
        guard ownServices.contains(service) else { return nil }
        let key = Key(service: service, server: server)
        // The silent read, if one is running, settles first: two Keychain
        // requests for one item never run at once.
        if case let .reading(_, running)? = entries[key] { await running.value }
        // A token this launch already holds needs no panel.  Asking again
        // would be the Keychain data request this cache exists to avoid.
        if let token = cachedToken(key) { return token }
        if let running = interactive[key] {
            await running.value
            return cachedToken(key)
        }
        let attempt = nextAttempt()
        // A token being re-authorized is not also read silently behind it.
        if entries[key] == nil { entries[key] = .unavailable(attempt: attempt) }
        let since = newestWrite[key]
        let running = Task { await self.interactiveRead(key, attempt: attempt, since: since) }
        interactive[key] = running
        await running.value
        return cachedToken(key)
    }

    func save(_ token: String, server: String, service: String) async throws {
        guard ownServices.contains(service) else {
            throw TokenStore.Failure.write(status: errSecParam, service: service)
        }
        try Self.check(await write(Key(service: service, server: server), token: token), service: service)
    }

    func delete(server: String, service: String) async throws {
        guard ownServices.contains(service) else {
            throw TokenStore.Failure.write(status: errSecParam, service: service)
        }
        try Self.check(await write(Key(service: service, server: server), token: nil), service: service)
    }

    private static func check(_ outcome: WriteOutcome, service: String) throws {
        switch outcome {
        case .done: return
        case let .refused(status), let .lostItem(status): throw TokenStore.Failure.write(status: status, service: service)
        case .timedOut: throw TokenStore.Failure.write(status: nil, service: service)
        }
    }

    // MARK: Writes

    /// Saves `token`, or deletes the item when it is nil.  Each write starts
    /// after the one before it has ended, so their results land in the order
    /// they were asked for.
    private func write(_ key: Key, token: String?) async -> WriteOutcome {
        let attempt = nextAttempt()
        newestWrite[key] = attempt
        let previous = writeTail
        let running = Task { () -> WriteOutcome in
            await previous?.value
            return await self.perform(key, token: token, attempt: attempt)
        }
        writeTail = Task { _ = await running.value }
        return await running.value
    }

    private func perform(_ key: Key, token: String?, attempt: UInt64) async -> WriteOutcome {
        let calls = calls
        let log = log
        let (service, server) = (key.service, key.server)
        let kind = token == nil ? "delete" : "save"
        let outcome: WriteOutcome = await Self.bounded(seconds: bounds.write, fallback: .timedOut, queue: writeQueue, late: { late in
            Task { await self.acceptLateWrite(late, key: key, token: token, attempt: attempt) }
        }) {
            let deleted = calls.delete(service, server)
            guard let token else {
                log("keychain \(service) delete status \(deleted)")
                return deleted == errSecSuccess || deleted == errSecItemNotFound ? .done : .refused(deleted)
            }
            log("keychain \(service) delete-before-add status \(deleted)")
            guard TokenStore.canAdd(afterDelete: deleted) else { return .refused(deleted) }
            let added = calls.add(service, server, Data(token.utf8))
            log("keychain \(service) add status \(added)")
            return added == errSecSuccess ? .done : .lostItem(added)
        }
        switch outcome {
        case .done:
            // A read still in flight, or a late one, finds this entry and leaves it.
            entries[key] = token.map(Entry.cached) ?? .unavailable(attempt: nextAttempt())
        case .refused:
            break // Nothing changed, so what this launch holds is still true.
        case .lostItem:
            entries[key] = .unavailable(attempt: nextAttempt())
        case .timedOut:
            log("keychain \(service) \(kind) timed out after \(bounds.write)s")
            entries[key] = .unavailable(attempt: nextAttempt())
        }
        return outcome
    }

    /// A save or delete that finished after its bound.  Taken only while nothing
    /// newer has been asked for since it began.
    private func acceptLateWrite(_ outcome: WriteOutcome, key: Key, token: String?, attempt: UInt64) {
        guard newestWrite[key] == attempt, case .done = outcome else { return }
        entries[key] = token.map(Entry.cached) ?? .unavailable(attempt: nextAttempt())
        log("keychain \(key.service) write finished after its bound")
        if token != nil { changed() }
    }

    // MARK: Reads

    private func silentRead(_ key: Key, attempt: UInt64) async {
        let outcome = await read(key, attempt: attempt, allowInteraction: false, seconds: bounds.silentRead)
        // A save, delete or re-authorization that landed meanwhile wins.
        guard case let .reading(current, _)? = entries[key], current == attempt else { return }
        entries[key] = outcome.token.map(Entry.cached) ?? .unavailable(attempt: attempt)
    }

    private func interactiveRead(_ key: Key, attempt: UInt64, since: UInt64?) async {
        let outcome = await read(key, attempt: attempt, allowInteraction: true, seconds: bounds.interactiveRead)
        interactive[key] = nil
        // A save or Forget asked for while the panel was open is newer than
        // this read, and its result stands: a forgotten token is not put back.
        guard newestWrite[key] == since else { return }
        if case .cached? = entries[key] { return }
        entries[key] = outcome.token.map(Entry.cached) ?? .unavailable(attempt: attempt)
    }

    private func read(_ key: Key, attempt: UInt64, allowInteraction: Bool, seconds: Double) async -> Outcome {
        let calls = calls
        let kind = allowInteraction ? "interactive" : "silent"
        let outcome: Outcome = await Self.bounded(seconds: seconds, fallback: .timedOut, late: { late in
            Task { await self.acceptLate(late, key: key, attempt: attempt) }
        }) {
            let (status, data) = calls.copyData(key.service, key.server, allowInteraction)
            guard status == errSecSuccess else { return .failed(status) }
            guard let data, let token = String(data: data, encoding: .utf8) else { return .failed(errSecDecode) }
            return .token(token)
        }
        switch outcome {
        case .token: log("keychain \(key.service) \(kind) read status \(errSecSuccess)")
        case let .failed(status): log("keychain \(key.service) \(kind) read status \(status)")
        case .timedOut: log("keychain \(key.service) \(kind) read timed out after \(seconds)s")
        }
        return outcome
    }

    /// A read that came back after its bound.  Taken only while nothing newer
    /// has happened to the token since that read began.
    private func acceptLate(_ outcome: Outcome, key: Key, attempt: UInt64) {
        guard let token = outcome.token else { return }
        switch entries[key] {
        case let .unavailable(since)? where since == attempt: break
        case let .reading(since, _)? where since == attempt: break
        default: return
        }
        entries[key] = .cached(token)
        log("keychain \(key.service) read answered after its bound; token held")
        changed()
    }

    private func cachedToken(_ key: Key) -> String? {
        if case let .cached(token)? = entries[key] { return token }
        return nil
    }

    private func nextAttempt() -> UInt64 {
        attempts += 1
        return attempts
    }

    // MARK: Bounding

    /// Runs a blocking Keychain call off the caller's thread and gives up on
    /// it at `seconds`.  A `SecItem` call can block well past that — waiting
    /// on a panel nobody has answered — and the caller moves on with
    /// `fallback`, costing one parked thread and nothing else.  When the call
    /// does return after the bound, `late` gets its answer.  Calls handed the
    /// same serial `queue` run one at a time, in the order they were handed in.
    static func bounded<Value: Sendable>(seconds: Double,
                                         fallback: Value,
                                         queue: DispatchQueue = .global(qos: .utility),
                                         late: (@Sendable (Value) -> Void)? = nil,
                                         operation: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            queue.async {
                let value = operation()
                if !completion.finish(value) { late?(value) }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) {
                completion.finish(fallback)
            }
        }
    }

    private final class Completion<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?
        init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }

        /// Resumes the caller with `value`, or returns false when it was
        /// already resumed.
        @discardableResult
        func finish(_ value: Value) -> Bool {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            guard let pending else { return false }
            pending.resume(returning: value)
            return true
        }
    }
}

/// What a settings group should say about a token it believes is saved.  A flag
/// recording that one was saved, plus a silent read that failed or timed out
/// this launch — most often because this build's code identity is not on the
/// Keychain item's access list, which is what rebuilding under a different
/// signature does — means the owner has to act.
enum SavedTokenState: Equatable {
    /// Nothing is saved for this group.
    case none
    /// Saved, and this build holds it.
    case readable
    /// Saved, but unreadable until the owner authorizes this build once or
    /// pastes the token again.  `TokenCache` does not retry on its own.
    case unreadable

    static func resolve(hasSavedFlag: Bool, silentReadSucceeded: Bool) -> SavedTokenState {
        guard hasSavedFlag else { return .none }
        return silentReadSucceeded ? .readable : .unreadable
    }

    /// Whether the group shows the caption and the Re-Authorize Saved Token button.
    var needsReauthorization: Bool { self == .unreadable }
}
