import XCTest
import Security
import QuotaCore
@testable import CodeCaps

@MainActor
final class ZAIQuotaSetupTests: XCTestCase {
    func testSavedRegionAndKeyRoundTripAsOneNarrowBuildScopedRecord() async throws {
        let vault = ZAIQuotaKeychainFixture()
        let store = ZAIQuotaCredentialStore(calls: vault.calls, bundleIdentifier: "com.example.CodeCaps.test")
        let missing = await store.load()
        XCTAssertNil(missing)
        let credential = ZCodeQuotaCredential(region: .bigModel, apiKey: "fixture-key")
        try await store.save(credential)
        let loaded = await store.load()
        XCTAssertEqual(loaded, credential)
        XCTAssertEqual(loaded?.region.quotaURL.host, "bigmodel.cn")
        XCTAssertEqual(vault.count, 1)
        XCTAssertEqual(vault.services, ["com.example.CodeCaps.test.zai-quota-api-key"])
        XCTAssertFalse(TokenStore.ownServices.contains("com.example.CodeCaps.test.zai-quota-api-key"))
        try await store.clear()
        let forgotten = await store.load()
        XCTAssertNil(forgotten)
        XCTAssertEqual(vault.count, 0)
    }

    func testInvalidKeyIsRejectedBeforeAnyKeychainWriteAndDevelopmentServicesDiffer() async {
        let vault = ZAIQuotaKeychainFixture()
        let store = ZAIQuotaCredentialStore(calls: vault.calls, bundleIdentifier: "com.example.CodeCaps.test")
        do {
            try await store.save(.init(region: .zAI, apiKey: String(repeating: "a", count: 8_193)))
            XCTFail("Oversized key must be refused")
        } catch { XCTAssertTrue(error is ZAIQuotaCredentialStore.Failure) }
        XCTAssertEqual(vault.count, 0)
        XCTAssertTrue(vault.services.isEmpty)
        XCTAssertNotEqual(ZAIQuotaCredentialStore.serviceName(bundleIdentifier: "com.example.CodeCaps"),
                          ZAIQuotaCredentialStore.serviceName(bundleIdentifier: "com.example.CodeCaps.dev"))
    }

    func testSetupIsExplicitAndPreferencesNeverContainTheKey() async {
        let suite = "ZAIQuotaSetupTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var saved: ZCodeQuotaCredential?
        var authorizations = 0
        var clears = 0
        var changes = 0
        let controller = ZAIQuotaSetupController(defaults: defaults, access: .init(
            save: { saved = $0 }, clear: { saved = nil; clears += 1 },
            reauthorize: { authorizations += 1; return saved }))
        controller.changed = { changes += 1 }
        XCTAssertNil(saved)
        XCTAssertEqual(authorizations, 0)
        let success = await controller.save(apiKey: "fixture-key", region: .bigModel)
        XCTAssertTrue(success)
        XCTAssertEqual(saved?.region, .bigModel)
        XCTAssertTrue(controller.hasSavedKey)
        XCTAssertEqual(controller.savedRegion, .bigModel)
        XCTAssertEqual(changes, 1)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String)?.contains("fixture-key") == true })
        await controller.reauthorize()
        XCTAssertEqual(authorizations, 1)
        await controller.forget()
        XCTAssertEqual(clears, 1)
        XCTAssertFalse(controller.hasSavedKey)
        XCTAssertNil(controller.savedRegion)
        XCTAssertEqual(changes, 3)
    }

    func testFailedStoreWritesKeepSetupMetadataAndDoNotSignalAChangedReader() async {
        let suite = "ZAIQuotaSetupTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        enum Failure: Error { case refused }
        let controller = ZAIQuotaSetupController(defaults: defaults, access: .init(
            save: { _ in throw Failure.refused }, clear: { throw Failure.refused }, reauthorize: { nil }))
        var changes = 0
        controller.changed = { changes += 1 }
        let success = await controller.save(apiKey: "fixture-key", region: .zAI)
        XCTAssertFalse(success)
        XCTAssertFalse(controller.hasSavedKey)
        XCTAssertEqual(changes, 0)
        XCTAssertFalse(controller.status?.contains("fixture-key") ?? true)
        await controller.forget()
        XCTAssertEqual(changes, 0)
    }
}

private final class ZAIQuotaKeychainFixture: @unchecked Sendable {
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
    var count: Int { lock.lock(); defer { lock.unlock() }; return values.count }
    var services: Set<String> { lock.lock(); defer { lock.unlock() }; return touched }
}
