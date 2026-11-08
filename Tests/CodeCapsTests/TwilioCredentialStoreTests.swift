import XCTest
import Security
import QuotaCore
@testable import CodeCaps

final class TwilioCredentialStoreTests: XCTestCase {
    private var credentials: TwilioSMSCredentials {
        .init(configuration: .init(accountSID: "AC" + String(repeating: "a", count: 32),
            apiKeySID: "SK" + String(repeating: "b", count: 32),
            messagingServiceSID: "MG" + String(repeating: "c", count: 32), recipient: "+15551234567"),
            apiKeySecret: "fixture-secret")
    }

    func testBuildScopedSingleRecordAndClearUseOnlyFakeKeychain() async throws {
        let fixture = TwilioKeychainFixture()
        let store = TwilioCredentialStore(calls: fixture.calls, bundleIdentifier: "com.example.CodeCaps.test")
        let missing = await store.load()
        XCTAssertNil(missing)
        try await store.save(credentials)
        let loaded = await store.load()
        XCTAssertEqual(loaded, credentials)
        XCTAssertEqual(fixture.itemCount, 1)
        XCTAssertEqual(fixture.services, ["com.example.CodeCaps.test.twilio-sms"])
        try await store.clear()
        let cleared = await store.load()
        XCTAssertNil(cleared)
        XCTAssertEqual(fixture.itemCount, 0)
    }

    func testProductionAndDevelopmentServicesDifferFromExistingTokens() {
        let release = TwilioCredentialStore.serviceName(bundleIdentifier: "com.example.CodeCaps")
        let development = TwilioCredentialStore.serviceName(bundleIdentifier: "com.example.CodeCaps.dev")
        XCTAssertNotEqual(release, development)
        XCTAssertFalse(TokenStore.ownServices.contains(release))
        XCTAssertFalse(TokenStore.ownServices.contains(development))
    }

    /// The Twilio API key secret resolves env-first, then Infisical, and the
    /// Keychain record only last: an ordinary service credential must not
    /// make the Keychain its source of truth (Kody review, PR #367).
    func testSecretResolutionOrderIsEnvironmentThenInfisicalThenKeychain() {
        let stored = TwilioSMSCredentials(
            configuration: TwilioSMSConfiguration(accountSID: "AC123", apiKeySID: "SK123",
                                                  messagingServiceSID: "MG123", recipient: "+15551234567"),
            apiKeySecret: "keychain-secret")
        let envCredentials = SMSCredentialAccess.resolvedCredentials(
            stored: stored,
            environment: ["TWILIO_API_KEY_SECRET": "env-secret"],
            infisicalSecret: "infisical-secret")
        XCTAssertEqual(envCredentials?.apiKeySecret, "env-secret", "the environment wins")
        let infisicalCredentials = SMSCredentialAccess.resolvedCredentials(
            stored: stored, environment: [:], infisicalSecret: "infisical-secret")
        XCTAssertEqual(infisicalCredentials?.apiKeySecret, "infisical-secret", "Infisical outranks the Keychain")
        let keychainCredentials = SMSCredentialAccess.resolvedCredentials(
            stored: stored, environment: [:], infisicalSecret: nil)
        XCTAssertEqual(keychainCredentials?.apiKeySecret, "keychain-secret",
                       "with no operator secret the Keychain record still answers")
        // A stored record supplies the configuration an operator secret is used with.
        XCTAssertEqual(envCredentials?.configuration, stored.configuration)
        XCTAssertNil(SMSCredentialAccess.resolvedCredentials(stored: nil, environment: [:], infisicalSecret: nil),
                     "no secret anywhere means no credentials")
        // An empty or blank secret is not a secret.
        XCTAssertEqual(SMSCredentialAccess.resolvedCredentials(
            stored: stored, environment: ["TWILIO_API_KEY_SECRET": "   "],
            infisicalSecret: nil)?.apiKeySecret, "keychain-secret")
    }

    func testInvalidSetupNeverTouchesKeychain() async {
        let fixture = TwilioKeychainFixture()
        let store = TwilioCredentialStore(calls: fixture.calls, bundleIdentifier: "com.example.CodeCaps.test")
        var invalid = credentials
        invalid.configuration.apiKeySID = "AC" + String(repeating: "b", count: 32)
        do {
            try await store.save(invalid)
            XCTFail("Expected invalid setup rejection")
        } catch { XCTAssertEqual(error as? TwilioSMSFailure, .invalidConfiguration) }
        XCTAssertEqual(fixture.itemCount, 0)
        XCTAssertTrue(fixture.services.isEmpty)
    }
}

private final class TwilioKeychainFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var touched: Set<String> = []
    var calls: KeychainCalls {
        .init(copyData: { service, account, _ in
            self.lock.lock(); defer { self.lock.unlock() }
            self.touched.insert(service)
            let data = self.values[service + "/" + account]
            return (data == nil ? errSecItemNotFound : errSecSuccess, data)
        }, delete: { service, account in
            self.lock.lock(); defer { self.lock.unlock() }
            self.touched.insert(service)
            self.values[service + "/" + account] = nil
            return errSecSuccess
        }, add: { service, account, data in
            self.lock.lock(); defer { self.lock.unlock() }
            self.touched.insert(service)
            self.values[service + "/" + account] = data
            return errSecSuccess
        })
    }
    var itemCount: Int {
        lock.lock(); defer { lock.unlock() }
        return values.count
    }
    var services: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return touched
    }
}
