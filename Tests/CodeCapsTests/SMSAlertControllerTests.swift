import XCTest
import QuotaCore
@testable import CodeCaps

@MainActor
final class SMSAlertControllerTests: XCTestCase {
    private var credentials: TwilioSMSCredentials {
        .init(configuration: .init(accountSID: "AC" + String(repeating: "a", count: 32),
            apiKeySID: "SK" + String(repeating: "b", count: 32),
            messagingServiceSID: "MG" + String(repeating: "c", count: 32), recipient: "+15551234567"),
            apiKeySecret: "fixture-secret")
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suite = "CodeCaps.SMSControllerTests." + UUID().uuidString
        return (UserDefaults(suiteName: suite)!, suite)
    }

    func testConstructionAndDisabledKindsNeverReadKeychain() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = SMSCredentialFixture()
        let controller = SMSAlertController(defaults: defaults, credentialAccess: vault.access)
        XCTAssertEqual(vault.loads, 0)
        XCTAssertNil(controller.deliver(kind: "museCodeBurn", title: "Title", body: "Body", eventID: "event"))
        controller.preferences["anomaly"] = true
        XCTAssertNil(controller.deliver(kind: "anomaly", title: "Title", body: "Body", eventID: "event"))
        XCTAssertEqual(vault.loads, 0)
        XCTAssertFalse(controller.hasSavedSetup)
    }

    func testBlankSecretPreservesMatchingSavedAPIKeyAndChangedKeyRequiresSecret() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = SMSCredentialFixture()
        let controller = SMSAlertController(defaults: defaults, credentialAccess: vault.access)
        let saved = await controller.saveSetup(configuration: credentials.configuration, apiKeySecret: credentials.apiKeySecret)
        XCTAssertTrue(saved)
        var config = credentials.configuration
        config.recipient = "+15557654321"
        let updated = await controller.saveSetup(configuration: config, apiKeySecret: "")
        XCTAssertTrue(updated)
        XCTAssertEqual(vault.credentials?.apiKeySecret, "fixture-secret")
        XCTAssertEqual(vault.credentials?.configuration.recipient, "+15557654321")
        config.apiKeySID = "SK" + String(repeating: "d", count: 32)
        let refused = await controller.saveSetup(configuration: config, apiKeySecret: "")
        XCTAssertFalse(refused)
        XCTAssertEqual(vault.credentials?.configuration.apiKeySID, credentials.configuration.apiKeySID)
        XCTAssertFalse(controller.status?.contains("fixture-secret") ?? true)
        let relaunched = SMSAlertController(defaults: defaults, credentialAccess: vault.access)
        XCTAssertTrue(relaunched.hasSavedSetup)
        XCTAssertEqual(relaunched.configuration?.recipient, "+15557654321")
        XCTAssertFalse(relaunched.preferences["museCodeBurn"])
    }

    func testSMSSendsWhenLocalMethodsAreOffAndDuplicateEventDoesNotReplay() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = SMSCredentialFixture()
        let transport = SMSControllerTransportFixture()
        let coordinator = SMSAlertCoordinator(persistence: .userDefaults(defaults, key: "fixture-history"), client: transport.client)
        let controller = SMSAlertController(defaults: defaults, credentialAccess: vault.access, coordinator: coordinator)
        _ = await controller.saveSetup(configuration: credentials.configuration, apiKeySecret: credentials.apiKeySecret)
        controller.preferences["quotaExhaustion"] = true
        let manager = ResetAlarmManager(defaults: defaults)
        manager.preferences[.quotaExhaustion] = .init(enabled: true, notification: false, popup: false, sound: .silent)
        var delivery: Task<Void, Never>?
        manager.additionalDelivery = { kind, title, body, eventID in
            delivery = controller.deliver(kind: kind.rawValue, title: title, body: body, eventID: eventID)
        }
        manager.deliverUsageAlert(kind: .quotaExhaustion, title: "Quota Exhausted", body: "Fixture", identifier: "stable-event")
        await delivery?.value
        XCTAssertEqual(transport.count, 1)
        XCTAssertEqual(controller.status, "Text accepted by Twilio.")
        let relaunched = SMSAlertController(defaults: defaults, credentialAccess: vault.access,
            coordinator: SMSAlertCoordinator(persistence: .userDefaults(defaults, key: "fixture-history"), client: transport.client))
        XCTAssertEqual(transport.count, 1)
        await relaunched.deliver(kind: "quotaExhaustion", title: "Quota Exhausted", body: "Fixture", eventID: "stable-event")?.value
        XCTAssertEqual(transport.count, 1)
    }

    func testMasterKindOffPreventsAdditionalDelivery() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = ResetAlarmManager(defaults: defaults)
        manager.preferences[.quotaExhaustion] = .init(enabled: false, notification: false, popup: false, sound: .silent)
        manager.additionalDelivery = { _, _, _, _ in XCTFail("Disabled kind cannot deliver SMS") }
        manager.deliverUsageAlert(kind: .quotaExhaustion, title: "Fixture", body: "Fixture", identifier: "event")
    }

    func testDisablingSMSWhileCredentialReadIsPendingCancelsSubmission() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: SMSAlertController.Keys.hasSetup)
        let started = expectation(description: "Credential read began")
        var pending: CheckedContinuation<TwilioSMSCredentials?, Never>?
        let access = SMSCredentialAccess(load: {
            await withCheckedContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
        }, save: { _ in }, clear: {}, reauthorize: { nil })
        let transport = SMSControllerTransportFixture()
        let coordinator = SMSAlertCoordinator(persistence: .init(load: { nil }, save: { _ in }), client: transport.client)
        let controller = SMSAlertController(defaults: defaults, credentialAccess: access, coordinator: coordinator)
        controller.preferences["museCodeBurn"] = true
        let delivery = controller.deliver(kind: "museCodeBurn", title: "Fixture", body: "Fixture", eventID: "event")
        await fulfillment(of: [started], timeout: 1)
        controller.preferences["museCodeBurn"] = false
        pending?.resume(returning: credentials)
        await delivery?.value
        XCTAssertEqual(transport.count, 0)
    }

    func testForgetClearsSetupButKeepsDedupeHistoryAndReauthorizationIsExplicit() async {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let vault = SMSCredentialFixture()
        let controller = SMSAlertController(defaults: defaults, credentialAccess: vault.access)
        _ = await controller.saveSetup(configuration: credentials.configuration, apiKeySecret: credentials.apiKeySecret)
        defaults.set(Data("fixture-history".utf8), forKey: SMSAlertController.Keys.history)
        XCTAssertEqual(vault.reauthorizations, 0)
        await controller.reauthorizeSavedSetup()
        XCTAssertEqual(vault.reauthorizations, 1)
        await controller.forgetSetup()
        XCTAssertFalse(controller.hasSavedSetup)
        XCTAssertNil(controller.configuration)
        XCTAssertNil(vault.credentials)
        XCTAssertNotNil(defaults.data(forKey: SMSAlertController.Keys.history))
    }
}

@MainActor
private final class SMSCredentialFixture {
    var credentials: TwilioSMSCredentials?
    var loads = 0
    var reauthorizations = 0
    var access: SMSCredentialAccess {
        .init(load: { self.loads += 1; return self.credentials },
              save: { self.credentials = $0 }, clear: { self.credentials = nil },
              reauthorize: { self.reauthorizations += 1; return self.credentials })
    }
}

private final class SMSControllerTransportFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
    private func increment() {
        lock.lock(); defer { lock.unlock() }
        requests += 1
    }
    var client: TwilioSMSClient {
        TwilioSMSClient(transport: { request in
            self.increment()
            return (Data(#"{"sid":"SMdddddddddddddddddddddddddddddddd","status":"queued"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        })
    }
}
