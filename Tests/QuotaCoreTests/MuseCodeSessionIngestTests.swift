import XCTest
@testable import QuotaCore

final class MuseCodeSessionIngestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func observation(session: String = "s1", snapshot: String = "snap1",
                             model: String = "muse-wonder-1.0", total: Int,
                             segment: String = "seg-a", minutesAgo: Double = 5) -> MuseCodeSessionObservation {
        MuseCodeSessionObservation(sessionId: session, snapshotId: snapshot, modelId: model,
                                    totalTokens: total, segmentKey: segment,
                                    observedAt: now.addingTimeInterval(-minutesAgo * 60))
    }

    // MARK: - Event shape (the verified contract)

    func testEventMatchesVerifiedContractShape() {
        let event = MuseCodeSessionIngest.event(
            observation: observation(model: "muse-spark-1.3-contributor", total: 5_000), delta: 1_250)
        XCTAssertEqual(Set(event.keys), ["eventId", "provider", "service", "producerKeyRef",
                                         "metricType", "unit", "quantity", "billingMode",
                                         "confidence", "occurredAt", "metadata"])
        XCTAssertEqual(event["eventId"] as? String,
                       "codecaps-muse-code:s1:snap1:muse-spark-1.3-contributor")
        XCTAssertEqual(event["provider"] as? String, "muse-code")
        XCTAssertEqual(event["service"] as? String, "muse-code")
        XCTAssertEqual(event["producerKeyRef"] as? String, "muse-spark-1.3-contributor")
        XCTAssertEqual(event["metricType"] as? String, "usage")
        XCTAssertEqual(event["unit"] as? String, "token")
        XCTAssertEqual(event["quantity"] as? Int, 1_250, "quantity is the delta, never the cumulative total")
        XCTAssertEqual(event["billingMode"] as? String, "estimated")
        XCTAssertEqual(event["confidence"] as? String, "estimated")
        let metadata = event["metadata"] as? [String: Any]
        XCTAssertEqual(metadata?["sessionId"] as? String, "s1")
        XCTAssertEqual(metadata?["contributor"] as? Bool, true)
        XCTAssertEqual(metadata?["source"] as? String, "muse-session-stores")
    }

    func testBatchEnvelopeMatchesVerifiedContractShape() throws {
        let events = [MuseCodeSessionIngest.event(observation: observation(total: 10), delta: 10)]
        let data = try MuseCodeSessionIngest.batchData(events: events)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["schemaVersion", "producerId", "events"])
        XCTAssertEqual(root["schemaVersion"] as? Int, 2)
        XCTAssertEqual(root["producerId"] as? String, "muse-code")
        XCTAssertEqual((root["events"] as? [Any])?.count, 1)
    }

    func testBatchesChunkAtOneHundredEvents() {
        let events = (0..<205).map { index in
            MuseCodeSessionIngest.event(observation: observation(session: "s\(index)", total: 1), delta: 1)
        }
        XCTAssertEqual(MuseCodeSessionIngest.eventBatches(events: events).map(\.count), [100, 100, 5])
    }

    // MARK: - Delta discipline

    func testFirstObservationEmitsTheSegmentTotal() {
        let plan = MuseCodeDeltaPlanner.plan(observations: [observation(total: 700)], previous: [:])
        XCTAssertEqual(plan.events.map(\.delta), [700])
        XCTAssertEqual(plan.updated["s1"]?.totalTokens, 700)
    }

    func testSameSegmentEmitsOnlyThePositiveDelta() {
        let previous = ["s1": observation(total: 700)]
        let plan = MuseCodeDeltaPlanner.plan(
            observations: [observation(snapshot: "snap2", total: 950)], previous: previous)
        XCTAssertEqual(plan.events.map(\.delta), [250],
                       "950 cumulative minus the 700 already posted is a 250 delta, not 950")
        XCTAssertEqual(plan.events.first?.observation.snapshotId, "snap2")
    }

    func testUnchangedTotalEmitsNothingButAdvancesBaseline() {
        let previous = ["s1": observation(total: 700)]
        let plan = MuseCodeDeltaPlanner.plan(
            observations: [observation(snapshot: "snap2", total: 700)], previous: previous)
        XCTAssertTrue(plan.events.isEmpty)
        XCTAssertEqual(plan.updated["s1"]?.snapshotId, "snap2")
    }

    func testSegmentResetEmitsTheNewSegmentsTotal() {
        let previous = ["s1": observation(total: 700, segment: "seg-a")]
        let plan = MuseCodeDeltaPlanner.plan(
            observations: [observation(snapshot: "snap2", total: 300, segment: "seg-b")],
            previous: previous)
        XCTAssertEqual(plan.events.map(\.delta), [300],
                       "a reset segment's total is the delta, even though it is below the old total")
    }

    func testModelSwitchEmitsTheNewTotal() {
        let previous = ["s1": observation(model: "muse-wonder-1.0", total: 700)]
        let plan = MuseCodeDeltaPlanner.plan(
            observations: [observation(snapshot: "snap2", model: "muse-spark-1.3-contributor", total: 200)],
            previous: previous)
        XCTAssertEqual(plan.events.map(\.delta), [200])
        XCTAssertEqual(plan.events.first?.observation.modelId, "muse-spark-1.3-contributor")
    }

    func testDecreasedTotalInSameSegmentEmitsNothingAndRebaselines() {
        let previous = ["s1": observation(total: 700)]
        let plan = MuseCodeDeltaPlanner.plan(
            observations: [observation(snapshot: "snap2", total: 400)], previous: previous)
        XCTAssertTrue(plan.events.isEmpty, "a negative delta is never posted")
        XCTAssertEqual(plan.updated["s1"]?.totalTokens, 400)
    }

    // MARK: - Poster

    private func response(status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: MuseCodeSessionIngest.endpoint, statusCode: status,
                        httpVersion: nil, headerFields: nil)!
    }

    func testPosterPostsBatchesAndValidatesCompleteAcknowledgment() async throws {
        let events = [MuseCodeSessionIngest.event(observation: observation(total: 10), delta: 10),
                      MuseCodeSessionIngest.event(observation: observation(session: "s2", total: 5), delta: 5)]
        var requests: [URLRequest] = []
        let poster = MuseCodeSessionPoster { request in
            requests.append(request)
            let ack: [String: Any] = ["received": 2, "persisted": 2, "duplicates": 0,
                                      "pruned": 0, "rejected": 0]
            return (try JSONSerialization.data(withJSONObject: ack), self.response())
        }
        let summary = try await poster.publish(events: events, to: MuseCodeSessionIngest.endpoint, token: "scoped-token")
        XCTAssertEqual(summary, MuseCodeIngestSummary(sent: 2, persisted: 2, duplicates: 0, pruned: 0, rejected: 0))
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "x-usage-telemetry-version"), "2")
        XCTAssertEqual(requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer scoped-token")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try XCTUnwrap(requests.first?.httpBody)) as? [String: Any])
        XCTAssertEqual(body["producerId"] as? String, "muse-code")
    }

    func testPosterRejectsIncompleteAcknowledgment() async {
        let events = [MuseCodeSessionIngest.event(observation: observation(total: 10), delta: 10)]
        let poster = MuseCodeSessionPoster { _ in
            let ack: [String: Any] = ["received": 0, "persisted": 0, "duplicates": 0,
                                      "pruned": 0, "rejected": 0]
            return (try JSONSerialization.data(withJSONObject: ack), self.response())
        }
        do {
            _ = try await poster.publish(events: events, to: MuseCodeSessionIngest.endpoint, token: "scoped-token")
            XCTFail("an acknowledgment that does not account for the sent events must throw")
        } catch {
            XCTAssertTrue(error is QuotaPublisherError)
        }
    }
}
