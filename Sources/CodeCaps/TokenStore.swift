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

    /// Whether `service` names one of CodeCaps's own two items.  The store
    /// refuses every other name before any Keychain call is made, so nothing
    /// here can read, overwrite or delete Claude Code's saved login or any
    /// other app's item.
    static func isOwnService(_ service: String) -> Bool {
        service.hasSuffix(".read-token") || service.hasSuffix(".sync-token")
    }

    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? defaultBundleIdentifier,
                                       category: "keychain")

    /// The app's one token cache.  Tests build their own over fake calls and
    /// never reach this one, so no test touches the real Keychain.
    static let shared = TokenCache(calls: .live) { message in
        // Status codes and service names only, at notice level so they persist
        // in the log store.  `TokenCache` never hands this a token.
        logger.notice("\(message, privacy: .public)")
    }

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
/// every refresh, so one such item could raise a panel each minute and park a
/// thread behind every one of them.  So each token is read at most once:
///
/// - The first request makes one silent, bounded read.  Any request that
///   arrives while it runs waits for that same read.
/// - A token that was read, saved or re-authorized is handed out from memory
///   with no Keychain call at all, for the rest of the launch.
/// - A read that fails or runs past its bound marks the token unavailable,
///   which Settings shows as Re-Authorize Saved Token.  Nothing retries on its
///   own, so the refresh loop can never queue a second call behind a panel
///   nobody has answered.  Only a save or Re-Authorize Saved Token asks the
///   Keychain again.  If the parked call does come back later with the token
///   — somebody answered that panel — it is taken.
/// - A save deletes CodeCaps's own item and adds a fresh one, so the item is
///   always created by the running build and later launches read it silently.
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
    private let log: @Sendable (String) -> Void
    private var entries: [Key: Entry] = [:]
    private var interactive: [Key: Task<Void, Never>] = [:]
    private var attempts: UInt64 = 0

    init(calls: KeychainCalls, bounds: Bounds = Bounds(), log: @escaping @Sendable (String) -> Void) {
        self.calls = calls
        self.bounds = bounds
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
        guard TokenStore.isOwnService(service) else { return nil }
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
        guard TokenStore.isOwnService(service) else { return nil }
        let key = Key(service: service, server: server)
        if let running = interactive[key] {
            await running.value
            return cachedToken(key)
        }
        let attempt = nextAttempt()
        let running = Task { await self.interactiveRead(key, attempt: attempt) }
        interactive[key] = running
        await running.value
        return cachedToken(key)
    }

    func save(_ token: String, server: String, service: String) async throws {
        guard TokenStore.isOwnService(service) else {
            throw TokenStore.Failure.write(status: errSecParam, service: service)
        }
        let calls = calls
        let log = log
        let status: OSStatus? = await Self.bounded(seconds: bounds.write, fallback: nil) {
            let deleted = calls.delete(service, server)
            log("keychain \(service) delete-before-add status \(deleted)")
            guard TokenStore.canAdd(afterDelete: deleted) else { return deleted }
            let added = calls.add(service, server, Data(token.utf8))
            log("keychain \(service) add status \(added)")
            return added
        }
        guard status == errSecSuccess else {
            if status == nil { log("keychain \(service) save timed out after \(bounds.write)s") }
            throw TokenStore.Failure.write(status: status, service: service)
        }
        // A read still in flight, or a late one, finds this entry and leaves it.
        entries[Key(service: service, server: server)] = .cached(token)
    }

    func delete(server: String, service: String) async throws {
        guard TokenStore.isOwnService(service) else {
            throw TokenStore.Failure.write(status: errSecParam, service: service)
        }
        let calls = calls
        let log = log
        let status: OSStatus? = await Self.bounded(seconds: bounds.write, fallback: nil) {
            let deleted = calls.delete(service, server)
            log("keychain \(service) delete status \(deleted)")
            return deleted
        }
        guard let status, status == errSecSuccess || status == errSecItemNotFound else {
            throw TokenStore.Failure.write(status: status, service: service)
        }
        // Nothing is left to read, so nothing will be read.
        entries[Key(service: service, server: server)] = .unavailable(attempt: nextAttempt())
    }

    // MARK: Reads

    private func silentRead(_ key: Key, attempt: UInt64) async {
        let outcome = await read(key, attempt: attempt, allowInteraction: false, seconds: bounds.silentRead)
        // A save, delete or re-authorization that landed meanwhile wins.
        guard case let .reading(current, _)? = entries[key], current == attempt else { return }
        entries[key] = outcome.token.map(Entry.cached) ?? .unavailable(attempt: attempt)
    }

    private func interactiveRead(_ key: Key, attempt: UInt64) async {
        let outcome = await read(key, attempt: attempt, allowInteraction: true, seconds: bounds.interactiveRead)
        interactive[key] = nil
        switch (outcome.token, entries[key]) {
        case (_, .cached?):
            return // A save landed meanwhile, and it is newer.
        case let (token?, _):
            entries[key] = .cached(token)
        case (nil, .reading?):
            return // The silent read still running settles it.
        case (nil, _):
            entries[key] = .unavailable(attempt: attempt)
        }
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
    /// does return after the bound, `late` gets its answer.
    static func bounded<Value: Sendable>(seconds: Double,
                                         fallback: Value,
                                         late: (@Sendable (Value) -> Void)? = nil,
                                         operation: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            DispatchQueue.global(qos: .utility).async {
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
