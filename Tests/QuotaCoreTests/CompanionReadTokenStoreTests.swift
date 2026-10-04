import Foundation
import Security
import XCTest
@testable import QuotaCore

final class CompanionReadTokenStoreTests: XCTestCase {
    private var suiteNames: [String] = []

    override func tearDown() {
        suiteNames.forEach { UserDefaults(suiteName: $0)?.removePersistentDomain(forName: $0) }
        suiteNames.removeAll()
        super.tearDown()
    }

    private final class FakeKeychain {
        var data: Data?
        var readFailure: OSStatus?
        var writeFailure: OSStatus?
        var removeFailure: OSStatus?
        var writes = 0

        var calls: CompanionReadTokenStore.Calls {
            .init(
                read: { _ in
                    if let readFailure = self.readFailure { return (readFailure, nil) }
                    guard let data = self.data else { return (errSecItemNotFound, nil) }
                    return (errSecSuccess, data)
                },
                write: { _, data in
                    self.writes += 1
                    if let writeFailure = self.writeFailure { return writeFailure }
                    self.data = data
                    return errSecSuccess
                },
                remove: { _ in
                    if let removeFailure = self.removeFailure { return removeFailure }
                    self.data = nil
                    return errSecSuccess
                }
            )
        }
    }

    private func defaults() -> UserDefaults {
        let name = "CompanionReadTokenStoreTests.\(UUID().uuidString)"
        suiteNames.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testMigrationWritesKeychainBeforeDeletingBothPreferences() {
        let shared = defaults()
        let standard = defaults()
        shared.set("fixture-token", forKey: CompanionReadTokenStore.legacyKey)
        standard.set("older-token", forKey: CompanionReadTokenStore.legacyKey)
        let fake = FakeKeychain()
        let store = CompanionReadTokenStore(accessGroup: "fixture.group", calls: fake.calls)

        XCTAssertEqual(store.loadAndMigrate(shared: shared, standard: standard), .token("fixture-token"))
        XCTAssertEqual(fake.data, Data("fixture-token".utf8))
        XCTAssertNil(shared.object(forKey: CompanionReadTokenStore.legacyKey))
        XCTAssertNil(standard.object(forKey: CompanionReadTokenStore.legacyKey))
        XCTAssertEqual(store.readForWidget(shared: shared), .token("fixture-token"))
    }

    func testFailedMigrationRetainsLegacyValueForAppAndWidget() {
        let shared = defaults()
        let standard = defaults()
        shared.set("fixture-token", forKey: CompanionReadTokenStore.legacyKey)
        standard.set("fixture-token", forKey: CompanionReadTokenStore.legacyKey)
        let fake = FakeKeychain()
        fake.writeFailure = errSecInteractionNotAllowed
        let store = CompanionReadTokenStore(accessGroup: "fixture.group", calls: fake.calls)

        XCTAssertEqual(store.loadAndMigrate(shared: shared, standard: standard),
                       .legacy("fixture-token", errSecInteractionNotAllowed))
        XCTAssertEqual(shared.string(forKey: CompanionReadTokenStore.legacyKey), "fixture-token")
        XCTAssertEqual(standard.string(forKey: CompanionReadTokenStore.legacyKey), "fixture-token")
        XCTAssertEqual(store.readForWidget(shared: shared), .legacy("fixture-token", errSecItemNotFound))
    }

    func testKeychainReadFailureDoesNotDeleteOrRewriteLegacyValue() {
        let shared = defaults()
        let standard = defaults()
        shared.set("fixture-token", forKey: CompanionReadTokenStore.legacyKey)
        let fake = FakeKeychain()
        fake.readFailure = errSecInteractionNotAllowed
        let store = CompanionReadTokenStore(accessGroup: "fixture.group", calls: fake.calls)

        XCTAssertEqual(store.loadAndMigrate(shared: shared, standard: standard),
                       .legacy("fixture-token", errSecInteractionNotAllowed))
        XCTAssertEqual(fake.writes, 0)
        XCTAssertEqual(shared.string(forKey: CompanionReadTokenStore.legacyKey), "fixture-token")
        XCTAssertEqual(store.readForWidget(shared: shared),
                       .legacy("fixture-token", errSecInteractionNotAllowed))
    }

    func testExistingKeychainTokenIsAuthoritativeAndRemovesStalePreferences() {
        let shared = defaults()
        let standard = defaults()
        shared.set("stale-token", forKey: CompanionReadTokenStore.legacyKey)
        standard.set("stale-token", forKey: CompanionReadTokenStore.legacyKey)
        let fake = FakeKeychain()
        fake.data = Data("saved-token".utf8)
        let store = CompanionReadTokenStore(accessGroup: "fixture.group", calls: fake.calls)

        XCTAssertEqual(store.loadAndMigrate(shared: shared, standard: standard), .token("saved-token"))
        XCTAssertEqual(fake.writes, 0)
        XCTAssertNil(shared.object(forKey: CompanionReadTokenStore.legacyKey))
        XCTAssertNil(standard.object(forKey: CompanionReadTokenStore.legacyKey))
    }

    func testExplicitRemovalDeletesKeychainAndBothLegacyValues() {
        let shared = defaults()
        let standard = defaults()
        shared.set("fixture-token", forKey: CompanionReadTokenStore.legacyKey)
        standard.set("fixture-token", forKey: CompanionReadTokenStore.legacyKey)
        let fake = FakeKeychain()
        fake.data = Data("fixture-token".utf8)
        let store = CompanionReadTokenStore(accessGroup: "fixture.group", calls: fake.calls)

        XCTAssertEqual(store.save("", shared: shared, standard: standard), errSecSuccess)
        XCTAssertEqual(store.readForWidget(shared: shared), .missing)
        XCTAssertNil(shared.object(forKey: CompanionReadTokenStore.legacyKey))
        XCTAssertNil(standard.object(forKey: CompanionReadTokenStore.legacyKey))
    }

    func testFailedRemovalPreservesKeychainAndLegacyValues() {
        let shared = defaults()
        let standard = defaults()
        shared.set("fixture-token", forKey: CompanionReadTokenStore.legacyKey)
        let fake = FakeKeychain()
        fake.data = Data("fixture-token".utf8)
        fake.removeFailure = errSecInteractionNotAllowed
        let store = CompanionReadTokenStore(accessGroup: "fixture.group", calls: fake.calls)

        XCTAssertEqual(store.save("", shared: shared, standard: standard), errSecInteractionNotAllowed)
        XCTAssertEqual(store.readForWidget(shared: shared), .token("fixture-token"))
        XCTAssertEqual(shared.string(forKey: CompanionReadTokenStore.legacyKey), "fixture-token")
    }
}
