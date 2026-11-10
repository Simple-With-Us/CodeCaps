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

    func testAggregateUsesHighWaterForRepeatedCumulativeRange() {
        let first = segment(model: "muse-wonder-1.0", tokens: 100,
                            minutesAgo: 10, first: "first", last: "last")
        let updated = segment(model: "muse-wonder-1.0", tokens: 200,
                              minutesAgo: 8, first: "first", last: "last")
        let stale = segment(model: "muse-wonder-1.0", tokens: 150,
                            minutesAgo: 5, first: "first", last: "last")

        let report = MuseCodeSessionReader.aggregate(
            segments: [first, updated, stale], sessionActivity: ["s1": now], now: now)

        XCTAssertEqual(report.window(minutes: 90)?.totalTokens, 200,
                       "cumulative snapshots of one exact source range contribute only their high-water total")
        XCTAssertEqual(report.window(minutes: 90)?.models.first?.segmentCount, 1)
        XCTAssertEqual(report.segments.first?.totalTokens, 200,
                       "a later stale snapshot cannot replace the segment high-water")
    }

    func testAggregateSumsDistinctRangesSessionsAndModelSwitches() {
        let segments = [
            segment(session: "s1", model: "muse-wonder-1.0", tokens: 100,
                    minutesAgo: 10, first: "shared-start", last: "range-one"),
            segment(session: "s1", model: "muse-wonder-1.0", tokens: 50,
                    minutesAgo: 9, first: "shared-start", last: "range-two"),
            segment(session: "s1", model: "muse-spark-1.3-contributor", tokens: 25,
                    minutesAgo: 8, first: "shared-start", last: "range-one"),
            segment(session: "s2", model: "muse-wonder-1.0", tokens: 70,
                    minutesAgo: 7, first: "shared-start", last: "range-one"),
        ]

        let report = MuseCodeSessionReader.aggregate(
            segments: segments, sessionActivity: ["s1": now, "s2": now], now: now)

        XCTAssertEqual(report.window(minutes: 90)?.totalTokens, 245)
        XCTAssertEqual(report.window(minutes: 90)?.models.first(where: { $0.modelId == "muse-wonder-1.0" })?.tokens, 220)
        XCTAssertEqual(report.window(minutes: 90)?.models.first(where: { $0.modelId == "muse-spark-1.3-contributor" })?.tokens, 25)
        XCTAssertEqual(report.window(minutes: 90)?.models.first(where: { $0.modelId == "muse-wonder-1.0" })?.sessionCount, 2)
        XCTAssertEqual(report.segments.count, 4)
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
                               usage: [String: Any]?, modified: Date, headId: String = "x",
                               nullTokenUsage: Bool = false) throws {
        let directory = home
            .appendingPathComponent(".local/share/muse/sessions/.msp-view-g6/\(session)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        if let usage {
            let root: [String: Any] = ["continuation": ["view_materialization":
                                        ["current_state": ["tokenUsage": usage]]]]
            try JSONSerialization.data(withJSONObject: root).write(to: url)
        } else if nullTokenUsage {
            let root: [String: Any] = ["continuation": ["view_materialization":
                                        ["current_state": ["tokenUsage": NSNull()]]]]
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
        XCTAssertEqual(report.currentModelObservations.map(\.sessionId), ["session-a"],
                       "stale session-b is not exposed as a currently active model")
        let observation = report.latestObservations.first
        XCTAssertEqual(observation?.snapshotId, "4",
                       "HEAD names an unknown id here, so the newest parsed snapshot is the latest")
        XCTAssertEqual(observation?.modelId, "muse-wonder-1.0")
        XCTAssertEqual(observation?.totalTokens, 500)
        XCTAssertEqual(observation?.segmentKey, "a3")
    }

    func testReaderServesUnchangedSnapshotsFromParseCache() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSnapshot(home: home, session: "session-a", name: "snapshot-1.json",
                          usage: usage(model: "muse-spark-1.3-contributor", tokens: 2_000, first: "a1", last: "b1"),
                          modified: now.addingTimeInterval(-10 * 60))
        let cache = MuseCodeSessionReader.snapshotSegmentCache
        cache.reset()
        let reader = MuseCodeSessionReader(homeDirectory: home, now: { self.now })
        _ = reader.read()
        let missesAfterFirst = cache.stats().misses
        XCTAssertGreaterThan(missesAfterFirst, 0)
        let again = reader.read()
        XCTAssertEqual(cache.stats().misses, missesAfterFirst,
                       "a second read of an unchanged store parses nothing again")
        XCTAssertNil(again.issue)
    }

    func testParseCacheOverflowEvictsOneEntryInsteadOfClearingAll() {
        let cache = MuseCodeSessionReader.snapshotSegmentCache
        cache.reset()
        defer { cache.reset() }
        let cap = 8_192
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let parse: () -> MuseCodeTokenSegment? = {
            MuseCodeTokenSegment(sessionId: "s", modelId: "m", totalTokens: 1, observedAt: stamp)
        }
        for i in 0..<cap {
            _ = cache.segment(sessionId: "s", url: URL(fileURLWithPath: "/tmp/fake-\(i).json"),
                              modified: stamp, size: 1, fileId: "fake", parse: parse)
        }
        // One more distinct snapshot pushes the cache past its cap.
        _ = cache.segment(sessionId: "s", url: URL(fileURLWithPath: "/tmp/fake-overflow.json"),
                          modified: stamp, size: 1, fileId: "fake", parse: parse)
        var hits = 0
        for i in 0..<cap {
            if cache.segment(sessionId: "s", url: URL(fileURLWithPath: "/tmp/fake-\(i).json"),
                             modified: stamp, size: 1, fileId: "fake", parse: { nil }) != nil {
                hits += 1
            }
        }
        XCTAssertEqual(hits, cap - 1,
                       "overflow evicts one entry, keeping the rest of the working set cached")
    }

    private static func snapshotFileId(at url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attrs.map {
            String(describing: $0[.systemFileNumber] ?? 0) + "@" +
                String((($0[.creationDate] as? Date) ?? .distantPast).timeIntervalSince1970)
        } ?? ""
    }

    func testParseCacheReparseesReplacedFileWithIdenticalMetadata() throws {
        // Rotation by replacement with a reused path, same size, and the same
        // mtime: the creation-date component in the key must still force a
        // re-parse.  mtime is set to a FUTURE stamp on both files, because
        // backdating mtime on macOS also drags birthtime down with it, which
        // would make the files genuinely indistinguishable by metadata.
        let cache = MuseCodeSessionReader.snapshotSegmentCache
        cache.reset()
        defer { cache.reset() }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cache-replacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("snapshot-1.json")
        let stamp = Date(timeIntervalSince1970: 2_000_000_000)
        var parses = 0
        let parse: () -> MuseCodeTokenSegment? = {
            parses += 1
            return MuseCodeTokenSegment(sessionId: "s", modelId: "m",
                                        totalTokens: parses, observedAt: stamp)
        }
        try Data(repeating: 0x61, count: 64).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        let first = cache.segment(sessionId: "s", url: url, modified: stamp, size: 64,
                                  fileId: Self.snapshotFileId(at: url), parse: parse)
        XCTAssertEqual(first?.totalTokens, 1)
        // Replace the file at the same path, then set the same mtime.
        try FileManager.default.removeItem(at: url)
        try Data(repeating: 0x62, count: 64).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        let second = cache.segment(sessionId: "s", url: url, modified: stamp, size: 64,
                                   fileId: Self.snapshotFileId(at: url), parse: parse)
        XCTAssertEqual(parses, 2, "a replacement with identical path/size/mtime must not hit the old entry")
        XCTAssertEqual(second?.totalTokens, 2, "the replacement's own content is returned, not the stale entry")
    }

    func testReaderReparsesASnapshotRewrittenInPlace() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSnapshot(home: home, session: "session-a", name: "snapshot-1.json",
                          usage: usage(model: "muse-spark-1.3-contributor", tokens: 2_000, first: "a1", last: "b1"),
                          modified: now.addingTimeInterval(-10 * 60))
        let cache = MuseCodeSessionReader.snapshotSegmentCache
        cache.reset()
        let reader = MuseCodeSessionReader(homeDirectory: home, now: { self.now })
        let first = try XCTUnwrap(reader.read().report)
        XCTAssertEqual(first.window(minutes: 90)?.totalTokens, 2_000)
        try writeSnapshot(home: home, session: "session-a", name: "snapshot-1.json",
                          usage: usage(model: "muse-spark-1.3-contributor", tokens: 5_000, first: "a1", last: "b1"),
                          modified: now.addingTimeInterval(-5 * 60))
        let second = try XCTUnwrap(reader.read().report)
        XCTAssertEqual(second.window(minutes: 90)?.totalTokens, 5_000,
                       "a rewritten snapshot has a new cache key, so the new content is parsed")
    }

    func testCurrentModelUsesNullHeadWithoutBackfillingAndPreservesHistoricalUsage() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try writeSnapshot(home: home, session: "session-current", name: "snapshot-1.json",
                          usage: usage(model: "muse-wonder-1.0", tokens: 4_250,
                                       first: "old-first", last: "old-last"),
                          modified: now.addingTimeInterval(-3 * 60), headId: "1")
        try writeSnapshot(home: home, session: "session-current", name: "snapshot-2.json",
                          usage: nil, modified: now.addingTimeInterval(-2 * 60), headId: "2",
                          nullTokenUsage: true)

        let nullHead = try XCTUnwrap(MuseCodeSessionReader(homeDirectory: home, now: { self.now })
            .read().report)
        XCTAssertEqual(nullHead.currentModelObservations.count, 1)
        XCTAssertNil(nullHead.currentModelObservations.first?.modelId,
                     "HEAD's null tokenUsage means the current model is unknown, not the older standard model")
        XCTAssertEqual(nullHead.window(minutes: 90)?.totalTokens, 4_250,
                       "a missing current model does not erase older valid token usage")

        try writeSnapshot(home: home, session: "session-current", name: "snapshot-3.json",
                          usage: usage(model: "muse-spark-1.3-contributor", tokens: 800,
                                       first: "contrib-first", last: "contrib-last"),
                          modified: now.addingTimeInterval(-60), headId: "3")
        let contributor = try XCTUnwrap(MuseCodeSessionReader(homeDirectory: home, now: { self.now })
            .read().report)
        XCTAssertEqual(contributor.currentModelObservations.first?.modelId,
                       "muse-spark-1.3-contributor")
        XCTAssertEqual(contributor.window(minutes: 90)?.totalTokens, 5_050)

        try writeSnapshot(home: home, session: "session-current", name: "snapshot-4.json",
                          usage: usage(model: "muse-wonder-2.0", tokens: 200,
                                       first: "standard-first", last: "standard-last"),
                          modified: now, headId: "4")
        let standard = try XCTUnwrap(MuseCodeSessionReader(homeDirectory: home, now: { self.now })
            .read().report)
        XCTAssertEqual(standard.currentModelObservations.first?.modelId, "muse-wonder-2.0")
        XCTAssertEqual(standard.window(minutes: 90)?.totalTokens, 5_250)
    }

    func testReaderKeepsNewestSnapshotsAndHeadBeyondParsingCap() throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        for index in 0...512 {
            try writeSnapshot(home: home, session: "session-many", name: "snapshot-\(index).json",
                              usage: usage(model: "muse-model-\(index)", tokens: 1,
                                           first: "first-\(index)", last: "last-\(index)"),
                              modified: now.addingTimeInterval(Double(index - 512)),
                              headId: "512")
        }

        let report = try XCTUnwrap(MuseCodeSessionReader(homeDirectory: home, now: { self.now })
            .read().report)
        XCTAssertEqual(report.currentModelObservations.first?.modelId, "muse-model-512")
        XCTAssertEqual(report.window(minutes: 90)?.totalTokens, 512,
                       "the newest 512 snapshots are retained for bounded usage parsing")
        XCTAssertTrue(report.segments.contains { $0.modelId == "muse-model-512" },
                      "the HEAD snapshot is always included in the bounded scan")
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
