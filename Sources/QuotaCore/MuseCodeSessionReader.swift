import Foundation

/// One distinct conversation segment observed in a Muse session snapshot.
///
/// A segment is the unit the fleet's survey scripts proved additive: distinct
/// source ranges inside one session sum to the session's burn, while the same
/// range re-read from a later snapshot is the same segment, never new burn.
public struct MuseCodeTokenSegment: Equatable, Sendable {
    public let sessionId: String
    public let modelId: String
    public let totalTokens: Int
    public let promptTokens: Int?
    public let observedAt: Date
    public let sourceFirstId: String?
    public let sourceLastId: String?

    public init(sessionId: String, modelId: String, totalTokens: Int, promptTokens: Int? = nil,
                observedAt: Date, sourceFirstId: String? = nil, sourceLastId: String? = nil) {
        self.sessionId = sessionId
        self.modelId = modelId
        self.totalTokens = totalTokens
        self.promptTokens = promptTokens
        self.observedAt = observedAt
        self.sourceFirstId = sourceFirstId
        self.sourceLastId = sourceLastId
    }

    /// The segment's identity inside its session, matching the dedupe key the
    /// survey scripts use: (sourceRange first id, last id, model, total).
    public var dedupeKey: String {
        [sourceFirstId ?? "", sourceLastId ?? "", modelId, String(totalTokens)]
            .joined(separator: "\u{1}")
    }

    public var isContributor: Bool { modelId.hasSuffix("-contributor") }
}

/// Token totals for one model inside one trailing window.
public struct MuseCodeModelUsage: Equatable, Sendable, Identifiable {
    public let modelId: String
    public let tokens: Int
    public let segmentCount: Int
    public let sessionCount: Int

    public var id: String { modelId }
    public var isContributor: Bool { modelId.hasSuffix("-contributor") }

    public init(modelId: String, tokens: Int, segmentCount: Int, sessionCount: Int) {
        self.modelId = modelId
        self.tokens = tokens
        self.segmentCount = segmentCount
        self.sessionCount = sessionCount
    }

    public func share(of total: Int) -> Double {
        total > 0 ? Double(tokens) / Double(total) : 0
    }
}

/// Aggregated Muse burn for one trailing window.
public struct MuseCodeWindowUsage: Equatable, Sendable {
    public let windowMinutes: Int
    public let totalTokens: Int
    public let contributorTokens: Int
    /// Nil when the window has no tokens at all: no burn is neither 0% nor
    /// 100% contributor, and the monitor must not treat it as either.
    public let contributorShare: Double?
    public let activeSessions: Int
    public let models: [MuseCodeModelUsage]

    public init(windowMinutes: Int, totalTokens: Int, contributorTokens: Int,
                contributorShare: Double?, activeSessions: Int, models: [MuseCodeModelUsage]) {
        self.windowMinutes = windowMinutes
        self.totalTokens = totalTokens
        self.contributorTokens = contributorTokens
        self.contributorShare = contributorShare
        self.activeSessions = activeSessions
        self.models = models
    }

    public var standardModels: [MuseCodeModelUsage] {
        models.filter { !$0.isContributor && $0.tokens > 0 }
    }

    public var tokensPerHour: Double {
        Double(totalTokens) * 60 / Double(windowMinutes)
    }
}

/// A session's latest snapshot observation: the bridge's unit of work.
///
/// The Usage Monitor bridge contract is defined over latest snapshots, not
/// over the segment sum the local monitor uses: per session, the latest
/// snapshot's `tokenUsage.totalTokens` is cumulative for its current
/// segment, and only the positive delta since the previous observation may
/// be posted.
public struct MuseCodeSessionObservation: Equatable, Sendable, Codable {
    public let sessionId: String
    public let snapshotId: String
    public let modelId: String
    public let totalTokens: Int
    /// Identifies the segment the cumulative total belongs to (the token
    /// usage's source-range start).  A changed key means the segment reset,
    /// and the new segment's total is the delta.
    public let segmentKey: String
    public let observedAt: Date

    public init(sessionId: String, snapshotId: String, modelId: String,
                totalTokens: Int, segmentKey: String, observedAt: Date) {
        self.sessionId = sessionId
        self.snapshotId = snapshotId
        self.modelId = modelId
        self.totalTokens = totalTokens
        self.segmentKey = segmentKey
        self.observedAt = observedAt
    }

    public var isContributor: Bool { modelId.hasSuffix("-contributor") }
}

/// One reading of the Muse session store: per-window aggregates for the
/// local monitor, plus each active session's latest observation for the
/// Usage Monitor bridge.
public struct MuseCodeSessionReport: Equatable, Sendable {
    public let generatedAt: Date
    public let windows: [MuseCodeWindowUsage]
    public let segments: [MuseCodeTokenSegment]
    public let latestObservations: [MuseCodeSessionObservation]

    public init(generatedAt: Date, windows: [MuseCodeWindowUsage],
                segments: [MuseCodeTokenSegment] = [],
                latestObservations: [MuseCodeSessionObservation] = []) {
        self.generatedAt = generatedAt
        self.windows = windows
        self.segments = segments
        self.latestObservations = latestObservations
    }

    public func window(minutes: Int) -> MuseCodeWindowUsage? {
        windows.first { $0.windowMinutes == minutes }
    }
}

/// The reader's result, in the shape every QuotaCore reader uses: data or a
/// user-safe issue, never a throw to the caller.
public struct MuseCodeSessionResult: Equatable, Sendable {
    public let report: MuseCodeSessionReport?
    public let issue: String?

    public init(report: MuseCodeSessionReport?, issue: String?) {
        self.report = report
        self.issue = issue
    }
}

/// Reads the Muse session stores on this Mac.
///
/// Muse writes one directory per session under
/// `~/.local/share/muse/sessions/.msp-view-g6/<session-id>/`, with a HEAD.json
/// naming the latest snapshot and `snapshot-<id>.json` files whose
/// `continuation.view_materialization.current_state.tokenUsage` carries the
/// model and token total for one conversation segment.  This reader scans the
/// snapshot files directly (the newest snapshot in a directory is the one
/// HEAD.json names), which covers both the latest-segment and the
/// segment-summed views the fleet's surveys validated.
public struct MuseCodeSessionReader: Sendable {
    public static let storeRelativePath = ".local/share/muse/sessions/.msp-view-g6"
    public static let windowMinutes = [60, 90]

    private static let maxSessionDirectories = 512
    private static let maxSnapshotsPerSession = 512
    private static let maxSnapshotBytes = 33_554_432
    private static let futureTolerance: TimeInterval = 120

    private let homeDirectory: URL
    private let now: @Sendable () -> Date

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.now = now
    }

    public func read() -> MuseCodeSessionResult {
        let instant = now()
        let root = homeDirectory.appendingPathComponent(Self.storeRelativePath, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return MuseCodeSessionResult(
                report: nil,
                issue: "Muse session store was not found on this Mac.")
        }
        let cutoff = instant.addingTimeInterval(-90 * 60)
        var segments: [MuseCodeTokenSegment] = []
        var activity: [String: Date] = [:]
        var observations: [MuseCodeSessionObservation] = []
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])) ?? []
        let sessionDirs = entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { Self.modification(of: $0) > Self.modification(of: $1) }
            .prefix(Self.maxSessionDirectories)
        for directory in sessionDirs {
            let sessionId = directory.lastPathComponent
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]) else { continue }
            let dated: [(url: URL, modified: Date, size: Int)] = files.map { url in
                let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                return (url, values?.contentModificationDate ?? .distantPast, values?.fileSize ?? 0)
            }
            // A session counts as active in a window when any of its files —
            // HEAD.json included — was written inside it, the same activity
            // test the survey scripts use.
            guard let newest = dated.map(\.modified).max(), newest >= cutoff else { continue }
            activity[sessionId] = newest
            let snapshots = dated
                .filter { $0.url.lastPathComponent.hasPrefix("snapshot-")
                    && $0.url.pathExtension == "json" && $0.modified >= cutoff }
                .sorted { $0.modified < $1.modified }
                .prefix(Self.maxSnapshotsPerSession)
            var parsed: [(snapshotId: String?, segment: MuseCodeTokenSegment)] = []
            for snapshot in snapshots {
                if let segment = Self.segment(sessionId: sessionId, url: snapshot.url,
                                              modified: snapshot.modified, size: snapshot.size) {
                    segments.append(segment)
                    parsed.append((Self.snapshotId(from: snapshot.url), segment))
                }
            }
            // The session's latest observation, for the bridge: the snapshot
            // HEAD.json names when it was parsed, otherwise the newest one.
            let headId = Self.headSnapshotId(in: dated)
            let chosen = parsed.first { $0.snapshotId != nil && $0.snapshotId == headId }
                ?? parsed.max { $0.segment.observedAt < $1.segment.observedAt }
            if let chosen {
                observations.append(MuseCodeSessionObservation(
                    sessionId: sessionId,
                    snapshotId: chosen.snapshotId ?? "",
                    modelId: chosen.segment.modelId,
                    totalTokens: chosen.segment.totalTokens,
                    segmentKey: chosen.segment.sourceFirstId ?? "",
                    observedAt: chosen.segment.observedAt))
            }
        }
        return MuseCodeSessionResult(
            report: Self.aggregate(segments: segments, sessionActivity: activity,
                                   latestObservations: observations.sorted { $0.sessionId < $1.sessionId },
                                   now: instant),
            issue: nil)
    }

    private static func snapshotId(from url: URL) -> String? {
        let name = url.lastPathComponent
        guard name.hasPrefix("snapshot-"), name.hasSuffix(".json") else { return nil }
        return String(name.dropFirst("snapshot-".count).dropLast(".json".count))
    }

    private static func headSnapshotId(in files: [(url: URL, modified: Date, size: Int)]) -> String? {
        guard let head = files.first(where: { $0.url.lastPathComponent == "HEAD.json" }),
              head.size > 0, head.size <= 1_048_576,
              let data = try? Data(contentsOf: head.url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = root["latest_snapshot_id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    private static func modification(of url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
    }

    private static func segment(sessionId: String, url: URL, modified: Date, size: Int) -> MuseCodeTokenSegment? {
        guard size > 0, size <= maxSnapshotBytes,
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let continuation = root["continuation"] as? [String: Any],
              let materialization = continuation["view_materialization"] as? [String: Any],
              let state = materialization["current_state"] as? [String: Any],
              let usage = state["tokenUsage"] as? [String: Any],
              let modelId = usage["modelId"] as? String, !modelId.isEmpty,
              let total = number(usage["totalTokens"]), total >= 0 else { return nil }
        let range = usage["sourceRange"] as? [String: Any]
        return MuseCodeTokenSegment(
            sessionId: sessionId,
            modelId: modelId,
            totalTokens: Int(total.rounded()),
            promptTokens: number(usage["promptTokens"]).map { Int($0.rounded()) },
            observedAt: modified,
            sourceFirstId: (range?["first"] as? [String: Any])?["id"] as? String,
            sourceLastId: (range?["last"] as? [String: Any])?["id"] as? String)
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    /// The aggregation the surveys validated, as a pure function so it can be
    /// tested without a session store: dedupe segments per session by source
    /// range, then sum per model inside each trailing window.
    public static func aggregate(segments raw: [MuseCodeTokenSegment],
                                 sessionActivity: [String: Date],
                                 latestObservations: [MuseCodeSessionObservation] = [],
                                 now: Date) -> MuseCodeSessionReport {
        // The stores rotate snapshots aggressively: a segment whose snapshot
        // file has already been rotated away is invisible here, and a session
        // that ends mid-window leaves only the segments still on disk.  Every
        // total this aggregation produces is therefore a floor, not an exact
        // count — the plugin page says so wherever it shows these numbers.
        var seen = Set<String>()
        var segments: [MuseCodeTokenSegment] = []
        for segment in raw.sorted(by: { $0.observedAt < $1.observedAt }) {
            guard seen.insert(segment.sessionId + "\u{1}" + segment.dedupeKey).inserted else { continue }
            segments.append(segment)
        }
        let horizon = now.addingTimeInterval(futureTolerance)
        let windows = windowMinutes.map { minutes -> MuseCodeWindowUsage in
            let cutoff = now.addingTimeInterval(-Double(minutes) * 60)
            var byModel: [String: (tokens: Int, segments: Int, sessions: Set<String>)] = [:]
            for segment in segments where segment.observedAt >= cutoff && segment.observedAt <= horizon {
                var entry = byModel[segment.modelId] ?? (tokens: 0, segments: 0, sessions: [])
                entry.tokens += segment.totalTokens
                entry.segments += 1
                entry.sessions.insert(segment.sessionId)
                byModel[segment.modelId] = entry
            }
            let models = byModel
                .map { MuseCodeModelUsage(modelId: $0.key, tokens: $0.value.tokens,
                                          segmentCount: $0.value.segments,
                                          sessionCount: $0.value.sessions.count) }
                .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.modelId < $1.modelId }
            let total = models.reduce(0) { $0 + $1.tokens }
            let contributor = models.filter(\.isContributor).reduce(0) { $0 + $1.tokens }
            let active = sessionActivity.filter { $0.value >= cutoff && $0.value <= horizon }.count
            return MuseCodeWindowUsage(
                windowMinutes: minutes,
                totalTokens: total,
                contributorTokens: contributor,
                contributorShare: total > 0 ? Double(contributor) / Double(total) : nil,
                activeSessions: active,
                models: models)
        }
        let cutoff90 = now.addingTimeInterval(-90 * 60)
        return MuseCodeSessionReport(
            generatedAt: now,
            windows: windows,
            segments: segments.filter { $0.observedAt >= cutoff90 && $0.observedAt <= horizon },
            latestObservations: latestObservations)
    }
}
