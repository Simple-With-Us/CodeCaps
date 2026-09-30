import Foundation
import LocalAuthentication
import os
import Security

/// What a silent read of Claude Code's saved login found on this Mac.
///
/// The cases are deliberately distinct.  "No Claude Code login exists here",
/// "a login exists that could not be read", and "the read could not finish
/// this time" need completely different words in the UI, and the old `Data?`
/// could not tell them apart: all of them arrived as `nil`, so a signed-in
/// owner was told to sign in.
public enum ClaudeCredentialAccess: Equatable, Sendable {
    /// No Claude Code Keychain item exists on this Mac.
    case missing
    /// An item exists and reading it was explicitly refused: `security`
    /// reported an authorization failure, that user interaction was needed,
    /// or that the request was cancelled.  The one interactive read behind
    /// Allow Access To Claude Code is the only thing that asks macOS about it.
    case unauthorized
    /// A Claude Code login is here, or may be, and this read could not finish:
    /// the `security` tool timed out or failed twice on a loaded Mac, another
    /// read was still in flight, or the bounded wait gave up.  It says nothing
    /// about sign-in or permission, and the next refresh simply tries again.
    case temporarilyUnavailable
    /// The item was read.
    case authorized(Data)

    public var data: Data? {
        if case .authorized(let data) = self { return data }
        return nil
    }
}

/// What one bounded run of `/usr/bin/security find-generic-password` said.
///
/// `security` exits with the low byte of the `OSStatus` it met, so
/// `errSecItemNotFound` (-25300) is exit 44 and `errSecAuthFailed` (-25293)
/// is exit 51.
enum SecurityCLIOutcome: Equatable, Sendable {
    /// Exit 0 with a non-empty, size-capped payload.
    case found(Data)
    /// `errSecItemNotFound`: no Claude Code item for `security` to find.
    case notFound
    /// An explicit refusal: `errSecAuthFailed`, `errSecInteractionNotAllowed`
    /// or `errSecUserCanceled`.
    case denied
    /// The child missed its deadline (or the caller gave up) and was killed.
    case timedOut
    /// Anything else: the launch failed, another exit status, a signal, or
    /// output that was empty or over the size cap.
    case failed

    static func classify(exitStatus: Int32) -> SecurityCLIOutcome {
        if exitStatus == lowByte(errSecItemNotFound) { return .notFound }
        if deniedExitStatuses.contains(exitStatus) { return .denied }
        return .failed
    }

    private static let deniedExitStatuses: Set<Int32> = [
        lowByte(errSecAuthFailed),              // 51
        lowByte(errSecInteractionNotAllowed),   // 36
        lowByte(errSecUserCanceled),            // 128
    ]

    private static func lowByte(_ status: OSStatus) -> Int32 { status & 0xFF }

    /// Status words for the log.  Never carries the payload.
    var logLabel: String {
        switch self {
        case .found: return "found"
        case .notFound: return "not found"
        case .denied: return "denied"
        case .timedOut: return "timed out"
        case .failed: return "failed"
        }
    }
}

/// What the attributes-only lookup found.  It never asks for the secret.
enum ClaudeItemPresence: Equatable, Sendable {
    case present
    case absent
    /// Any status other than success or `errSecItemNotFound`.
    case unknown
}

/// The only two Keychain operations the refresh loop may perform.
///
/// Neither one reads Claude Code's secret from inside the CodeCaps process:
/// the CLI read happens in the `security` child, and the lookup asks for
/// attributes only.  There is deliberately no hook here for an in-process
/// data read, because that is the call that raised the panel.  Tests inject
/// their own closures so no test touches a real Keychain.
struct ClaudeKeychainProbe: Sendable {
    /// Runs `security` once, bounded by `deadline` seconds.  The second
    /// argument reports whether the caller has already given up, so a hung
    /// child is killed as soon as its answer can no longer be used.
    var readViaSecurityCLI: @Sendable (_ deadline: TimeInterval,
                                       _ shouldStop: @escaping @Sendable () -> Bool) -> SecurityCLIOutcome
    var lookUpItem: @Sendable () -> ClaudeItemPresence

    static let live = ClaudeKeychainProbe(
        readViaSecurityCLI: { deadline, shouldStop in
            ClaudeCredentialSource.runSecurityCLI(deadline: deadline, shouldStop: shouldStop)
        },
        lookUpItem: { ClaudeCredentialSource.lookUpItemAttributes() })
}

/// Reads Claude Code's own saved login.  This type never writes it, refreshes
/// it, re-ACLs it, or deletes it.  When the saved access token has expired
/// while Claude Code sat idle, `LocalQuotaReader` may ask Claude Code itself
/// to renew its own login (a zero-turn `/usage` run); Claude Code then writes
/// its own Keychain item and CodeCaps only reads the result.
public enum ClaudeCredentialSource {
    static let service = "Claude Code-credentials"

    private static let worker = DispatchQueue(label: "com.jays.usage-monitor.claude-keychain")
    private static let activeRead = DispatchSemaphore(value: 1)

    /// One `security` run's deadline.  It was 3 seconds, and under a load
    /// average of 500-990 the child stalled at "Retrieve User by ID" past it.
    static let cliAttemptDeadline: TimeInterval = 12
    /// A timed-out or failed run is tried once more.  An explicit answer —
    /// found, not found, denied — is never retried.
    static let cliAttempts = 2
    /// How long SIGTERM, and then SIGKILL, each get to end a hung child.
    static let cliKillGrace: TimeInterval = 0.5
    /// The longest the CLI step can take, retry and kill grace included.
    static var cliBudget: TimeInterval { Double(cliAttempts) * (cliAttemptDeadline + 2 * cliKillGrace) }
    /// `access()`'s own wait.  Longer than `cliBudget`, with room for the
    /// attributes lookup, so a slow but healthy read is never cut off.
    static let accessTimeout: TimeInterval = 30
    /// `boundedAccess`'s wait, which wraps `access()` and so must outlast it.
    public static let boundedAccessTimeout: TimeInterval = 35

    /// Long enough for someone to read and answer a system panel, short enough
    /// that a wedged Keychain does not leave the button spinning forever.
    private static let interactiveTimeout: Double = 60
    private static let maxCredentialBytes = 1_048_576

    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.jays.agent-bar.mac",
                                    category: "claude-credentials")

    /// The refresh loop's read.  Never prompts, never makes a Keychain data
    /// request from this process, never mutates another app's login, and
    /// reports which kind of failure it met.
    public static func access() async -> ClaudeCredentialAccess {
        await access(probe: .live, gate: activeRead, queue: worker, timeout: accessTimeout)
    }

    /// `access()` with its collaborators injected, for tests.
    static func access(probe: ClaudeKeychainProbe,
                       gate semaphore: DispatchSemaphore,
                       queue: DispatchQueue,
                       timeout: TimeInterval,
                       attemptDeadline: TimeInterval = cliAttemptDeadline) async -> ClaudeCredentialAccess {
        await withCheckedContinuation { (continuation: CheckedContinuation<ClaudeCredentialAccess, Never>) in
            // A read still in flight — most likely a `security` child stuck on
            // a loaded Mac — says nothing about whether a login exists.
            guard semaphore.wait(timeout: .now()) == .success else {
                log.notice("claude keychain read skipped: an earlier read is still running")
                continuation.resume(returning: .temporarilyUnavailable)
                return
            }
            let gate = KeychainReadGate(continuation)
            queue.async {
                defer { semaphore.signal() }
                gate.finish(resolveSilently(probe: probe, attemptDeadline: attemptDeadline,
                                            isAbandoned: { gate.isFinished }))
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                if gate.finish(.temporarilyUnavailable) {
                    log.notice("claude keychain read gave up after its bounded wait")
                }
            }
        }
    }

    /// Bounds injected or future asynchronous keychain adapters as well as
    /// the production read.  Giving up is `.temporarilyUnavailable`, never
    /// `.missing`: a read that did not finish must not look like no login.
    public static func boundedAccess(timeout: TimeInterval = boundedAccessTimeout,
                                     _ operation: @escaping @Sendable () async -> ClaudeCredentialAccess) async -> ClaudeCredentialAccess {
        await withCheckedContinuation { (continuation: CheckedContinuation<ClaudeCredentialAccess, Never>) in
            let gate = KeychainReadGate(continuation)
            Task.detached(priority: .utility) { gate.finish(await operation()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                gate.finish(.temporarilyUnavailable)
            }
        }
    }

    /// One read that lets macOS show its own authorization panel.  Only ever
    /// reached from Allow Access To Claude Code — never from the refresh loop,
    /// which must stay prompt-free.
    ///
    /// Returns whether access was granted rather than the credential itself.
    /// Nothing outside this type has any use for Claude Code's saved login, so
    /// nothing outside this type is handed it.
    public static func readAllowingInteraction() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let gate = KeychainReadGate(continuation)
            // Deliberately not behind `activeRead`: a call parked on a panel
            // nobody has answered must not make every later silent read fail.
            DispatchQueue.global(qos: .userInitiated).async { gate.finish(readInteractively()) }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + interactiveTimeout) {
                gate.finish(false)
            }
        }
    }

    /// The refresh loop's decision, with no Keychain data request of its own.
    ///
    /// Why there is no in-process data read here any more (verified from the
    /// unified log, Sep 30 2026): the item's partition list is `apple-tool:`,
    /// so the `security` child matches it and reads silently.  CodeCaps does
    /// not: securityd logged `ACL partition mismatch: client
    /// teamid:CC8UTF7ATG ACL ("apple-tool:")` and then `displaying keychain
    /// prompt for <home>/Applications/CodeCaps.app` for a data `SecItemCopyMatching`
    /// that carried both `LAContext.interactionNotAllowed` and
    /// `kSecUseAuthenticationUIFail`.  So on current macOS those flags do not
    /// suppress the file-keychain ACL/partition panel.  Always Allow adds the
    /// team ID to the partition list, but Claude Code rewrites the item when
    /// it refreshes its token and the grant is gone again, so it is no fix
    /// either.  The attributes-only lookup below never asks for the secret
    /// and never prompted, so it stays as the existence check.
    ///
    /// `isAbandoned` turns true once the caller's bounded wait has given up.
    /// Nothing new starts after that — no retry, no lookup.
    static func resolveSilently(probe: ClaudeKeychainProbe,
                                attemptDeadline: TimeInterval = cliAttemptDeadline,
                                attempts: Int = cliAttempts,
                                isAbandoned: @escaping @Sendable () -> Bool = { false }) -> ClaudeCredentialAccess {
        var last = SecurityCLIOutcome.failed
        retry: for attempt in 1...max(1, attempts) {
            if isAbandoned() { return .temporarilyUnavailable }
            last = probe.readViaSecurityCLI(attemptDeadline, isAbandoned)
            log.notice("claude keychain security CLI attempt \(attempt, privacy: .public): \(last.logLabel, privacy: .public)")
            switch last {
            case .found(let data): return .authorized(data)
            case .denied: return .unauthorized
            case .notFound: break retry
            case .timedOut, .failed: continue retry
            }
        }

        if isAbandoned() { return .temporarilyUnavailable }
        switch (last, probe.lookUpItem()) {
        case (.notFound, .present):
            // `security` saw no item a moment ago and the lookup sees one:
            // Claude Code was most likely rewriting it.  Try again next time.
            return .temporarilyUnavailable
        case (.notFound, _), (_, .absent):
            return .missing
        default:
            // The item is there, or the lookup could not say, and the CLI
            // did not finish.  That is load, not a signed-out Mac.
            return .temporarilyUnavailable
        }
    }

    /// The existence check.  An attributes-only query reads the item's
    /// metadata, which needs no entry on its access list, so it answers "is
    /// there a Claude Code login here at all" without touching the secret.
    static func lookUpItemAttributes() -> ClaudeItemPresence {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecUseAuthenticationContext as String: context,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // Status codes only, at notice level so they persist in the log store.
        // Nothing here ever logs the credential.
        log.notice("claude keychain silent attributes status \(status, privacy: .public)")
        switch status {
        case errSecSuccess: return .present
        case errSecItemNotFound: return .absent
        default: return .unknown
        }
    }

    /// The one call allowed to raise the system panel: no `LAContext`, no
    /// `interactionNotAllowed`, no `kSecUseAuthenticationUIFail`.  It only ever
    /// reads — the item is never added, updated, or deleted.
    private static func readInteractively() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let found = SecItemCopyMatching(query as CFDictionary, &result)
        // Status codes only, at notice level so they persist in the log store.
        // Nothing here ever logs the credential.
        log.notice("claude keychain attributes status \(found, privacy: .public)")
        guard found == errSecSuccess,
              let items = result as? [[String: Any]],
              let newest = items.max(by: {
                  ($0[kSecAttrModificationDate as String] as? Date ?? .distantPast)
                    < ($1[kSecAttrModificationDate as String] as? Date ?? .distantPast)
              }) else { return false }

        var dataQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account = newest[kSecAttrAccount as String] {
            dataQuery[kSecAttrAccount as String] = account
        }
        var payload: CFTypeRef?
        let status = SecItemCopyMatching(dataQuery as CFDictionary, &payload)
        log.notice("claude keychain interactive read status \(status, privacy: .public)")
        guard status == errSecSuccess, let data = payload as? Data else { return false }
        return !data.isEmpty && data.count <= maxCredentialBytes
    }

    /// One bounded `security find-generic-password -w` run.  The child is
    /// judged by securityd as partition `apple-tool:`, which the item allows,
    /// so it reads silently and can never raise a panel as CodeCaps.  Output
    /// is capped, the child is killed at the deadline or as soon as
    /// `shouldStop` turns true, and it is never waited on without a bound.
    /// `serviceName` is overridable only so a test can ask for an item that
    /// does not exist; production always reads `service`.
    static func runSecurityCLI(deadline seconds: TimeInterval,
                               serviceName: String = service,
                               shouldStop: @Sendable () -> Bool) -> SecurityCLIOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", serviceName, "-w"]
        process.environment = ["HOME": FileManager.default.homeDirectoryForCurrentUser.path]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        let reader = output.fileHandleForReading
        do {
            try process.run()
        } catch {
            try? output.fileHandleForWriting.close()
            try? reader.close()
            return .failed
        }
        // Our copy of the write end has to close, or EOF never arrives.
        try? output.fileHandleForWriting.close()
        defer {
            // Never leave a hung child or an open descriptor behind.
            stop(process)
            try? reader.close()
        }

        let descriptor = reader.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        var reachedEOF = false
        while true {
            if shouldStop() || ProcessInfo.processInfo.systemUptime >= deadline { return .timedOut }
            if !reachedEOF {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    guard data.count + count <= maxCredentialBytes else { return .failed }
                    data.append(contentsOf: buffer.prefix(count))
                    continue
                }
                if count == 0 {
                    reachedEOF = true
                    continue
                }
                if errno != EAGAIN && errno != EINTR { return .failed }
            } else if !process.isRunning {
                break
            }
            usleep(5_000)
        }

        guard process.terminationReason == .exit else { return .failed }
        let status = process.terminationStatus
        guard status == 0 else { return SecurityCLIOutcome.classify(exitStatus: status) }
        guard let decoded = decodeOutput(data) else { return .failed }
        return .found(decoded)
    }

    /// SIGTERM, then SIGKILL, each with a short bounded wait.  A child that
    /// survives both is left to the OS rather than blocking this thread.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        if waitForExit(process, within: cliKillGrace) { return }
        kill(process.processIdentifier, SIGKILL)
        _ = waitForExit(process, within: cliKillGrace)
    }

    private static func waitForExit(_ process: Process, within seconds: TimeInterval) -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while process.isRunning {
            if ProcessInfo.processInfo.systemUptime >= end { return false }
            usleep(5_000)
        }
        return true
    }

    /// The trimmed payload, hex-decoded when macOS printed it as hex, or nil
    /// when there is nothing in it.
    static func decodeOutput(_ data: Data) -> Data? {
        guard let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let trimmed = string.data(using: .utf8) else {
            return data.isEmpty ? nil : data
        }
        guard !trimmed.isEmpty else { return nil }
        // macOS 26+ may output a hex-encoded string when the value contains
        // non-ASCII bytes.  Detect and decode it.
        return decodeHexString(trimmed) ?? trimmed
    }

    /// Returns decoded `Data` when the input is a pure hex string (pairs of
    /// `[0-9a-fA-F]`, optionally whitespace-separated).  Returns `nil` for
    /// anything that doesn't look like hex output, so the caller falls through
    /// to treating the data as-is.
    private static func decodeHexString(_ data: Data) -> Data? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let hex = raw.filter { !$0.isWhitespace }
        // Must be even-length and entirely hex digits.
        guard hex.count >= 2, hex.count.isMultiple(of: 2),
              hex.allSatisfy({ $0.isHexDigit }) else { return nil }
        // Only decode if it looks like hex-encoded JSON (starts with 7b = '{').
        guard hex.hasPrefix("7b") || hex.hasPrefix("7B") else { return nil }
        var decoded = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            decoded.append(byte)
            index = next
        }
        return decoded
    }
}

/// What the Claude reader should say, derived from the only two things it can
/// observe: whether it found a usable, unexpired OAuth record, and what a
/// silent Keychain read saw.  Pure, so the mapping is unit-tested without ever
/// touching a real Keychain.
public enum ClaudeLoginState: Equatable, Sendable {
    /// A usable credential was found — in Claude Code's file or its Keychain
    /// item — and the reader can go on to ask Anthropic for quota.
    case connected
    /// A Claude Code login exists on this Mac, and reading it was refused.
    /// The owner can answer that once from Settings.
    case needsPermission
    /// No usable Claude Code login exists here at all.
    case signedOut
    /// Claude Code is signed in, but its saved access token expired while
    /// Claude Code was idle and a renewal has not landed yet.  Claude Code
    /// renews it the next time it runs, so this is not a sign-in problem.
    case idle
    /// The silent read could not finish this time, usually because the Mac
    /// is heavily loaded.  Neither a sign-in nor a permission problem.
    case temporarilyUnavailable

    public static func resolve(hasUsableCredential: Bool, access: ClaudeCredentialAccess,
                               renewable: Bool = false) -> ClaudeLoginState {
        if hasUsableCredential { return .connected }
        switch access {
        case .unauthorized: return .needsPermission
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .missing, .authorized: return renewable ? .idle : .signedOut
        }
    }

    /// The one sentence a Glance row, a Console card and the Settings row all
    /// show.  Short on purpose: Glance has a single line for it.
    public var issue: String? {
        switch self {
        case .connected:
            return nil
        case .needsPermission:
            return "CodeCaps needs your permission to read Claude Code's saved login."
        case .signedOut:
            return "Claude Code quota login is unavailable." + sentenceGap
                + "Sign in to Claude Code to connect subscription quotas."
        case .idle:
            return "Claude Code's saved login expired while Claude Code was idle." + sentenceGap
                + "It renews the next time Claude Code runs."
        case .temporarilyUnavailable:
            return "Claude quota is temporarily unavailable."
        }
    }

    /// Whether the UI should offer the one-time Allow Access To Claude Code
    /// step rather than telling the owner to sign in.
    public var needsConsent: Bool { self == .needsPermission }
}

/// Resumes the async caller exactly once when the read returns, or when its
/// bounded wait expires.  A timed-out read may still be running in its worker,
/// but it cannot block the refresh task, and `isFinished` tells it to start
/// nothing new.
private final class KeychainReadGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    /// True once a value has been delivered, by the read or by the timeout.
    var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation == nil
    }

    /// Delivers `value` if nothing has been delivered yet, and says whether it
    /// was this call that did.
    @discardableResult
    func finish(_ value: Value) -> Bool {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
        return pending != nil
    }
}
