import Foundation
import LocalAuthentication
import Security
import XCTest
@testable import QuotaCore

/// The one-time Allow Access To Claude Code step.
///
/// macOS guards Claude Code's Keychain item per code identity, so a freshly
/// installed CodeCaps reads nothing until the owner allows it once.  "Nothing
/// is there" and "something is there that I may not read" used to arrive as
/// the same empty result, and a signed-in owner was told to sign in.
///
/// Every test here is offline and never touches a Keychain: the state mapping
/// is pure, the reader takes an injected credential closure, the silent read
/// takes an injected Keychain probe, and the child-process handling runs
/// throwaway `/bin/sh` and `/usr/bin/yes` children instead of the real
/// `security` tool.  No credential value is ever asserted on.
final class ClaudeConsentTests: XCTestCase {

    override func setUp() {
        super.setUp()
        ClaudeCredentialSource.resetRememberedCredential()
    }

    // MARK: - The pure mapping

    func testNoItemAndNoFileReadsAsSignedOut() {
        let state = ClaudeLoginState.resolve(hasUsableCredential: false, access: .missing)
        XCTAssertEqual(state, .signedOut)
        XCTAssertFalse(state.needsConsent)
        XCTAssertEqual(state.issue, "Claude Code quota login is unavailable." + sentenceGap
                       + "Sign in to Claude Code to connect subscription quotas.")
    }

    func testItemPresentButUnreadableAsksForPermission() {
        let state = ClaudeLoginState.resolve(hasUsableCredential: false, access: .unauthorized)
        XCTAssertEqual(state, .needsPermission)
        XCTAssertTrue(state.needsConsent)
        XCTAssertEqual(state.issue, "CodeCaps needs your permission to read Claude Code's saved login.")
    }

    func testReadableItemIsConnected() {
        let access = ClaudeCredentialAccess.authorized(Data("{}".utf8))
        let state = ClaudeLoginState.resolve(hasUsableCredential: true, access: access)
        XCTAssertEqual(state, .connected)
        XCTAssertFalse(state.needsConsent)
        XCTAssertNil(state.issue)
    }

    /// A fresh credentials file wins outright: the Keychain is never consulted,
    /// so whatever it would have said cannot produce a consent prompt.
    func testFreshFileIsConnectedWhateverTheKeychainWouldSay() {
        XCTAssertEqual(ClaudeLoginState.resolve(hasUsableCredential: true, access: .missing), .connected)
        XCTAssertEqual(ClaudeLoginState.resolve(hasUsableCredential: true, access: .unauthorized), .connected)
    }

    func testRenewableExpiredLoginReadsAsIdleNotSignedOut() {
        let state = ClaudeLoginState.resolve(hasUsableCredential: false, access: .missing, renewable: true)
        XCTAssertEqual(state, .idle)
        XCTAssertFalse(state.needsConsent)
        XCTAssertEqual(state.issue, "Claude Code's saved login expired while Claude Code was idle." + sentenceGap
                       + "It renews the next time Claude Code runs.")
        // An unreadable item still asks for permission first.
        XCTAssertEqual(ClaudeLoginState.resolve(hasUsableCredential: false, access: .unauthorized, renewable: true),
                       .needsPermission)
        XCTAssertEqual(ClaudeLoginState.resolve(hasUsableCredential: false, access: .missing, renewable: false),
                       .signedOut)
    }

    // MARK: - The reader, with an injected credential closure

    func testUnauthorizedItemSurfacesTheConsentIssueAndFlagsTheProvider() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Expired, exactly like the stale file this Mac actually carries.
        try writeFixtureLogin(expiresAt: 1_000_000_000_000, to: home)
        let reader = LocalQuotaReader(homeDirectory: home,
                                      runAntigravity: { Data("{}".utf8) },
                                      readClaudeCredential: { .unauthorized })
        let result = await reader.read()
        XCTAssertEqual(result.issues["anthropic"], ClaudeLoginState.needsPermission.issue)
        XCTAssertTrue(result.consentNeeded.contains("anthropic"))
        XCTAssertTrue(result.windows.filter { $0.providerKey == "anthropic" }.isEmpty)
    }

    func testMissingItemKeepsTheSignedOutWordingAndAsksForNoConsent() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeFixtureLogin(expiresAt: 1_000_000_000_000, to: home)
        let reader = LocalQuotaReader(homeDirectory: home,
                                      runAntigravity: { Data("{}".utf8) },
                                      readClaudeCredential: { .missing })
        let result = await reader.read()
        XCTAssertEqual(result.issues["anthropic"], ClaudeLoginState.signedOut.issue)
        XCTAssertFalse(result.consentNeeded.contains("anthropic"))
    }

    func testAuthorizedItemReadsQuotaAndAsksForNoConsent() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeFixtureLogin(expiresAt: 1_000_000_000_000, to: home)
        let reader = LocalQuotaReader(
            homeDirectory: home,
            fetchJSON: { request in
                XCTAssertEqual(request.url?.host, "api.anthropic.com")
                return Self.httpResponse(#"{"five_hour":{"utilization":40}}"#)
            },
            runAntigravity: { Data("{}".utf8) },
            readClaudeCredential: {
                .authorized(Data(#"{"claudeAiOauth":{"accessToken":"fixture","expiresAt":4102444800000}}"#.utf8))
            })
        let result = await reader.read()
        XCTAssertEqual(result.windows.first { $0.providerKey == "anthropic" }?.remainingPercent, 60)
        XCTAssertNil(result.issues["anthropic"])
        XCTAssertTrue(result.consentNeeded.isEmpty)
    }

    /// A usable file means no Keychain traffic at all, so a background refresh
    /// on a healthy Mac can never reach the code path that once raised a panel.
    func testFreshFileNeverConsultsTheKeychain() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeFixtureLogin(expiresAt: 4_102_444_800_000, to: home)
        let probed = ProbeFlag()
        let reader = LocalQuotaReader(
            homeDirectory: home,
            fetchJSON: { _ in Self.httpResponse(#"{"five_hour":{"utilization":10}}"#) },
            runAntigravity: { Data("{}".utf8) },
            readClaudeCredential: {
                probed.set()
                return .unauthorized
            })
        let result = await reader.read()
        XCTAssertFalse(probed.value, "a fresh credentials file must not cost a Keychain read")
        XCTAssertEqual(result.windows.first { $0.providerKey == "anthropic" }?.remainingPercent, 90)
        XCTAssertTrue(result.consentNeeded.isEmpty)
    }

    // MARK: - Idle renewal

    private static let expiredRenewable = Data(
        #"{"claudeAiOauth":{"accessToken":"old","refreshToken":"r","expiresAt":1000000000000}}"#.utf8)
    private static let freshLogin = Data(
        #"{"claudeAiOauth":{"accessToken":"new","refreshToken":"r","expiresAt":4102444800000}}"#.utf8)

    /// A counter safe to touch from `@Sendable` closures.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func bump() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    /// Serves the expired login until `bump()` has been called, then a fresh one.
    private func makeIdleReader(home: URL, renewals: Counter, renewalHelps: Bool,
                                throttle: ClaudeRenewalThrottle,
                                now: @escaping @Sendable () -> Date = { Date() }) -> LocalQuotaReader {
        LocalQuotaReader(
            homeDirectory: home,
            now: now,
            fetchJSON: { _ in Self.httpResponse(#"{"five_hour":{"utilization":25}}"#) },
            runAntigravity: { Data("{}".utf8) },
            readClaudeCredential: {
                .authorized(renewals.value > 0 && renewalHelps ? Self.freshLogin : Self.expiredRenewable)
            },
            renewClaudeLogin: { renewals.bump() },
            renewalThrottle: throttle)
    }

    func testIdleLoginIsRenewedThenReadAndReturnsWindows() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let renewals = Counter()
        let reader = makeIdleReader(home: home, renewals: renewals, renewalHelps: true,
                                    throttle: ClaudeRenewalThrottle())
        let result = await reader.read()
        XCTAssertEqual(renewals.value, 1)
        XCTAssertEqual(result.windows.first { $0.providerKey == "anthropic" }?.remainingPercent, 75)
        XCTAssertNil(result.issues["anthropic"])
        XCTAssertTrue(result.consentNeeded.isEmpty)
    }

    func testRenewalThatDoesNotHelpReportsIdleNotSignedOut() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let renewals = Counter()
        let reader = makeIdleReader(home: home, renewals: renewals, renewalHelps: false,
                                    throttle: ClaudeRenewalThrottle())
        let result = await reader.read()
        XCTAssertEqual(renewals.value, 1)
        XCTAssertEqual(result.issues["anthropic"], ClaudeLoginState.idle.issue)
        XCTAssertNotEqual(result.issues["anthropic"], ClaudeLoginState.signedOut.issue)
        XCTAssertFalse(result.consentNeeded.contains("anthropic"))
        XCTAssertTrue(result.windows.filter { $0.providerKey == "anthropic" }.isEmpty)
    }

    func testRenewalIsThrottledToOncePerFifteenMinutes() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let renewals = Counter()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let reader = makeIdleReader(home: home, renewals: renewals, renewalHelps: false,
                                    throttle: ClaudeRenewalThrottle(), now: { start })
        _ = await reader.read()
        _ = await reader.read()
        XCTAssertEqual(renewals.value, 1, "two reads inside 15 minutes must renew once")

        let later = makeIdleReader(home: home, renewals: renewals, renewalHelps: false,
                                   throttle: ClaudeRenewalThrottle(), now: { start })
        _ = await later.read()   // fresh throttle: one more, proving the counter is per throttle
        XCTAssertEqual(renewals.value, 2)
    }

    func testThrottleAllowsAnotherRenewalAfterTheInterval() async {
        let throttle = ClaudeRenewalThrottle()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let renewals = Counter()
        let first = await throttle.perform(now: start) { renewals.bump() }
        let second = await throttle.perform(now: start.addingTimeInterval(14 * 60)) { renewals.bump() }
        let third = await throttle.perform(now: start.addingTimeInterval(16 * 60)) { renewals.bump() }
        XCTAssertEqual([first, second, third], [true, false, true])
        XCTAssertEqual(renewals.value, 2)
    }

    func testOverlappingRenewalsShareOneRun() async {
        let throttle = ClaudeRenewalThrottle()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let renewals = Counter()
        async let a = throttle.perform(now: now) {
            renewals.bump()
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        async let b = throttle.perform(now: now) { renewals.bump() }
        _ = await (a, b)
        XCTAssertEqual(renewals.value, 1)
    }

    func testUnrenewableExpiredLoginNeverAsksClaudeCodeToRenew() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let renewals = Counter()
        let reader = LocalQuotaReader(
            homeDirectory: home,
            runAntigravity: { Data("{}".utf8) },
            readClaudeCredential: {
                .authorized(Data(#"{"claudeAiOauth":{"accessToken":"old","expiresAt":1000000000000}}"#.utf8))
            },
            renewClaudeLogin: { renewals.bump() },
            renewalThrottle: ClaudeRenewalThrottle())
        let result = await reader.read()
        XCTAssertEqual(renewals.value, 0)
        XCTAssertEqual(result.issues["anthropic"], ClaudeLoginState.signedOut.issue)
    }

    // MARK: - The silent read never starts security and never reads the secret

    /// Records every Keychain operation an injected probe was asked for.  A
    /// background log of only "lookup" is proof the `security` child did not
    /// start and no in-process data read was attempted.
    private final class ProbeLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String] = []
        func record(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
        var calls: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    private func makeProbe(log: ProbeLog,
                           cli outcomes: [SecurityCLIOutcome],
                           presence: ClaudeItemPresence) -> ClaudeKeychainProbe {
        let queue = OutcomeQueue(outcomes)
        return ClaudeKeychainProbe(
            readViaSecurityCLI: { _, _ in
                log.record("cli")
                return queue.next()
            },
            lookUpItem: {
                log.record("lookup")
                return presence
            })
    }

    /// Hands out scripted CLI outcomes in order, repeating the last one.
    private final class OutcomeQueue: @unchecked Sendable {
        private let lock = NSLock()
        private var remaining: [SecurityCLIOutcome]
        init(_ outcomes: [SecurityCLIOutcome]) { remaining = outcomes }
        func next() -> SecurityCLIOutcome {
            lock.lock(); defer { lock.unlock() }
            return remaining.count > 1 ? remaining.removeFirst() : (remaining.first ?? .failed)
        }
    }

    func testBackgroundReadWithAnItemAndNoGrantAsksForConsentAndNeverStartsSecurity() {
        let log = ProbeLog()
        let access = ClaudeCredentialSource.resolveSilently(
            probe: makeProbe(log: log, cli: [.timedOut], presence: .present))
        XCTAssertEqual(access, .unauthorized)
        XCTAssertEqual(log.calls, ["lookup"])
        XCTAssertEqual(ClaudeLoginState.resolve(hasUsableCredential: false, access: access), .needsPermission)
    }

    func testBackgroundReadWhenTheLookupCannotTellStaysTransientAndNeverStartsSecurity() {
        let log = ProbeLog()
        let access = ClaudeCredentialSource.resolveSilently(
            probe: makeProbe(log: log, cli: [.timedOut], presence: .unknown))
        XCTAssertEqual(access, .temporarilyUnavailable)
        XCTAssertEqual(log.calls, ["lookup"])
    }

    func testBackgroundReadWithNoItemIsMissingAndDropsARememberedGrant() {
        let payload = Data(#"{"claudeAiOauth":{"accessToken":"fixture"}}"#.utf8)
        ClaudeCredentialSource.remember(payload)
        let log = ProbeLog()
        let access = ClaudeCredentialSource.resolveSilently(
            probe: makeProbe(log: log, cli: [.found(payload)], presence: .absent))
        XCTAssertEqual(access, .missing)
        XCTAssertEqual(log.calls, ["lookup"])
        XCTAssertNil(ClaudeCredentialSource.rememberedCredential())
    }

    func testExpiredRememberedGrantIsDroppedAndAsksForConsent() {
        let expired = Data(#"{"claudeAiOauth":{"accessToken":"fixture","expiresAt":1}}"#.utf8)
        ClaudeCredentialSource.remember(expired)
        let log = ProbeLog()
        let access = ClaudeCredentialSource.resolveSilently(
            probe: makeProbe(log: log, cli: [.found(expired)], presence: .present),
            isAbandoned: { false })
        XCTAssertEqual(access, .unauthorized)
        XCTAssertEqual(log.calls, ["lookup"])
        XCTAssertNil(ClaudeCredentialSource.rememberedCredential())
        XCTAssertFalse(ClaudeCredentialSource.rememberedGrantStillUsable(expired, now: Date(timeIntervalSince1970: 10)))
    }

    func testUnexpiredRememberedGrantStaysUsable() {
        let payload = Data(#"{"claudeAiOauth":{"accessToken":"fixture","expiresAt":4102444800000}}"#.utf8)
        XCTAssertTrue(ClaudeCredentialSource.rememberedGrantStillUsable(payload, now: Date(timeIntervalSince1970: 1_700_000_000)))
    }

    func testRememberedGrantIsServedWithoutStartingSecurity() {
        let log = ProbeLog()
        let payload = Data(#"{"claudeAiOauth":{"accessToken":"fixture"}}"#.utf8)
        ClaudeCredentialSource.remember(payload)
        let access = ClaudeCredentialSource.resolveSilently(
            probe: makeProbe(log: log, cli: [.denied], presence: .present))
        XCTAssertEqual(access, .authorized(payload))
        XCTAssertEqual(log.calls, ["lookup"])
    }

    func testAbandonedBackgroundReadStartsNothing() {
        let log = ProbeLog()
        let access = ClaudeCredentialSource.resolveSilently(
            probe: makeProbe(log: log, cli: [.found(Data())], presence: .present),
            isAbandoned: { true })
        XCTAssertEqual(access, .temporarilyUnavailable)
        XCTAssertEqual(log.calls, [])
    }

    func testSecurityExitStatusesMapToOutcomes() {
        XCTAssertEqual(errSecItemNotFound & 0xFF, 44)
        XCTAssertEqual(errSecAuthFailed & 0xFF, 51)
        XCTAssertEqual(SecurityCLIOutcome.classify(exitStatus: 44), .notFound)
        XCTAssertEqual(SecurityCLIOutcome.classify(exitStatus: 51), .denied)
        XCTAssertEqual(SecurityCLIOutcome.classify(exitStatus: errSecInteractionNotAllowed & 0xFF), .denied)
        XCTAssertEqual(SecurityCLIOutcome.classify(exitStatus: errSecUserCanceled & 0xFF), .denied)
        XCTAssertEqual(SecurityCLIOutcome.classify(exitStatus: 1), .failed)
    }

    // MARK: - The real child-process handling, with a stand-in child

    private func shell(_ script: String) -> SecurityCommand {
        SecurityCommand(executable: "/bin/sh", arguments: ["-c", script])
    }

    private func runCLI(_ command: SecurityCommand, deadline: TimeInterval = 10,
                        shouldStop: @escaping @Sendable () -> Bool = { false }) -> SecurityCLIOutcome {
        ClaudeCredentialSource.runSecurityCLI(deadline: deadline, command: command, shouldStop: shouldStop)
    }

    func testProductionCommandIsTheSecurityToolReadingOnlyClaudesItem() {
        let command = SecurityCommand.findClaudeLogin
        XCTAssertEqual(command.executable, "/usr/bin/security")
        XCTAssertEqual(command.arguments, ["find-generic-password", "-s", "Claude Code-credentials", "-w"])
    }

    func testChildExitStatusesBecomeOutcomes() {
        XCTAssertEqual(runCLI(shell("exit 44")), .notFound)
        XCTAssertEqual(runCLI(shell("exit 51")), .denied)
        XCTAssertEqual(runCLI(shell("exit 36")), .denied)
        XCTAssertEqual(runCLI(shell("exit 128")), .denied)
        XCTAssertEqual(runCLI(shell("exit 1")), .failed)
    }

    func testChildOutputIsReturnedTrimmedAndHexIsDecoded() {
        XCTAssertEqual(runCLI(shell("printf '{\"a\":1}\\n'")), .found(Data(#"{"a":1}"#.utf8)))
        // `security` prints hex when the stored value holds non-ASCII bytes.
        XCTAssertEqual(runCLI(shell("printf 7b2261223a317d")), .found(Data(#"{"a":1}"#.utf8)))
    }

    func testEmptyOutputSignalsAndLaunchErrorsAreFailures() {
        XCTAssertEqual(runCLI(shell("exit 0")), .failed, "a success with nothing in it is not a login")
        XCTAssertEqual(runCLI(shell("kill -9 $$")), .failed, "a child ended by a signal is not an answer")
        XCTAssertEqual(runCLI(SecurityCommand(executable: "/nonexistent/security", arguments: [])), .failed)
    }

    func testChildIsTimedOutAtItsDeadline() {
        let started = Date()
        XCTAssertEqual(runCLI(shell("exec /bin/sleep 30"), deadline: 0.3), .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testChildIsKilledAtOnceWhenTheCallerStops() {
        let started = Date()
        XCTAssertEqual(runCLI(shell("exec /bin/sleep 30"), deadline: 10, shouldStop: { true }), .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    /// A child that ignores SIGTERM has to be ended with SIGKILL, and be gone
    /// (reaped, not merely signalled) by the time the call returns.
    func testChildThatIgnoresSIGTERMIsKilledAndGone() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("claude-cli-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let script = "trap '' TERM; echo $$ > '\(pidFile.path)'; exec /bin/sleep 30"
        let outcome = runCLI(shell(script), deadline: 2)
        XCTAssertEqual(outcome, .timedOut)
        let pid = try XCTUnwrap(Int32(String(contentsOfFile: pidFile.path, encoding: .utf8)
                                        .trimmingCharacters(in: .whitespacesAndNewlines)),
                                "the child never wrote its pid, so the test proved nothing")
        try XCTAssertProcessGone(pid)
    }

    /// A child that never stops writing is cut off at the size cap, killed,
    /// and reported as a failure rather than buffered without bound.
    func testRunawayOutputIsCappedAndTheChildKilled() throws {
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("claude-cli-pid-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: pidFile) }
        let started = Date()
        let outcome = runCLI(shell("echo $$ > '\(pidFile.path)'; exec /usr/bin/yes"), deadline: 20)
        XCTAssertEqual(outcome, .failed)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        let pid = try XCTUnwrap(Int32(String(contentsOfFile: pidFile.path, encoding: .utf8)
                                        .trimmingCharacters(in: .whitespacesAndNewlines)))
        try XCTAssertProcessGone(pid)
    }

    private func XCTAssertProcessGone(_ pid: Int32, file: StaticString = #filePath, line: UInt = #line) throws {
        let end = Date().addingTimeInterval(1.5)
        while kill(pid, 0) == 0 && Date() < end { usleep(20_000) }
        XCTAssertEqual(kill(pid, 0), -1, "child \(pid) is still alive", file: file, line: line)
        XCTAssertEqual(errno, ESRCH, file: file, line: line)
    }

    func testBusyReadIsTransientAndTouchesNoKeychain() async {
        let log = ProbeLog()
        let busy = DispatchSemaphore(value: 0)
        let access = await ClaudeCredentialSource.access(
            probe: makeProbe(log: log, cli: [.found(Data("{}".utf8))], presence: .present),
            gate: busy, queue: DispatchQueue(label: "claude-consent-test.busy"), timeout: 5)
        XCTAssertEqual(access, .temporarilyUnavailable)
        XCTAssertTrue(log.calls.isEmpty)
        XCTAssertFalse(ClaudeLoginState.resolve(hasUsableCredential: false, access: access).needsConsent)
    }

    /// A background read finishes from the attributes lookup.  A CLI closure
    /// that would hang is never entered, so it cannot raise a panel.
    func testBackgroundAccessNeverStartsTheSecurityCLI() async {
        let log = ProbeLog()
        let gate = DispatchSemaphore(value: 1)
        let probe = ClaudeKeychainProbe(
            readViaSecurityCLI: { _, _ in
                log.record("cli")
                sleep(5)
                return .timedOut
            },
            lookUpItem: {
                log.record("lookup")
                return .present
            })
        let started = Date()
        let access = await ClaudeCredentialSource.access(
            probe: probe, gate: gate, queue: DispatchQueue(label: "claude-consent-test.background"),
            timeout: 2, attemptDeadline: 5)
        XCTAssertEqual(access, .unauthorized)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        XCTAssertEqual(log.calls, ["lookup"])
    }

    // MARK: - The existence check asks for attributes only

    func testExistenceQueryNeverRequestsTheSecret() {
        let query = ClaudeCredentialSource.attributesQuery(context: LAContext())
        for forbidden in [kSecReturnData, kSecReturnRef, kSecReturnPersistentRef] {
            XCTAssertNil(query[forbidden as String], "\(forbidden) would make the refresh loop request the secret")
        }
        XCTAssertEqual(query[kSecReturnAttributes as String] as? Bool, true)
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, "Claude Code-credentials")
        XCTAssertEqual(query[kSecUseAuthenticationUI as String] as? String,
                       kSecUseAuthenticationUIFail as String)
        XCTAssertNotNil(query[kSecUseAuthenticationContext as String])
    }

    // MARK: - Allow Access is the only security read

    func testAllowAccessReadsThroughTheSecurityCLIOnly() async {
        let log = ProbeLog()
        let deadlines = DeadlineLog()
        let probe = ClaudeKeychainProbe(
            readViaSecurityCLI: { deadline, _ in
                log.record("cli")
                deadlines.record(deadline)
                return .found(Data("{}".utf8))
            },
            lookUpItem: {
                log.record("lookup")
                return .present
            })
        let granted = await ClaudeCredentialSource.readAllowingInteraction(
            probe: probe, deadline: ClaudeCredentialSource.interactiveDeadline)
        XCTAssertTrue(granted)
        XCTAssertEqual(log.calls, ["cli"], "the button is the only security run, and it makes no in-process data read")
        XCTAssertEqual(deadlines.values, [ClaudeCredentialSource.interactiveDeadline])
        XCTAssertGreaterThan(ClaudeCredentialSource.interactiveDeadline, ClaudeCredentialSource.cliAttemptDeadline,
                             "the button must leave time to answer the panel")
        let silent = ClaudeCredentialSource.resolveSilently(probe: probe)
        XCTAssertEqual(silent, .authorized(Data("{}".utf8)))
        XCTAssertEqual(log.calls, ["cli", "lookup"], "the next refresh serves the remembered bytes and does not start security again")
    }

    func testAllowAccessIsNotGrantedUnlessTheSecurityCLIReadIt() async {
        for outcome in [SecurityCLIOutcome.denied, .notFound, .timedOut, .failed] {
            let probe = ClaudeKeychainProbe(readViaSecurityCLI: { _, _ in outcome }, lookUpItem: { .present })
            let granted = await ClaudeCredentialSource.readAllowingInteraction(probe: probe, deadline: 5)
            XCTAssertFalse(granted, "\(outcome) must not report a grant")
        }
    }

    /// The button's wait gives up after the child's deadline plus its kill
    /// grace, and tells a still-waiting child to stop.
    func testAllowAccessStopsTheChildWhenItsWaitEnds() async {
        let sawStop = ProbeFlag()
        let probe = ClaudeKeychainProbe(
            readViaSecurityCLI: { _, shouldStop in
                let end = Date().addingTimeInterval(5)
                while !shouldStop() && Date() < end { usleep(5_000) }
                if shouldStop() { sawStop.set() }
                return .timedOut
            },
            lookUpItem: { .present })
        let started = Date()
        let granted = await ClaudeCredentialSource.readAllowingInteraction(probe: probe, deadline: 30, wait: 0.2)
        XCTAssertFalse(granted)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        let end = Date().addingTimeInterval(2)
        while !sawStop.value && Date() < end { usleep(10_000) }
        XCTAssertTrue(sawStop.value)
    }

    private final class DeadlineLog: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [TimeInterval] = []
        func record(_ value: TimeInterval) { lock.lock(); entries.append(value); lock.unlock() }
        var values: [TimeInterval] { lock.lock(); defer { lock.unlock() }; return entries }
    }

    func testOuterWaitsOutlastTheCLIBudget() {
        XCTAssertGreaterThanOrEqual(ClaudeCredentialSource.cliAttemptDeadline, 12)
        XCTAssertEqual(ClaudeCredentialSource.cliAttempts, 2)
        XCTAssertGreaterThan(ClaudeCredentialSource.accessTimeout, ClaudeCredentialSource.cliBudget)
        XCTAssertGreaterThan(ClaudeCredentialSource.boundedAccessTimeout, ClaudeCredentialSource.accessTimeout)
    }

    func testBoundedAccessTimeoutIsTransientNotMissing() async {
        let access = await ClaudeCredentialSource.boundedAccess(timeout: 0.1) {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return .missing
        }
        XCTAssertEqual(access, .temporarilyUnavailable)
    }

    func testTransientStateHasANeutralIssue() {
        let state = ClaudeLoginState.resolve(hasUsableCredential: false, access: .temporarilyUnavailable,
                                             renewable: true)
        XCTAssertEqual(state, .temporarilyUnavailable)
        XCTAssertFalse(state.needsConsent)
        XCTAssertEqual(state.issue, "Claude quota is temporarily unavailable.")
        // Glance words its status line by looking for these phrases.
        XCTAssertFalse(state.issue!.localizedCaseInsensitiveContains("sign in"))
        XCTAssertFalse(state.issue!.localizedCaseInsensitiveContains("permission"))
        XCTAssertEqual(ClaudeLoginState.resolve(hasUsableCredential: true, access: .temporarilyUnavailable),
                       .connected)
    }

    /// The reader stops at a transient read: no renewal run, no second read,
    /// and neither the sign-in wording nor the consent button.
    func testTransientReadSurfacesTheNeutralIssueAndNeverRenews() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        // Expired but renewable, which would otherwise ask Claude Code to renew.
        let object: [String: Any] = ["claudeAiOauth": ["accessToken": "old", "refreshToken": "r",
                                                       "expiresAt": 1_000_000_000_000]]
        try JSONSerialization.data(withJSONObject: object)
            .write(to: home.appendingPathComponent(".claude").appendingPathComponent(".credentials" + ".json"))
        let reads = Counter()
        let renewals = Counter()
        let reader = LocalQuotaReader(
            homeDirectory: home,
            runAntigravity: { Data("{}".utf8) },
            readClaudeCredential: {
                reads.bump()
                return .temporarilyUnavailable
            },
            renewClaudeLogin: { renewals.bump() },
            renewalThrottle: ClaudeRenewalThrottle())
        let result = await reader.read()
        XCTAssertEqual(result.issues["anthropic"], ClaudeLoginState.temporarilyUnavailable.issue)
        XCTAssertNotEqual(result.issues["anthropic"], ClaudeLoginState.signedOut.issue)
        XCTAssertFalse(result.consentNeeded.contains("anthropic"))
        XCTAssertTrue(result.windows.filter { $0.providerKey == "anthropic" }.isEmpty)
        XCTAssertEqual(reads.value, 1)
        XCTAssertEqual(renewals.value, 0)
    }

    // MARK: - Helpers

    /// Records whether the injected credential closure ran, without requiring
    /// the closure itself to be mutating or actor-isolated.
    private final class ProbeFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    private func makeHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("claude-consent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url.appendingPathComponent(".claude"), withIntermediateDirectories: true)
        return url
    }

    /// Writes a fixture login into a throwaway home directory.  The token is a
    /// literal placeholder; nothing real is read, written, or asserted on.
    private func writeFixtureLogin(expiresAt: Double, to home: URL) throws {
        let object: [String: Any] = ["claudeAiOauth": ["accessToken": "fixture-token", "expiresAt": expiresAt]]
        let data = try JSONSerialization.data(withJSONObject: object)
        let name = ".credentials" + ".json"
        try data.write(to: home.appendingPathComponent(".claude").appendingPathComponent(name), options: .atomic)
    }

    private static func httpResponse(_ text: String, status: Int = 200) -> (Data, HTTPURLResponse) {
        let url = URL(string: "https://fixture.invalid/quota")!
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        return (Data(text.utf8), response)
    }
}
