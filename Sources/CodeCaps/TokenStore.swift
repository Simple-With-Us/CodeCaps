import Foundation
import LocalAuthentication
import os
import Security

/// Tokens are scoped to their server URL and service domain and never stored in preferences.
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

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? defaultBundleIdentifier,
                                    category: "keychain")

    /// How long a Keychain call may take, and whether it may wait behind a call
    /// already in flight.
    private enum Bound {
        /// The refresh loop's read.  Never prompts, and never queues behind a
        /// panel somebody is still answering.
        case silentRead
        /// A save or a delete the owner asked for.  macOS may put up its own
        /// authorization panel, and the old three second bound returned
        /// `errSecInteractionNotAllowed` before anyone could answer it.
        case userInitiated
        /// The single read behind Re-Authorize Saved Token.
        case interactiveRead

        var seconds: Double {
            switch self {
            case .silentRead: return 3
            // Long enough for someone to read and answer an authorization
            // panel, short enough that a wedged Keychain does not leave the
            // Save button spinning forever.  With a stable signature no panel
            // appears at all, so this bound is the unhappy path only.
            case .userInitiated: return 30
            case .interactiveRead: return 60
            }
        }
    }

    static func read(server: String, service: String = readService) async -> String? {
        await bounded(nil, .silentRead) {
            readSynchronously(server: server, service: service, allowInteraction: false)
        }
    }

    /// One read that lets macOS show its own authorization panel, so the owner
    /// can press Always Allow and put this build on the item's access list.
    /// Only ever reached from Re-Authorize Saved Token — never from the refresh
    /// loop, which must stay prompt-free.
    static func readAllowingInteraction(server: String, service: String = readService) async -> String? {
        await bounded(nil, .interactiveRead) {
            readSynchronously(server: server, service: service, allowInteraction: true)
        }
    }

    private static func readSynchronously(server: String, service: String, allowInteraction: Bool) -> String? {
        var query = base(server, service: service)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowInteraction {
            // Ask macOS not to prompt.  Both keys are set, because they cover
            // different dialogs: `LAContext.interactionNotAllowed` suppresses
            // LocalAuthentication UI, but only for an item carrying an access
            // control policy — these are added with none, so on macOS they
            // resolve against the file-based login Keychain, whose unlock panel
            // is governed by `kSecUseAuthenticationUIFail` instead (deprecated).
            // Neither key suppresses the legacy ACL/partition panel: on
            // Sep 30 2026 securityd logged `ACL partition mismatch` and
            // `displaying keychain prompt` for a data read that carried both.
            // That panel appears whenever this build's team ID is missing from
            // the item's partition list, for example an item written by a
            // differently signed build.  The refresh loop still makes this
            // read, so it can raise that panel; board item 116f1cd8 tracks
            // moving it off the legacy Keychain or caching the token.
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if allowInteraction {
            log.notice("keychain interactive read status \(status, privacy: .public)")
        }
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String, server: String, service: String = readService) async throws {
        let status = await bounded(nil as OSStatus?, .userInitiated) {
            saveSynchronously(token, server: server, service: service)
        }
        guard status == errSecSuccess else { throw Failure.write(status: status, service: service) }
    }

    /// Delete, then add; and when the delete is refused, update in place.
    ///
    /// Delete-then-add is preferred because the rewritten item carries this
    /// build's own access list instead of an older build's.  Measured on
    /// 2026-09-17 with two differently signed builds, `SecItemDelete` on the
    /// other build's item returned `errSecSuccess` with no panel.
    ///
    /// It does not always.  On 2026-09-25 the owner's Ingest Token item, first
    /// written on 2026-09-15 by an ad-hoc AgentBar build, refused the delete
    /// with `errSecInvalidOwnerEdit` (-25244): the item's owner entry trusts no
    /// application, and none of the builds on its access list is this one.
    /// The add then failed with `errSecDuplicateItem` (-25299), because the old
    /// item was still there, and the owner was told to unlock a Keychain that
    /// was already unlocked.  Replacing only the item's data needs the
    /// encrypt authorization, which that same access list grants to any
    /// application, so the update is the way through.  It asks macOS not to
    /// prompt (`kSecUseAuthenticationUIFail`), but that key does not suppress
    /// every legacy access-list or partition panel — a probe of this exact
    /// item still raised one.  On a save the owner started that is
    /// acceptable: a panel left unanswered ends in the 30 second timeout
    /// message instead of a silent hang.
    private static func saveSynchronously(_ token: String, server: String, service: String) -> OSStatus {
        let query = base(server, service: service)
        let data = Data(token.utf8)
        // Status codes only, at notice level so they persist in the log store.
        // Nothing here ever logs a token.
        let deleted = SecItemDelete(query as CFDictionary)
        log.notice("keychain delete-before-add status \(deleted, privacy: .public)")
        guard shouldUpdateInPlace(afterDelete: deleted) else {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            log.notice("keychain add status \(added, privacy: .public)")
            return added
        }
        var match = query
        match[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let updated = SecItemUpdate(match as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        log.notice("keychain update-in-place status \(updated, privacy: .public)")
        // The delete's refusal is the more useful thing to report when the
        // update fails too: it is what the owner has to clear.
        return updated == errSecSuccess ? updated : deleted
    }

    /// A delete that removed the item, or found none, leaves room for a clean
    /// add.  Any other answer means the old item is still there, so an add
    /// could only collide with it.
    static func shouldUpdateInPlace(afterDelete status: OSStatus) -> Bool {
        status != errSecSuccess && status != errSecItemNotFound
    }

    static func delete(server: String, service: String = readService) async throws {
        let status = await bounded(nil as OSStatus?, .userInitiated) {
            let deleted = SecItemDelete(base(server, service: service) as CFDictionary)
            log.notice("keychain delete status \(deleted, privacy: .public)")
            return deleted
        }
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.write(status: status, service: service)
        }
    }

    /// Runs a Keychain call with a deadline, and deliberately without a shared
    /// gate.  A `SecItem` call can block well past its bound — waiting on an
    /// authorization panel nobody has answered yet — and a semaphore shared
    /// across every call turns that one stuck call into a token store that
    /// never works again: each later call waits for a signal that is never
    /// sent, so a save fails before it runs and there is nothing in the log to
    /// say why.  Without the gate a stuck call costs one parked thread and
    /// nothing else, and the `SecItem` functions are themselves thread-safe.
    private static func bounded<Value: Sendable>(_ fallback: Value,
                                                 _ bound: Bound,
                                                 operation: @escaping @Sendable () -> Value) async -> Value {
        await withCheckedContinuation { continuation in
            let completion = Completion(continuation)
            DispatchQueue.global(qos: .utility).async { completion.finish(operation()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + bound.seconds) {
                completion.finish(fallback)
            }
        }
    }

    private final class Completion<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Never>?
        init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
        func finish(_ value: Value) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: value)
        }
    }

    private static func base(_ server: String, service: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: server]
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

/// What a settings group should say about a token it believes is saved.  A flag
/// recording that one was saved, plus a silent read that came back empty, means
/// this build's code identity is not on the Keychain item's access list — which
/// is exactly what rebuilding under a different signature does.
enum SavedTokenState: Equatable {
    /// Nothing is saved for this group.
    case none
    /// Saved, and this build can read it without prompting.
    case readable
    /// Saved, but unreadable until the owner authorizes this build once.
    case unreadable

    static func resolve(hasSavedFlag: Bool, silentReadSucceeded: Bool) -> SavedTokenState {
        guard hasSavedFlag else { return .none }
        return silentReadSucceeded ? .readable : .unreadable
    }

    /// Whether the group shows the caption and the Re-Authorize Saved Token button.
    var needsReauthorization: Bool { self == .unreadable }
}
