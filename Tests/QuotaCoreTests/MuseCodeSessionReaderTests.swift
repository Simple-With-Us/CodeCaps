import XCTest
@testable import QuotaCore

final class MuseCodeSessionReaderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func segment(session: String = "s1", model: String, tokens: Int,
                         minutesAgo: Double, first: String, last: String) -> MuseCodeTokenSegment {
        MuseCodeTokenSegment(sessionId: session, modelId: model, totalTokens: tokens,
                              observedAt: now.addingTimeInterval(-minutesAgo * 60),
                              sourceFirstId: first, sourceLastId: last)
    }

    func testAggregateDedupesRepeatedSegmentsPerSession() {
        let original = segment(model: "muse-spark-1.3-contributor", tokens: 1_000,
                               minutesAgo: 10, first: "a", last: "b")
        let reread = segment(model: "muse-spark-1.3-contributor", tokens: 1_000,
                             minutesAgo: 9, first: "a", last: "b")
        let otherSession = segment(session: "s2", model: "muse-spark-1.3-contributor",
                                   tokens: 1_000, minutesAgo: 8, first: "a", last: "b")
        let report = MuseCodeSessionReader.aggregate(
            segments: [original, reread, otherSession],
            sessionActivity: ["s1": now, "s2": now], now: now)
        let window = report.window(minutes: 90)
        XCTAssertEqual(window?.totalTokens, 2_000,
                       "the same source range in one session is one segment; in another session it is its own")
        XCTAssertEqual(window?.models.first?.segmentCount, 2)
        XCTAssertEqual(window?.models.first?.sessionCount, 2)
        XCTAssertEqual(report.segments.count, 2)
    }

    func testAggregateWindowsAndContributorShare() {
        let segments = [
            segment(model: "muse-spark-1.3-contributor", tokens: 3_000_000,
                    minutesAgo: 30, first: "a", last: "b"),
            segment(model: "muse-wonder-1.0", tokens: 1_000_000,
                    minutesAgo: 20, first: "c", last: "d"),
            segment(model: "muse-spark-1.3-contributor", tokens: 2_000_000,
                    minutesAgo: 75, first: "e", last: "f"),
            segment(model: "muse-wonder-full-1.0", tokens: 9_000_000,
                    minutesAgo: 120, first: "g", last: "h")
        ]
        let report = MuseCodeSessionReader.aggregate(
            segments: segments, sessionActivity: ["s1": now], now: now)
        let window60 = report.window(minutes: 60)
        XCTAssertEqual(window60?.totalTokens, 4_000_000)
        XCTAssertEqual(window60?.contributorTokens, 3_000_000)
        XCTAssertEqual(window60?.contributorShare, 0.75)
        let window90 = report.window(minutes: 90)
        XCTAssertEqual(window90?.totalTokens, 6_000_000)
        XCTAssertEqual(window90?.contributorShare, 5.0 / 6.0)
        XCTAssertEqual(window90?.standardModels.map(\.modelId), ["muse-wonder-1.0"],
                       "the 120-minute-old standard segment is outside both windows")
        XCTAssertEqual(window90?.activeSessions, 1)
        XCTAssertEqual(window90?.tokensPerHour, 4_000_000)
    }

    func testAggregateEmptyWindowHasNoShare() {
        let report = MuseCodeSessionReader.aggregate(segments: [], sessionActivity: [:], now: now)
        XCTAssertEqual(report.window(minutes: 90)?.totalTokens, 0)
        XCTAssertNil(report.window(minutes: 90)?.contributorShare,
                     "no burn is neither 0% nor 100% contributor")
    }

    // MARK: - Filesystem

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("MuseCodeSessionReaderTests." + UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return home
    }

    private func writeSnapshot(home: URL, session: String, name: String,
                               usage: [String: Any]?, modified: Date, headId: String = "x") throws {
        let directory = home
            .appendingPathComponent(".local/share/muse/sessions/.msp-view-g6/\(session)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        if let usage {
            let root: [String: Any] = ["continuation": ["view_materialization":
                                        ["current_state": ["tokenUsage": usage]]]]
            try JSONSerialization.data(withJSONObject: root).write(to: url)
        } else {
            try Data("not json".utf8).write(to: url)
        }
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        let head = directory.appendingPathComponent("HEAD.json")
        try JSONSerialization.data(withJSONObject: ["latest_snapshot_id": headId]).write(to: head)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: head.path)
    }

    private func usage(model: String, tokens: Int, first: String, last: String) -> [String: Any] {
        ["modelId": model, "totalTokens": tokens, "promptTokens": tokens / 2,
         "sourceRange": ["first": ["id": first], "last": ["id": last]]]
    }

    func testReaderScansStoreAndSkipsStaleAndMalformedSnapshots() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSnapshot(home: home, session: "session-a", name: "snapshot-1.json",
                          usage: usage(model: "muse-spark-1.3-contributor", tokens: 2_000, first: "a1", last: "b1"),
                          modified: now.addingTimeInterval(-75 * 60))
        try writeSnapshot(home: home, session: "session-a", name: "snapshot-2.json",
                          usage: usage(model: "muse-spark-1.3-contributor", tokens: 1_000, first: "a2", last: "b2"),
                          modified: now.addingTimeInterval(-10 * 60))
        try writeSnapshot(home: home, session: "session-a", name: "snapshot-3.json",
                          usage: usage(model: "muse-spark-1.3-contributor", tokens: 1_000, first: "a2", last: "b2"),
                          modified: now.addingTimeInterval(-9 * 60))
        try writeSnapshot(home: home, session: "session-a", name: "snapshot-4.json",
                          usage: usage(model: "muse-wonder-1.0", tokens: 500, first: "a3", last: "b3"),
                          modified: now.addingTimeInterval(-8 * 60))
        try writeSnapshot(home: home, session: "session-a", name: "snapshot-bad.json",
                          usage: nil, modified: now.addingTimeInterval(-5 * 60))
        try writeSnapshot(home: home, session: "session-b", name: "snapshot-1.json",
                          usage: usage(model: "muse-wonder-1.0", tokens: 7_777, first: "z1", last: "z2"),
                          modified: now.addingTimeInterval(-180 * 60))

        let result = MuseCodeSessionReader(homeDirectory: home, now: { self.now }).read()
        XCTAssertNil(result.issue)
        let report = try XCTUnwrap(result.report)
        XCTAssertEqual(report.window(minutes: 60)?.totalTokens, 1_500)
        XCTAssertEqual(report.window(minutes: 90)?.totalTokens, 3_500)
        XCTAssertEqual(report.window(minutes: 90)?.contributorTokens, 3_000)
        XCTAssertEqual(report.window(minutes: 90)?.activeSessions, 1,
                       "session-b's newest file is three hours old, so it is not active")
        XCTAssertEqual(report.segments.count, 3, "the duplicate snapshot adds no segment")
        XCTAssertEqual(report.latestObservations.map(\.sessionId), ["session-a"])
        let observation = report.latestObservations.first
        XCTAssertEqual(observation?.snapshotId, "4",
                       "HEAD names an unknown id here, so the newest parsed snapshot is the latest")
        XCTAssertEqual(observation?.modelId, "muse-wonder-1.0")
        XCTAssertEqual(observation?.totalTokens, 500)
        XCTAssertEqual(observation?.segmentKey, "a3")
    }

    func testReaderLatestObservationFollowsHeadSnapshotId() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSnapshot(home: home, session: "session-c", name: "snapshot-7.json",
                          usage: usage(model: "muse-spark-1.3-contributor", tokens: 300, first: "c1", last: "c2"),
                          modified: now.addingTimeInterval(-20 * 60), headId: "7")
        try writeSnapshot(home: home, session: "session-c", name: "snapshot-9.json",
                          usage: usage(model: "muse-wonder-1.0", tokens: 900, first: "c3", last: "c4"),
                          modified: now.addingTimeInterval(-5 * 60), headId: "7")

        let result = MuseCodeSessionReader(homeDirectory: home, now: { self.now }).read()
        let observation = result.report?.latestObservations.first
        XCTAssertEqual(observation?.snapshotId, "7",
                       "HEAD.json's latest_snapshot_id wins over the newest file by mtime")
        XCTAssertEqual(observation?.modelId, "muse-spark-1.3-contributor")
        XCTAssertEqual(observation?.totalTokens, 300)
        XCTAssertEqual(observation?.isContributor, true)
    }

    func testReaderReportsMissingStore() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let result = MuseCodeSessionReader(homeDirectory: home, now: { self.now }).read()
        XCTAssertNil(result.report)
        XCTAssertNotNil(result.issue)
    }
}
