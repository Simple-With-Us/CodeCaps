import XCTest
@testable import QuotaCore

final class SMSAlertCoordinatorTests: XCTestCase {
    private var credentials: TwilioSMSCredentials {
        .init(configuration: .init(accountSID: "AC" + String(repeating: "a", count: 32),
            apiKeySID: "SK" + String(repeating: "b", count: 32),
            messagingServiceSID: "MG" + String(repeating: "c", count: 32), recipient: "+15551234567"),
            apiKeySecret: "fixture-secret")
    }
    private let preferences = SMSAlertPreferences(enabledKinds: ["museCodeBurn"])

    func testReservationIsSavedBeforeSendAndSurvivesRelaunch() async {
        let disk = SMSHistoryFixture()
        let client = TwilioSMSClient(transport: { request in
            XCTAssertNotNil(disk.read())
            disk.recordRequest()
            return (Data(#"{"sid":"SMdddddddddddddddddddddddddddddddd","status":"queued"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        })
        let coordinator = SMSAlertCoordinator(persistence: disk.persistence, client: client)
        let first = await coordinator.send(eventID: "stable-event", kind: "museCodeBurn", title: "Burn", body: "Fixture",
                                           preferences: preferences, credentials: credentials)
        XCTAssertEqual(first, .accepted)
        let relaunched = SMSAlertCoordinator(persistence: disk.persistence, client: client)
        let repeatSend = await relaunched.send(eventID: "stable-event", kind: "museCodeBurn", title: "Burn", body: "Fixture",
                                               preferences: preferences, credentials: credentials)
        XCTAssertEqual(repeatSend, .duplicate)
        XCTAssertEqual(disk.requestCount, 1)
        XCTAssertFalse(String(data: disk.read()!, encoding: .utf8)!.contains("stable-event"))
    }

    func testUncertainOutcomeRemainsReservedAndConcurrentDuplicatesSendOnlyOnce() async {
        let disk = SMSHistoryFixture()
        let client = TwilioSMSClient(transport: { _ in
            disk.recordRequest()
            await Task.yield()
            throw URLError(.timedOut)
        })
        let coordinator = SMSAlertCoordinator(persistence: disk.persistence, client: client)
        async let first = coordinator.send(eventID: "same", kind: "museCodeBurn", title: "Burn", body: "Fixture",
                                            preferences: preferences, credentials: credentials)
        async let second = coordinator.send(eventID: "same", kind: "museCodeBurn", title: "Burn", body: "Fixture",
                                             preferences: preferences, credentials: credentials)
        let results = await [first, second]
        XCTAssertTrue(results.contains(.duplicate))
        XCTAssertTrue(results.contains(.failed(.uncertain)))
        XCTAssertEqual(disk.requestCount, 1)
        let relaunched = SMSAlertCoordinator(persistence: disk.persistence, client: client)
        let repeatSend = await relaunched.send(eventID: "same", kind: "museCodeBurn", title: "Burn", body: "Fixture",
                                               preferences: preferences, credentials: credentials)
        XCTAssertEqual(repeatSend, .duplicate)
    }

    func testDisabledUnconfiguredAndCorruptPersistenceNeverSend() async {
        let disk = SMSHistoryFixture()
        let client = TwilioSMSClient(transport: { _ in
            XCTFail("No network call should be attempted")
            throw URLError(.badURL)
        })
        let coordinator = SMSAlertCoordinator(persistence: disk.persistence, client: client)
        let disabled = await coordinator.send(eventID: "event", kind: "anomaly", title: "Fixture", body: "Fixture",
                                              preferences: .init(enabledKinds: ["anomaly"]), credentials: credentials)
        XCTAssertEqual(disabled, .disabled)
        let unconfigured = await coordinator.send(eventID: "event", kind: "museCodeBurn", title: "Fixture", body: "Fixture",
                                                  preferences: preferences, credentials: nil)
        XCTAssertEqual(unconfigured, .failed(.invalidConfiguration))
        let corrupt = SMSAlertCoordinator(persistence: .init(load: { Data("broken".utf8) }, save: { _ in }), client: client)
        let failed = await corrupt.send(eventID: "event", kind: "museCodeBurn", title: "Fixture", body: "Fixture",
                                         preferences: preferences, credentials: credentials)
        XCTAssertEqual(failed, .failed(.persistence))
        let writeFailure = SMSAlertCoordinator(persistence: .init(load: { nil }, save: { _ in throw URLError(.cannotWriteToFile) }), client: client)
        let failedWrite = await writeFailure.send(eventID: "event", kind: "museCodeBurn", title: "Fixture", body: "Fixture",
                                                  preferences: preferences, credentials: credentials)
        XCTAssertEqual(failedWrite, .failed(.persistence))
    }

    func testFullHistoryFailsClosedRatherThanEvictingDedupeIDs() async {
        let disk = SMSHistoryFixture()
        let client = TwilioSMSClient(transport: { request in
            disk.recordRequest()
            return (Data(#"{"sid":"SMdddddddddddddddddddddddddddddddd","status":"queued"}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        })
        let coordinator = SMSAlertCoordinator(persistence: disk.persistence, client: client, maximumReservations: 1)
        _ = await coordinator.send(eventID: "first", kind: "museCodeBurn", title: "Burn", body: "Fixture",
                                    preferences: preferences, credentials: credentials)
        let full = await coordinator.send(eventID: "second", kind: "museCodeBurn", title: "Burn", body: "Fixture",
                                          preferences: preferences, credentials: credentials)
        XCTAssertEqual(full, .failed(.capacity))
        XCTAssertEqual(disk.requestCount, 1)
    }
}

private final class SMSHistoryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var requests = 0
    var persistence: SMSAlertPersistence {
        .init(load: { self.read() }, save: { self.write($0) })
    }
    func read() -> Data? {
        lock.lock(); defer { lock.unlock() }
        return data
    }
    func write(_ value: Data) {
        lock.lock(); defer { lock.unlock() }
        data = value
    }
    func recordRequest() {
        lock.lock(); defer { lock.unlock() }
        requests += 1
    }
    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }
}
