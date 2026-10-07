import Foundation
@testable import QuotaCore
import XCTest

private final class MockSyncProtocol: URLProtocol, @unchecked Sendable {
    static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = MockSyncProtocol.requestHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class QuotaPublisherTests: XCTestCase {
    override func tearDown() {
        MockSyncProtocol.requestHandler = nil
        super.tearDown()
    }

    private func makeSampleWindows() -> [QuotaWindow] {
        [
            QuotaWindow(
                id: "anthropic-5h",
                provider: "anthropic",
                providerKey: "anthropic",
                providerLabel: "Anthropic",
                via: nil,
                sourceApp: nil,
                modelId: nil,
                modelType: nil,
                label: "Claude 5h",
                remainingPercent: 85.0,
                absoluteRemaining: nil,
                absoluteLimit: nil,
                quotaUnit: nil,
                planName: "Claude Max",
                remainingUnknown: false,
                isExhausted: false,
                resetAt: "2026-09-14T22:00:00Z",
                window: "5h",
                status: .available,
                skip: false,
                skipReason: nil,
                occurredAt: "2026-09-14T19:00:00Z",
                source: "local"
            ),
            QuotaWindow(
                id: "codex-weekly",
                provider: "openai",
                providerKey: "openai",
                providerLabel: "OpenAI",
                via: nil,
                sourceApp: nil,
                modelId: nil,
                modelType: nil,
                label: "Codex Weekly",
                remainingPercent: 12.0,
                absoluteRemaining: nil,
                absoluteLimit: nil,
                quotaUnit: nil,
                planName: nil,
                remainingUnknown: false,
                isExhausted: false,
                resetAt: "2026-09-15T00:00:00Z",
                window: "weekly",
                status: .nearCap,
                skip: false,
                skipReason: nil,
                occurredAt: "2026-09-14T19:00:00Z",
                source: "local"
            )
        ]
    }

    private func acknowledgment(
        received: Int = 2, persisted: Int = 2, duplicates: Int = 0,
        pruned: Int = 0, rejected: Int = 0
    ) -> [String: Any] {
        [
            "ok": true, "schemaVersion": 2, "received": received,
            "persisted": persisted, "duplicates": duplicates,
            "pruned": pruned, "rejected": rejected
        ]
    }

    private func requestEvents(_ request: URLRequest) throws -> [[String: Any]] {
        let data: Data
        if let body = request.httpBody {
            data = body
        } else {
            let stream = try XCTUnwrap(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeRawData) }
                if count == 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            data = body
        }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(payload["events"] as? [[String: Any]])
    }

    private func assertInvalidAcknowledgment(
        _ data: Data, statusCode: Int = 200, message: String? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        MockSyncProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
        let publisher = QuotaPublisher(urlProtocolClasses: [MockSyncProtocol.self])
        do {
            _ = try await publisher.publish(windows: makeSampleWindows(), to: URL(string: "https://usage.example.com/api/ingest/usage")!)
            XCTFail("Expected acknowledgment failure", file: file, line: line)
        } catch let error as QuotaPublisherError {
            guard case let .serverError(detail) = error else {
                XCTFail("Unexpected publisher error: \(error)", file: file, line: line)
                return
            }
            if let message {
                XCTAssertTrue(detail.contains(message), "Unexpected acknowledgment error: \(detail)", file: file, line: line)
            }
            XCTAssertFalse(detail.contains("private-server-detail"), file: file, line: line)
        } catch {
            XCTFail("Unexpected error: \(error)", file: file, line: line)
        }
    }

    func testBuildUsageMonitorV2Payload() throws {
        let publisher = QuotaPublisher()
        let windows = makeSampleWindows()
        let data = try publisher.buildUsageMonitorV2Payload(windows: windows, occurredAtIso: "2026-09-14T19:00:00Z", machineName: "Test-Mac", producerInstanceId: "test-instance")
        
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schemaVersion"] as? Int, 2)
        XCTAssertEqual(json["producerId"] as? String, "codecaps")
        XCTAssertEqual(json["producerInstanceId"] as? String, "test-instance")

        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)

        let first = events[0]
        XCTAssertEqual(first["provider"] as? String, "anthropic")
        XCTAssertEqual(first["service"] as? String, "codecaps")
        XCTAssertEqual(first["label"] as? String, "Claude 5h")
        XCTAssertEqual(first["metricType"] as? String, "quota")
        XCTAssertEqual(first["limit"] as? Int, 100)
        XCTAssertEqual(first["credits"] as? Double, 85.0)
        XCTAssertEqual(first["tier"] as? String, "Claude Max")

        let meta = try XCTUnwrap(first["metadata"] as? [String: Any])
        XCTAssertEqual(meta["machine"] as? String, "Test-Mac")
        XCTAssertEqual(meta["bucketId"] as? String, "5h")
        XCTAssertEqual(meta["quotaWindow"] as? String, "5h")
        XCTAssertEqual(meta["resetAt"] as? String, "2026-09-14T22:00:00Z")
        XCTAssertEqual(meta["source"] as? String, "codecaps")
        XCTAssertEqual(meta["usedPercent"] as? Double, 15.0)
    }

    /// The v2 schema is strict (`additionalProperties: false`), and one extra
    /// key at the batch or event level fails the whole POST with HTTP 400
    /// "Invalid usage telemetry v2 batch" before any event is inspected.  That
    /// is how `machine` at the batch root, and `machine` plus
    /// `producerInstanceId` on the event, silently broke every push while
    /// looking like a server outage.
    func testV2PayloadCarriesNoKeysTheSchemaRejects() throws {
        let publisher = QuotaPublisher()
        let data = try publisher.buildUsageMonitorV2Payload(
            windows: makeSampleWindows(), occurredAtIso: "2026-09-14T19:00:00Z",
            machineName: "Test-Mac", producerInstanceId: "test-instance")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        let allowedRoot: Set<String> = ["schemaVersion", "producerId", "producerInstanceId", "events"]
        for key in json.keys {
            XCTAssertTrue(allowedRoot.contains(key), "batch root carries '\(key)', which the v2 schema rejects")
        }
        // Provenance still has to survive: it belongs in metadata, not beside it.
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        for event in events {
            XCTAssertNil(event["machine"], "event-level 'machine' is rejected as an unrecognized key")
            XCTAssertNil(event["producerInstanceId"], "event-level 'producerInstanceId' is rejected as an unrecognized key")
            let meta = try XCTUnwrap(event["metadata"] as? [String: Any])
            XCTAssertEqual(meta["machine"] as? String, "Test-Mac")
            XCTAssertEqual(meta["producerInstanceId"] as? String, "test-instance")
        }
    }

    func testInstancePersistsAndScopesIdempotency() throws {
        let suite = "codecaps-machine-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let id = QuotaPublisher.persistentInstanceId(defaults: defaults)
        XCTAssertNotNil(UUID(uuidString: id))
        XCTAssertEqual(id, QuotaPublisher.persistentInstanceId(defaults: defaults))
        let publisher = QuotaPublisher()
        func payload(_ instance: String, name: String = "Same Name") throws -> [String: Any] {
            let data = try publisher.buildUsageMonitorV2Payload(windows: makeSampleWindows(), occurredAtIso: "2026-10-03T20:00:00Z", machineName: name, producerInstanceId: instance)
            return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        }
        func events(_ p: [String: Any]) throws -> [String] {
            try XCTUnwrap(p["events"] as? [[String: Any]]).compactMap { $0["eventId"] as? String }
        }
        let first = try events(payload("one"))
        XCTAssertEqual(first, try events(payload("one")))
        XCTAssertEqual(first, try events(payload("one", name: "Renamed")))
        XCTAssertNotEqual(first, try events(payload("two")))
    }

    func testBuildGenericWebhookPayload() throws {
        let publisher = QuotaPublisher()
        let windows = makeSampleWindows()
        let data = try publisher.buildGenericWebhookPayload(windows: windows, occurredAtIso: "2026-09-14T19:00:00Z", machineName: "Test-MacBook")

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["format"] as? String, "codecaps-quotas")
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["machine"] as? String, "Test-MacBook")
        XCTAssertEqual(json["count"] as? Int, 2)

        let list = try XCTUnwrap(json["windows"] as? [[String: Any]])
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["label"] as? String, "Claude 5h")
        XCTAssertEqual(list[0]["remainingPercent"] as? Double, 85.0)
        XCTAssertEqual(list[1]["status"] as? String, "near_cap")
    }

    func testPublishRequiresAllowedEndpoint() async {
        let publisher = QuotaPublisher()
        let windows = makeSampleWindows()
        let invalidUrl = URL(string: "ftp://example.com/api")!

        do {
            _ = try await publisher.publish(windows: windows, to: invalidUrl)
            XCTFail("Expected invalidEndpoint error")
        } catch let err as QuotaPublisherError {
            XCTAssertEqual(err, .invalidEndpoint)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPublishEmptyWindowsFailsFast() async {
        let publisher = QuotaPublisher()
        let url = URL(string: "https://usage.example.com/api/ingest/usage")!

        do {
            _ = try await publisher.publish(windows: [], to: url)
            XCTFail("Expected emptyWindows error")
        } catch let err as QuotaPublisherError {
            XCTAssertEqual(err, .emptyWindows)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testPublishHandlesSuccess() async throws {
        let responseData = try JSONSerialization.data(withJSONObject: acknowledgment())
        MockSyncProtocol.requestHandler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-ingest-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-usage-ingest-token"), "test-ingest-token")

            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            return (response, responseData)
        }

        let publisher = QuotaPublisher(urlProtocolClasses: [MockSyncProtocol.self])
        let windows = makeSampleWindows()
        let url = URL(string: "https://usage.example.com/api/ingest/usage")!

        let result = try await publisher.publish(windows: windows, to: url, token: "test-ingest-token")
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result.message, "Synced 2 quotas (2 persisted, 0 duplicates, 0 pruned).")
    }

    func testPublishRejectsMalformedSuccessfulResponses() async {
        for body in ["", "<html>private-server-detail</html>", "{", "[]", "null", "{}"] {
            await assertInvalidAcknowledgment(Data(body.utf8), message: "invalid v2 acknowledgment")
        }
        await assertInvalidAcknowledgment(Data(), statusCode: 204)
    }

    func testPublishRequiresTypedV2SuccessEnvelope() async throws {
        for key in ["ok", "schemaVersion"] {
            var missing = acknowledgment()
            missing.removeValue(forKey: key)
            await assertInvalidAcknowledgment(try JSONSerialization.data(withJSONObject: missing))
        }
        let invalidFields: [(String, Any)] = [
            ("ok", false), ("ok", 1), ("ok", "true"), ("ok", NSNull()),
            ("schemaVersion", 1), ("schemaVersion", 3), ("schemaVersion", true),
            ("schemaVersion", "2"), ("schemaVersion", 2.5), ("schemaVersion", NSNull())
        ]
        for (key, value) in invalidFields {
            var invalid = acknowledgment()
            invalid[key] = value
            await assertInvalidAcknowledgment(try JSONSerialization.data(withJSONObject: invalid))
        }
    }

    func testPublishRejectsMissingOrInvalidCounts() async throws {
        for key in ["received", "persisted", "duplicates", "pruned", "rejected"] {
            var missing = acknowledgment()
            missing.removeValue(forKey: key)
            await assertInvalidAcknowledgment(try JSONSerialization.data(withJSONObject: missing))
            let invalidValues: [Any] = [true, false, "0", -1, 0.5, NSNull(), [] as [Int], [:] as [String: Int]]
            for value in invalidValues {
                var invalid = acknowledgment()
                invalid[key] = value
                await assertInvalidAcknowledgment(try JSONSerialization.data(withJSONObject: invalid))
            }
        }
        let outOfRange = "{\"ok\":true,\"schemaVersion\":2,\"received\":2,\"persisted\":9223372036854775808,\"duplicates\":0,\"pruned\":0,\"rejected\":0}"
        await assertInvalidAcknowledgment(Data(outOfRange.utf8))
    }

    func testPublishRejectsInconsistentCountsWithoutOverflow() async throws {
        for invalid in [
            acknowledgment(received: 1, persisted: 1),
            acknowledgment(received: 3, persisted: 3),
            acknowledgment(persisted: 1),
            acknowledgment(persisted: 2, duplicates: 1),
            acknowledgment(persisted: Int.max, duplicates: Int.max)
        ] {
            await assertInvalidAcknowledgment(try JSONSerialization.data(withJSONObject: invalid))
        }
    }

    func testPublishReportsPartialAndFullRejectionWithoutServerDetails() async throws {
        for statusCode in [200, 202] {
            for rejected in [1, 2] {
                var response = acknowledgment(persisted: 2 - rejected, rejected: rejected)
                response["rejections"] = [["index": 0, "reason": "private-server-detail"]]
                await assertInvalidAcknowledgment(
                    try JSONSerialization.data(withJSONObject: response),
                    statusCode: statusCode,
                    message: "rejected \(rejected) of 2 quota events"
                )
            }
        }
    }

    func testPublishAcceptsDuplicateAndPrunedDispositions() async throws {
        for (persisted, duplicates, pruned) in [(0, 2, 0), (0, 0, 2), (1, 1, 0), (1, 0, 1), (0, 1, 1)] {
            let data = try JSONSerialization.data(withJSONObject: acknowledgment(persisted: persisted, duplicates: duplicates, pruned: pruned))
            MockSyncProtocol.requestHandler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 202, httpVersion: nil, headerFields: nil)!
                return (response, data)
            }
            let publisher = QuotaPublisher(urlProtocolClasses: [MockSyncProtocol.self])
            let result = try await publisher.publish(windows: makeSampleWindows(), to: URL(string: "https://usage.example.com/api/ingest/usage")!)
            XCTAssertEqual(result.statusCode, 202)
            XCTAssertEqual(result.count, 2)
            XCTAssertEqual(result.message, "Synced 2 quotas (\(persisted) persisted, \(duplicates) duplicates, \(pruned) pruned).")
        }
    }

    func testPublishRetryPreservesEventIdsAndAcceptsDuplicates() async throws {
        // The first request may have persisted even though its ACK is invalid.
        let invalidFirstResponse = Data("{\"ok\":true}".utf8)
        let duplicates = try JSONSerialization.data(withJSONObject: acknowledgment(persisted: 0, duplicates: 2))
        var submittedIds: [[String]] = []
        MockSyncProtocol.requestHandler = { request in
            let events = try self.requestEvents(request)
            submittedIds.append(try events.map { try XCTUnwrap($0["eventId"] as? String) })
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, submittedIds.count == 1 ? invalidFirstResponse : duplicates)
        }
        let publisher = QuotaPublisher(urlProtocolClasses: [MockSyncProtocol.self])
        let windows = makeSampleWindows()
        let endpoint = URL(string: "https://usage.example.com/api/ingest/usage")!
        do {
            _ = try await publisher.publish(windows: windows, to: endpoint)
            XCTFail("Expected the invalid first ACK to fail")
        } catch let error as QuotaPublisherError {
            XCTAssertEqual(error, .serverError("Usage Monitor returned an invalid v2 acknowledgment."))
        }
        let retry = try await publisher.publish(windows: windows, to: endpoint)
        XCTAssertEqual(retry.count, 2)
        XCTAssertTrue(retry.message.contains("2 duplicates"))
        XCTAssertEqual(submittedIds.count, 2)
        XCTAssertEqual(submittedIds.first?.count, 2)
        XCTAssertEqual(submittedIds.first, submittedIds.last)
    }

    func testPublishValidatesActualFilteredEventCount() async throws {
        var windows = makeSampleWindows()
        windows[1].remainingPercent = nil
        windows[1].remainingUnknown = true
        let data = try JSONSerialization.data(withJSONObject: acknowledgment(received: 1, persisted: 1))
        MockSyncProtocol.requestHandler = { request in
            XCTAssertEqual(try self.requestEvents(request).count, 1)
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, data)
        }
        let publisher = QuotaPublisher(urlProtocolClasses: [MockSyncProtocol.self])
        let endpoint = URL(string: "https://usage.example.com/api/ingest/usage")!
        let result = try await publisher.publish(windows: windows, to: endpoint)
        XCTAssertEqual(result.count, 1)
        XCTAssertTrue(result.message.contains("Synced 1 quotas"))

        let inflated = try JSONSerialization.data(withJSONObject: acknowledgment())
        MockSyncProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, inflated)
        }
        do {
            _ = try await publisher.publish(windows: windows, to: endpoint)
            XCTFail("Expected the ACK to match emitted events, not input windows")
        } catch let error as QuotaPublisherError {
            XCTAssertEqual(error, .serverError("Usage Monitor acknowledged 2 quota events; the request contained 1."))
        }
    }

    func testPublishWithNoPublishableEventsFailsBeforeRequest() async {
        var windows = makeSampleWindows()
        for index in windows.indices {
            windows[index].remainingPercent = nil
            windows[index].remainingUnknown = true
        }
        MockSyncProtocol.requestHandler = { _ in
            XCTFail("An empty event batch must not be sent")
            throw URLError(.badServerResponse)
        }
        let publisher = QuotaPublisher(urlProtocolClasses: [MockSyncProtocol.self])
        do {
            _ = try await publisher.publish(windows: windows, to: URL(string: "https://usage.example.com/api/ingest/usage")!)
            XCTFail("Expected noPublishableWindows error")
        } catch let error as QuotaPublisherError {
            XCTAssertEqual(error, .noPublishableWindows)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGenericWebhookKeepsHTTP2xxSuccessSemantics() async throws {
        for (statusCode, body) in [(204, ""), (200, "not-json"), (200, "{\"ok\":false}")] {
            MockSyncProtocol.requestHandler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: nil, headerFields: nil)!
                return (response, Data(body.utf8))
            }
            var windows = makeSampleWindows()
            windows[1].remainingPercent = nil
            let publisher = QuotaPublisher(urlProtocolClasses: [MockSyncProtocol.self])
            let result = try await publisher.publish(windows: windows, to: URL(string: "https://webhook.example.com/quotas")!, format: .genericWebhook)
            XCTAssertEqual(result.statusCode, statusCode)
            XCTAssertEqual(result.count, 2)
            XCTAssertEqual(result.message, "Pushed 2 quota windows successfully.")
        }
    }

    func testPublishHandlesUnauthorized() async {
        MockSyncProtocol.requestHandler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let publisher = QuotaPublisher(urlProtocolClasses: [MockSyncProtocol.self])
        let windows = makeSampleWindows()
        let url = URL(string: "https://usage.example.com/api/ingest/usage")!

        do {
            _ = try await publisher.publish(windows: windows, to: url, token: "bad-token")
            XCTFail("Expected unauthorized error")
        } catch let err as QuotaPublisherError {
            XCTAssertEqual(err, .unauthorized)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
