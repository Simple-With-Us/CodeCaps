import XCTest
import QuotaCore
@testable import CodeCaps

/// The Keychain seam: an in-memory fake keeps these tests off the real
/// Keychain entirely.
final class InfisicalIdentityStoreTests: XCTestCase {
    private var vault: [String: String] = [:]
    private var savedCalls: InfisicalIdentityStore.KeychainCalls!

    override func setUp() {
        super.setUp()
        savedCalls = InfisicalIdentityStore.calls
        InfisicalIdentityStore.calls = InfisicalIdentityStore.KeychainCalls(
            read: { [weak self] service, account in
                guard let self else { return nil }
                return self.vault["\(service)/\(account)"]
            },
            save: { [weak self] service, account, value in
                self?.vault["\(service)/\(account)"] = value
            },
            delete: { [weak self] service, account in
                self?.vault.removeValue(forKey: "\(service)/\(account)")
            }
        )
    }

    override func tearDown() {
        InfisicalIdentityStore.calls = savedCalls
        vault = [:]
        super.tearDown()
    }

    func testLoadIsNilBeforeProvisioning() {
        XCTAssertNil(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"))
    }

    func testSaveThenLoadRoundTrips() throws {
        let identity = InfisicalIdentityStore.Identity(clientId: "cid-1", clientSecret: "csec-1")
        try InfisicalIdentityStore.save(identity, bundleIdentifier: "com.jays.agent-bar.mac.test")
        XCTAssertEqual(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"), identity)
    }

    func testDeleteRemovesTheIdentity() throws {
        let identity = InfisicalIdentityStore.Identity(clientId: "cid-1", clientSecret: "csec-1")
        try InfisicalIdentityStore.save(identity, bundleIdentifier: "com.jays.agent-bar.mac.test")
        try InfisicalIdentityStore.delete(bundleIdentifier: "com.jays.agent-bar.mac.test")
        XCTAssertNil(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"))
    }

    func testHalfWrittenIdentityReadsAsAbsent() {
        // Only the client ID made it in (e.g. the save was interrupted):
        // the store must not hand out a half identity.
        vault["com.jays.agent-bar.mac.test.infisical-identity/client-id"] = "cid-1"
        XCTAssertNil(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"))
    }

    func testServiceNameFollowsTheBuildsBundleIdentifier() {
        XCTAssertEqual(
            InfisicalIdentityStore.serviceName(bundleIdentifier: "com.jays.agent-bar.mac"),
            "com.jays.agent-bar.mac.infisical-identity"
        )
        XCTAssertEqual(
            InfisicalIdentityStore.serviceName(bundleIdentifier: "com.jays.agent-bar.mac.dev"),
            "com.jays.agent-bar.mac.dev.infisical-identity"
        )
        // A `.dev` build's identity can never collide with the owner's.
        XCTAssertNotEqual(
            InfisicalIdentityStore.serviceName(bundleIdentifier: "com.jays.agent-bar.mac.dev"),
            InfisicalIdentityStore.serviceName(bundleIdentifier: "com.jays.agent-bar.mac")
        )
    }
    func testLegacyIdentityUsesDefaultProjectWithoutRewritingKeychain() {
        let service = "com.jays.agent-bar.mac.test.infisical-identity"
        vault["\(service)/client-id"] = "legacy-id"
        vault["\(service)/client-secret"] = "legacy-secret"
        let identity = InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test")
        XCTAssertEqual(identity?.projectId, InfisicalSettings.codeCapsProjectId)
        XCTAssertEqual(identity?.clientId, "legacy-id")
        XCTAssertNil(vault["\(service)/setup-v1"])
    }

    func testProjectAndIdentityPersistAsOneAtomicRecord() throws {
        let identity = InfisicalIdentityStore.Identity(clientId: "new-id", clientSecret: "new-secret", projectId: "project-B")
        try InfisicalIdentityStore.save(identity, bundleIdentifier: "com.jays.agent-bar.mac.test")
        XCTAssertEqual(vault.count, 1)
        XCTAssertEqual(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"), identity)
    }

    func testFailedSavePreservesPreviousIdentityAndProject() throws {
        let old = InfisicalIdentityStore.Identity(clientId: "old-id", clientSecret: "old-secret", projectId: "project-A")
        try InfisicalIdentityStore.save(old, bundleIdentifier: "com.jays.agent-bar.mac.test")
        InfisicalIdentityStore.calls.save = { _, _, _ in throw InfisicalIdentityStore.StoreError.keychain(status: -1) }
        XCTAssertThrowsError(try InfisicalIdentityStore.save(
            .init(clientId: "new-id", clientSecret: "new-secret", projectId: "project-B"),
            bundleIdentifier: "com.jays.agent-bar.mac.test"))
        XCTAssertEqual(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"), old)
    }

    func testForgetLegacyIdentityCannotResurrectIt() throws {
        let service = "com.jays.agent-bar.mac.test.infisical-identity"
        vault["\(service)/client-id"] = "legacy-id"
        vault["\(service)/client-secret"] = "legacy-secret"
        try InfisicalIdentityStore.delete(bundleIdentifier: "com.jays.agent-bar.mac.test")
        XCTAssertNil(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"))
        XCTAssertNil(vault["\(service)/client-id"])
        XCTAssertNil(vault["\(service)/client-secret"])
        XCTAssertNotNil(vault["\(service)/setup-v1"])
    }

    func testFailedLegacyDeleteLeavesCompleteActiveIdentity() throws {
        let service = "com.jays.agent-bar.mac.test.infisical-identity"
        vault["\(service)/client-id"] = "legacy-id"
        vault["\(service)/client-secret"] = "legacy-secret"
        InfisicalIdentityStore.calls.delete = { [weak self] service, account in
            if account == "client-secret" { throw InfisicalIdentityStore.StoreError.keychain(status: -1) }
            self?.vault.removeValue(forKey: "\(service)/\(account)")
        }
        XCTAssertThrowsError(try InfisicalIdentityStore.delete(bundleIdentifier: "com.jays.agent-bar.mac.test"))
        XCTAssertEqual(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test")?.clientSecret, "legacy-secret")
    }

    func testLegacyReadFailureAbortsForgetBeforeDeletingAnything() {
        InfisicalIdentityStore.calls.read = { _, account in
            if account == "setup-v1" { return nil }
            if account == "client-id" { return "legacy-id" }
            throw InfisicalIdentityStore.StoreError.keychain(status: -1)
        }
        InfisicalIdentityStore.calls.delete = { _, _ in XCTFail("Must not delete unreadable legacy setup") }
        InfisicalIdentityStore.calls.save = { _, _, _ in XCTFail("Must not replace unreadable legacy setup") }
        XCTAssertThrowsError(try InfisicalIdentityStore.delete(bundleIdentifier: "com.jays.agent-bar.mac.test"))
    }

    func testNewRecordReadErrorDoesNotReviveReadableLegacyIdentity() {
        InfisicalIdentityStore.calls.read = { _, account in
            if account == "setup-v1" { throw InfisicalIdentityStore.StoreError.keychain(status: -1) }
            return account == "client-id" ? "legacy-id" : "legacy-secret"
        }
        XCTAssertNil(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"))
        XCTAssertThrowsError(try InfisicalIdentityStore.delete(bundleIdentifier: "com.jays.agent-bar.mac.test"))
    }

    func testCorruptNewRecordDoesNotFallBackToLegacyProject() {
        let service = "com.jays.agent-bar.mac.test.infisical-identity"
        vault["\(service)/client-id"] = "legacy-id"
        vault["\(service)/client-secret"] = "legacy-secret"
        vault["\(service)/setup-v1"] = "not-json"
        XCTAssertNil(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"))
    }

}
