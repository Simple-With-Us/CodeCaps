import XCTest
@testable import QuotaCore

private final class InvocationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private struct RegistryFakeReader: LocalQuotaReading {
    let result: LocalQuotaResult
    var delayNanoseconds: UInt64 = 0

    func read() async -> LocalQuotaResult {
        if delayNanoseconds > 0 { try? await Task.sleep(nanoseconds: delayNanoseconds) }
        return result
    }
}

final class LocalQuotaReaderRegistryTests: XCTestCase {
    func testDisabledOptionalReaderIsNotConstructedOrInvoked() async {
        let calls = InvocationCounter()
        let registry = LocalQuotaReaderRegistry(registrations: [
            LocalQuotaReaderRegistration(id: "kimi", label: "Kimi", isOptional: true) {
                calls.increment()
                return RegistryFakeReader(result: LocalQuotaResult(issues: ["kimi": "read"]))
            },
        ])
        var preferences = QuotaReaderPreferences()
        preferences.setEnabled(false, for: "kimi")

        let result = await registry.read(preferences: preferences)

        XCTAssertEqual(calls.value(), 0)
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertTrue(result.issues.isEmpty)
    }

    func testMissingAndUnknownReaderChoicesDefaultToEnabled() {
        let preferences = QuotaReaderPreferences()
        XCTAssertTrue(preferences.isEnabled("kimi"))
        XCTAssertTrue(preferences.isEnabled("future-provider"))
    }

    func testPreferencesPersistExplicitChoiceAndPreserveUnknownIDs() {
        let suite = "LocalQuotaReaderRegistryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = QuotaReaderPreferences()
        preferences.setEnabled(false, for: "kimi")
        preferences.setEnabled(false, for: "future-provider")
        preferences.save(to: defaults)

        let loaded = QuotaReaderPreferences.load(from: defaults)
        XCTAssertFalse(loaded.isEnabled("kimi"))
        XCTAssertFalse(loaded.isEnabled("future-provider"))
        XCTAssertTrue(loaded.isEnabled("zcode"))
    }

    func testNonOptionalReadersRunAndResultsMergeInRegistrationOrder() async {
        let registry = LocalQuotaReaderRegistry(registrations: [
            LocalQuotaReaderRegistration(id: "primary", label: "Primary") {
                RegistryFakeReader(result: LocalQuotaResult(issues: ["same": "first"],
                                                              consentNeeded: ["first"]),
                                   delayNanoseconds: 50_000_000)
            },
            LocalQuotaReaderRegistration(id: "kimi", label: "Kimi", isOptional: true) {
                RegistryFakeReader(result: LocalQuotaResult(issues: ["same": "last"],
                                                              consentNeeded: ["second"]))
            },
        ])

        let result = await registry.read()

        XCTAssertEqual(result.issues["same"], "last")
        XCTAssertEqual(result.consentNeeded, ["first", "second"])
    }
}
