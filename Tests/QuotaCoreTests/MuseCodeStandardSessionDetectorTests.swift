import XCTest
@testable import QuotaCore

final class MuseCodeStandardSessionDetectorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let contributorModel = "muse-spark-1.3-contributor"
    private let standardModel = "muse-wonder-1.0"

    private func observation(_ sessionId: String, _ modelId: String?,
                             at offset: TimeInterval = 0) -> MuseCodeSessionModelObservation {
        MuseCodeSessionModelObservation(sessionId: sessionId, modelId: modelId,
                                         observedAt: now.addingTimeInterval(offset))
    }

    func testNewStandardSessionFiresOnceNamingSessionModelAndTime() {
        var detector = MuseCodeStandardSessionDetector()
        let events = detector.observe([observation("s1", standardModel, at: 60)])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.sessionId, "s1")
        XCTAssertEqual(events.first?.modelId, standardModel)
        XCTAssertEqual(events.first?.observedAt, now.addingTimeInterval(60))
        XCTAssertTrue(events.first?.body.contains("s1") == true,
                      "the alert payload names the session")
        XCTAssertTrue(events.first?.body.contains(standardModel) == true,
                      "the alert payload names the model")
    }

    func testEventBodyUsesCentralTwelveHourTime() {
        let observedAt = ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z")!
        let event = MuseCodeStandardSessionEvent(sessionId: "s1", modelId: standardModel,
                                                 observedAt: observedAt)
        XCTAssertTrue(event.body.contains("Observed at Nov 3, 2026 6:00 AM."))
    }

    func testSameStandardSessionRepolledDoesNotRefire() {
        var detector = MuseCodeStandardSessionDetector()
        XCTAssertEqual(detector.observe([observation("s1", standardModel)]).count, 1)
        XCTAssertTrue(detector.observe([observation("s1", standardModel, at: 120)]).isEmpty)
        XCTAssertTrue(detector.observe([observation("s1", standardModel, at: 240)]).isEmpty,
                      "staying on the same standard model across polls is not a new event")
    }

    func testStandardToDifferentStandardModelDoesNotRefire() {
        var detector = MuseCodeStandardSessionDetector()
        XCTAssertEqual(detector.observe([observation("s1", standardModel)]).count, 1)
        XCTAssertTrue(detector.observe([observation("s1", "muse-wonder-full-1.0", at: 60)]).isEmpty,
                      "moving between standard models never left the standard side")
    }

    func testContributorToStandardSwitchFires() {
        var detector = MuseCodeStandardSessionDetector()
        XCTAssertTrue(detector.observe([observation("s1", contributorModel)]).isEmpty)
        let events = detector.observe([observation("s1", standardModel, at: 60)])
        XCTAssertEqual(events.map(\.sessionId), ["s1"])
        XCTAssertEqual(events.first?.modelId, standardModel)
    }

    func testStandardContributorStandardRefires() {
        var detector = MuseCodeStandardSessionDetector()
        XCTAssertEqual(detector.observe([observation("s1", standardModel)]).count, 1)
        XCTAssertTrue(detector.observe([observation("s1", contributorModel, at: 60)]).isEmpty,
                      "returning to a contributor model is not an event, it re-arms")
        let events = detector.observe([observation("s1", standardModel, at: 120)])
        XCTAssertEqual(events.count, 1, "going standard again after recovery is a new event")
    }

    func testContributorOnlySessionsNeverFire() {
        var detector = MuseCodeStandardSessionDetector()
        for offset in stride(from: 0, through: 600, by: 60) {
            let events = detector.observe([
                observation("s1", contributorModel, at: TimeInterval(offset)),
                observation("s2", "muse-wonder-full-1.0-contributor", at: TimeInterval(offset)),
            ])
            XCTAssertTrue(events.isEmpty)
        }
    }

    func testNullModelSessionNeverFiresAndLeavesNoTrace() {
        var detector = MuseCodeStandardSessionDetector()
        XCTAssertTrue(detector.observe([observation("s1", nil)]).isEmpty)
        XCTAssertTrue(detector.observe([observation("s1", nil, at: 60)]).isEmpty,
                      "a session with no model on its current segment is not an event")
        XCTAssertEqual(detector.lastKnownModels.count, 0,
                       "a model-less observation records nothing")
        // The later standard sighting is the first model-bearing one, so it
        // fires as first-observed rather than being masked by the null.
        XCTAssertEqual(detector.observe([observation("s1", standardModel, at: 120)]).count, 1)
    }

    func testSessionsAreTrackedIndependently() {
        var detector = MuseCodeStandardSessionDetector()
        let first = detector.observe([
            observation("s1", contributorModel),
            observation("s2", standardModel),
        ])
        XCTAssertEqual(first.map(\.sessionId), ["s2"])
        let second = detector.observe([
            observation("s1", standardModel, at: 60),
            observation("s2", standardModel, at: 60),
        ])
        XCTAssertEqual(second.map(\.sessionId), ["s1"],
                       "s2 was already standard; only s1's switch is new")
    }

    func testStateSurvivesCodableRoundTripWithoutRefiring() throws {
        var detector = MuseCodeStandardSessionDetector()
        XCTAssertEqual(detector.observe([observation("s1", standardModel)]).count, 1)
        // The persistence pattern the app uses: JSON in UserDefaults, loaded
        // back at launch.  A relaunched detector must not re-report s1.
        let data = try JSONEncoder().encode(detector)
        var relaunched = try JSONDecoder().decode(MuseCodeStandardSessionDetector.self, from: data)
        XCTAssertEqual(relaunched, detector)
        XCTAssertTrue(relaunched.observe([observation("s1", standardModel, at: 60)]).isEmpty)
        XCTAssertEqual(relaunched.observe([observation("s2", standardModel, at: 60)]).count, 1,
                       "a genuinely new standard session still fires after a relaunch")
    }

    func testStandardSessionsPresenceListsCurrentStandardSessions() {
        let present = MuseCodeStandardSessionDetector.standardSessions(in: [
            observation("s1", contributorModel),
            observation("s2", standardModel),
            observation("s3", nil),
        ])
        XCTAssertEqual(present.map(\.sessionId), ["s2"])
        XCTAssertEqual(present.first?.modelId, standardModel)
    }
}
