import XCTest
@testable import QuotaCore

final class TwilioSMSClientTests: XCTestCase {
    private var credentials: TwilioSMSCredentials {
        .init(configuration: .init(accountSID: "AC" + String(repeating: "a", count: 32),
            apiKeySID: "SK" + String(repeating: "b", count: 32),
            messagingServiceSID: "MG" + String(repeating: "c", count: 32), recipient: "+15551234567"),
            apiKeySecret: "fixture-secret")
    }

    func testSMSIsOffByDefaultAndUnknownKindsCannotBeEnabled() throws {
        var preferences = SMSAlertPreferences()
        for kind in SMSAlertPreferences.eligibleKinds { XCTAssertFalse(preferences[kind]) }
        preferences["anomaly"] = true
        XCTAssertFalse(preferences["anomaly"])
        preferences["museCodeBurn"] = true
        let restored = try JSONDecoder().decode(SMSAlertPreferences.self, from: JSONEncoder().encode(preferences))
        XCTAssertTrue(restored["museCodeBurn"])
        XCTAssertFalse(restored["quotaExhaustion"])
    }

    func testFixedEndpointAPIKeyAuthenticationAndFormEncoding() throws {
        let request = try TwilioSMSClient.request(title: "Session & burn", body: "+ quota = 1", credentials: credentials)
        XCTAssertEqual(request.url?.host, "api.twilio.com")
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.path, "/2010-04-01/Accounts/\(credentials.configuration.accountSID)/Messages.json")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"),
                       "Basic " + Data((credentials.configuration.apiKeySID + ":fixture-secret").utf8).base64EncodedString())
        let form = String(data: request.httpBody!, encoding: .utf8)!
        XCTAssertTrue(form.contains("To=%2B15551234567"))
        XCTAssertTrue(form.contains("MessagingServiceSid=MG"))
        XCTAssertTrue(form.contains("Session%20%26%20burn%0A%2B%20quota%20%3D%201"))
        XCTAssertFalse(form.contains("fixture-secret"))
    }

    func testFormEncodingEscapesUnicodeAsUTF8Bytes() throws {
        let request = try TwilioSMSClient.request(title: "café ☃️", body: "naïve", credentials: credentials)
        let form = try XCTUnwrap(String(data: try XCTUnwrap(request.httpBody), encoding: .utf8))
        XCTAssertTrue(form.contains("CodeCaps%3A%20caf%C3%A9%20%E2%98%83%EF%B8%8F%0Ana%C3%AFve"))
    }

    func testMessageIsBoundedAndInvalidConfigurationNeverCreatesARequest() throws {
        let request = try TwilioSMSClient.request(title: String(repeating: "x", count: 500), body: "body", credentials: credentials)
        let form = String(data: request.httpBody!, encoding: .utf8)!
        let body = form.components(separatedBy: "&Body=")[1].removingPercentEncoding!
        XCTAssertEqual(body.count, 240)
        var invalid = credentials
        invalid.configuration.accountSID = "../another-account"
        XCTAssertThrowsError(try TwilioSMSClient.request(title: "title", body: "body", credentials: invalid))
        invalid = credentials
        invalid.configuration.recipient = "5551234567"
        XCTAssertThrowsError(try invalid.validate())
        invalid = credentials
        invalid.apiKeySecret = "secret\nheader"
        XCTAssertThrowsError(try invalid.validate())
    }

    func testQueuedReceiptIsAcceptedWithoutClaimingDelivery() async throws {
        let client = TwilioSMSClient(transport: { request in
            let data = Data(#"{"sid":"SMdddddddddddddddddddddddddddddddd","status":"queued"}"#.utf8)
            return (data, HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
        })
        try await client.send(title: "title", body: "body", credentials: credentials)
    }

    func testRedirectDelegateRefusesCredentialForwardingWithoutStartingATask() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://api.twilio.com/example")!
        let task = session.dataTask(with: url)
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil,
                                       headerFields: ["Location": "https://example.invalid/"])!
        var completionCalled = false
        NoSMSRedirects().urlSession(session, task: task, willPerformHTTPRedirection: response,
                                    newRequest: URLRequest(url: URL(string: "https://example.invalid/")!)) { request in
            XCTAssertNil(request)
            completionCalled = true
        }
        XCTAssertTrue(completionCalled)
    }

    func testMalformedAndFailedReceiptsCannotClaimAcceptance() async {
        for responseBody in ["not-json", #"{"sid":"SMdddddddddddddddddddddddddddddddd","status":"failed"}"#] {
            let client = TwilioSMSClient(transport: { request in
                (Data(responseBody.utf8), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!)
            })
            do {
                try await client.send(title: "title", body: "body", credentials: credentials)
                XCTFail("Malformed or failed receipt must not be accepted")
            } catch {
                XCTAssertNotNil(error as? TwilioSMSFailure)
                XCTAssertFalse(error.localizedDescription.contains(responseBody))
            }
        }
    }

    func testErrorsAreSanitizedAndNeverRetried() async {
        for (status, expected) in [(401, TwilioSMSFailure.authentication), (429, .rateLimited),
                                    (503, .serviceUnavailable), (302, .rejected), (400, .rejected)] {
            let counter = SMSRequestCounter()
            let client = TwilioSMSClient(transport: { request in
                await counter.increment()
                return (Data("private phone and token".utf8),
                        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            })
            do {
                try await client.send(title: "title", body: "body", credentials: credentials)
                XCTFail("Expected sanitized failure")
            } catch { XCTAssertEqual(error as? TwilioSMSFailure, expected) }
            let count = await counter.count
            XCTAssertEqual(count, 1)
        }
    }
}

private actor SMSRequestCounter {
    var count = 0
    func increment() { count += 1 }
}
