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
        let identity = InfisicalIdentityStore.Identity(clientId: "cid-1", clientSecret: "csec-1", projectId: "project-A")
        try InfisicalIdentityStore.save(identity, bundleIdentifier: "com.jays.agent-bar.mac.test")
        XCTAssertEqual(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"), identity)
    }

    func testDeleteRemovesTheIdentity() throws {
        let identity = InfisicalIdentityStore.Identity(clientId: "cid-1", clientSecret: "csec-1", projectId: "project-A")
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
    func testLegacyIdentityRequiresExplicitProjectSetup() {
        let service = "com.jays.agent-bar.mac.test.infisical-identity"
        vault["\(service)/client-id"] = "legacy-id"
        vault["\(service)/client-secret"] = "legacy-secret"
        XCTAssertNil(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"))
        XCTAssertNil(vault["\(service)/setup-v1"])
    }

    func testBlankProjectCannotBePersisted() {
        XCTAssertThrowsError(try InfisicalIdentityStore.save(
            .init(clientId: "id", clientSecret: "secret", projectId: " \n"),
            bundleIdentifier: "com.jays.agent-bar.mac.test"))
        XCTAssertTrue(vault.isEmpty)
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

    func testFailedDeletePreservesCompleteSetup() throws {
        let old = InfisicalIdentityStore.Identity(clientId: "old-id", clientSecret: "old-secret", projectId: "project-A")
        try InfisicalIdentityStore.save(old, bundleIdentifier: "com.jays.agent-bar.mac.test")
        InfisicalIdentityStore.calls.delete = { _, _ in throw InfisicalIdentityStore.StoreError.keychain(status: -1) }
        XCTAssertThrowsError(try InfisicalIdentityStore.delete(bundleIdentifier: "com.jays.agent-bar.mac.test"))
        XCTAssertEqual(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"), old)
    }

    func testRecordReadErrorDoesNotActivateLegacyIdentity() {
        InfisicalIdentityStore.calls.read = { _, account in
            XCTAssertEqual(account, "setup-v1")
            throw InfisicalIdentityStore.StoreError.keychain(status: -1)
        }
        XCTAssertNil(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"))
    }

    func testCorruptNewRecordDoesNotFallBackToLegacyProject() {
        let service = "com.jays.agent-bar.mac.test.infisical-identity"
        vault["\(service)/client-id"] = "legacy-id"
        vault["\(service)/client-secret"] = "legacy-secret"
        vault["\(service)/setup-v1"] = "not-json"
        XCTAssertNil(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"))
    }

    func testV1MigrationPreservesMachineReadsButNeverInfersWriteAccess() throws {
        let service = "com.jays.agent-bar.mac.test.infisical-identity"
        let legacy = #"{"version":1,"identity":{"clientId":"legacy-id","clientSecret":"legacy-secret","projectId":"project-A"}}"#
        vault["\(service)/setup-v1"] = legacy
        let setup = try XCTUnwrap(InfisicalIdentityStore.loadSetup(bundleIdentifier: "com.jays.agent-bar.mac.test"))
        XCTAssertEqual(setup.bindings.count, 1)
        XCTAssertEqual(setup.configuration?.readBinding.authentication, .machineIdentity)
        XCTAssertEqual(setup.configuration?.readBinding.environment, "prod")
        XCTAssertEqual(setup.configuration?.readBinding.secretPath, "/")
        XCTAssertEqual(setup.configuration?.readBinding.clientSecret, "legacy-secret")
        XCTAssertNil(setup.writeBindingID)
        XCTAssertNil(setup.configuration?.writeBinding)
        XCTAssertEqual(vault["\(service)/setup-v1"], legacy, "Startup migration must not rewrite working credentials")
    }

    func testV2RetainsMultipleScopesAndIndependentSelectionsInOneKeychainRecord() throws {
        let read = InfisicalBinding(id: "read", label: "Project A Read", projectId: "project-A", environment: "qa",
            secretPath: "/codecaps", access: .read, serviceToken: "st.fixture.read-secret")
        var write = read
        write.id = "write"; write.label = "Project A Write"; write.access = .write; write.serviceToken = "st.fixture.write-secret"
        let other = InfisicalBinding(id: "other", label: "Other Project", projectId: "project-B", environment: "prod",
            secretPath: "/shared", access: .read, serviceToken: "st.fixture.other-secret")
        let setup = InfisicalSetup(bindings: [read, write, other], readBindingID: read.id, writeBindingID: write.id)
        try InfisicalIdentityStore.saveSetup(setup, bundleIdentifier: "com.jays.agent-bar.mac.test")
        XCTAssertEqual(InfisicalIdentityStore.loadSetup(bundleIdentifier: "com.jays.agent-bar.mac.test"), setup)
        XCTAssertEqual(vault.count, 1)
        XCTAssertNil(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"))
    }

    func testMismatchedWriteBindingNeverReplacesTheSavedSetup() throws {
        let identity = InfisicalIdentityStore.Identity(clientId: "id", clientSecret: "secret", projectId: "project-A")
        try InfisicalIdentityStore.save(identity, bundleIdentifier: "com.jays.agent-bar.mac.test")
        var setup = try XCTUnwrap(InfisicalIdentityStore.loadSetup(bundleIdentifier: "com.jays.agent-bar.mac.test"))
        var write = setup.bindings[0]
        write.id = "write"; write.access = .write; write.secretPath = "/another-folder"
        setup.bindings.append(write); setup.writeBindingID = write.id
        XCTAssertThrowsError(try InfisicalIdentityStore.saveSetup(setup, bundleIdentifier: "com.jays.agent-bar.mac.test"))
        XCTAssertEqual(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"), identity)
    }

}
