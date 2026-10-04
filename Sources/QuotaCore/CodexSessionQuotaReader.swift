import Darwin
import Foundation

/// Reads quota events written by the signed-in Codex CLI.  It never reads
/// conversation content beyond a bounded JSON line and never contacts Codex.
public actor CodexSessionQuotaReader {
    private let homeDirectory: URL
    private let now: @Sendable () -> Date
    private var accountID: String?
    private var cursors: [URL: Cursor] = [:]
    private var latest: [String: Observation] = [:]

    private static let maxDays = 7
    private static let maxFiles = 64
    private static let maxPrefix = 16_384
    private static let maxRead = 262_144
    private static let maxTotalRead = 2_097_152
    private static let maxLine = 65_536
    private static let maxAuth = 1_048_576
    private static let maxAge: TimeInterval = 86_400
    private static let futureTolerance: TimeInterval = 120

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                now: @escaping @Sendable () -> Date = { Date() }) {
        let path = Self.canonicalPath(homeDirectory.path)
        self.homeDirectory = URL(fileURLWithPath: path, isDirectory: true)
        self.now = now
    }

    public func read() async -> LocalQuotaResult {
        let instant = now()
        guard let current = readAccountID() else {
            accountID = nil
            cursors.removeAll()
            latest.removeAll()
            return LocalQuotaResult(issues: ["openai": "Codex is not signed in locally."])
        }
        if accountID != current {
            accountID = current
            cursors.removeAll()
            latest.removeAll()
        }

        var budget = Self.maxTotalRead
        let files = recentFiles(at: instant)
        for file in files where budget > 0 {
            scan(file, accountID: current, at: instant, budget: &budget)
        }
        cursors = cursors.filter { files.contains($0.key) }
        latest = latest.filter { _, item in isFresh(item, at: instant) }
        let windows = latest.values.map(\.window).sorted { $0.id < $1.id }
        return windows.isEmpty
            ? LocalQuotaResult(issues: ["openai": "No recent Codex session quota is available."])
            : LocalQuotaResult(windows: windows)
    }

    /// Recheck the bounded local auth identity after an asynchronous quota read.
    /// A login switch during a read must not publish the previous account's quotas.
    public func currentAccountID() -> String? { readAccountID() }

    private struct Cursor {
        let device: UInt64
        let inode: UInt64
        var offset: Int64
        var modificationNanoseconds: Int64
        let matchesAccount: Bool
    }

    private struct Observation {
        let window: QuotaWindow
        let date: Date
        let reset: Date?
        let file: URL
    }

    private func readAccountID() -> String? {
        let url = homeDirectory.appendingPathComponent(".codex/auth.json")
        guard let data = boundedFile(url, maxBytes: Self.maxAuth),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let account = tokens["account_id"] as? String,
              !account.isEmpty, account.utf8.count <= 256 else { return nil }
        return account
    }

    private func recentFiles(at instant: Date) -> [URL] {
        let root = homeDirectory.appendingPathComponent(".codex/sessions")
        guard isDirectoryWithoutSymlink(root) else { return [] }
        let calendar = Calendar(identifier: .gregorian)
        var days: [URL] = []
        for offset in 0..<Self.maxDays {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: instant) else { continue }
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            guard let year = parts.year, let month = parts.month, let day = parts.day else { continue }
            let directory = root.appendingPathComponent(String(format: "%04d/%02d/%02d", year, month, day))
            if isDirectoryWithoutSymlink(directory) { days.append(directory) }
        }
        var files: [URL] = []
        for day in days {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: day.path) else { continue }
            for name in names where name.hasSuffix(".jsonl") && !name.contains("/") {
                let url = day.appendingPathComponent(name)
                if secureStat(url, required: .regular) != nil { files.append(url) }
            }
        }
        return Array(files.sorted { $0.path > $1.path }.prefix(Self.maxFiles))
    }

    private enum FileKind: Equatable { case regular, directory }

    private func secureStat(_ url: URL, required: FileKind) -> stat? {
        let base = homeDirectory.path
        let path = url.path
        guard path.hasPrefix(base + "/") else { return nil }
        var current = "/"
        var info = stat()
        for component in base.split(separator: "/") {
            current += (current == "/" ? "" : "/") + String(component)
            guard Darwin.lstat(current, &info) == 0,
                  (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        }
        for component in path.dropFirst(base.count + 1).split(separator: "/") {
            current += "/" + String(component)
            guard Darwin.lstat(current, &info) == 0 else { return nil }
            let kind = info.st_mode & S_IFMT
            if current == path {
                guard kind == (required == .regular ? S_IFREG : S_IFDIR) else { return nil }
            } else if kind != S_IFDIR { return nil }
        }
        return info
    }

    private func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        secureStat(url, required: .directory) != nil
    }

    private func boundedFile(_ url: URL, maxBytes: Int) -> Data? {
        guard let info = secureStat(url, required: .regular), info.st_size >= 0,
              info.st_size <= maxBytes else { return nil }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var opened = stat()
        guard Darwin.fstat(fd, &opened) == 0,
              opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
              opened.st_size <= maxBytes else { return nil }
        return read(fd, from: 0, count: Int(opened.st_size))
    }

    private func read(_ fd: Int32, from offset: Int64, count: Int) -> Data? {
        guard count >= 0 else { return nil }
        var data = Data(count: count)
        let received = data.withUnsafeMutableBytes { bytes in
            Darwin.pread(fd, bytes.baseAddress, count, off_t(offset))
        }
        guard received >= 0 else { return nil }
        return Data(data.prefix(received))
    }

    private func scan(_ url: URL, accountID: String, at instant: Date, budget: inout Int) {
        guard let info = secureStat(url, required: .regular), info.st_size >= 0 else { return }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return }
        defer { Darwin.close(fd) }
        var opened = stat()
        guard Darwin.fstat(fd, &opened) == 0,
              opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
              (opened.st_mode & S_IFMT) == S_IFREG else { return }
        let size = Int64(opened.st_size)
        let modification = Int64(opened.st_mtimespec.tv_sec) * 1_000_000_000
            + Int64(opened.st_mtimespec.tv_nsec)
        var cursor = cursors[url]
        if cursor?.device != UInt64(opened.st_dev) || cursor?.inode != UInt64(opened.st_ino)
            || (cursor?.offset ?? 0) > size
            || (cursor?.offset == size && cursor?.modificationNanoseconds != modification) {
            cursor = nil
            latest = latest.filter { $0.value.file != url }
        }
        if cursor == nil {
            let count = min(Int(size), Self.maxPrefix, budget)
            guard let prefix = read(fd, from: 0, count: count) else { return }
            budget -= prefix.count
            guard let newline = prefix.firstIndex(of: 10) else {
                // Empty or still-flushing file: no complete first line to
                // identify the session yet.  Don't cache a rejection — a
                // session observed before its first line is written would
                // otherwise stay invisible for the life of the inode.
                return
            }
            guard newline <= Self.maxLine else {
                // First line exceeds the readable bound: not a session_meta
                // header.  The identity definitively does not match.
                cursor = Cursor(device: UInt64(opened.st_dev), inode: UInt64(opened.st_ino), offset: 0,
                                modificationNanoseconds: modification,
                                matchesAccount: false)
                cursors[url] = cursor
                return
            }
            let matches = metadataAccount(in: Data(prefix[..<newline])) == accountID
            cursor = Cursor(device: UInt64(opened.st_dev), inode: UInt64(opened.st_ino), offset: 0,
                            modificationNanoseconds: modification,
                            matchesAccount: matches)
            if !matches { cursors[url] = cursor; return }
        }
        guard var active = cursor, active.matchesAccount, budget > 0 else { return }
        let isInitial = active.offset == 0
        let available = size - active.offset
        guard available > 0 else { cursors[url] = active; return }
        let length = min(Int(available), Self.maxRead, budget)
        let start = isInitial ? max(0, size - Int64(length)) : max(active.offset, size - Int64(length))
        guard let data = read(fd, from: start, count: Int(size - start)) else { return }
        budget -= data.count
        var lineStart = 0
        // A retained cursor starts at a complete-line boundary (or the start
        // of a partial line).  Skip a fragment only when a bounded tail read
        // actually jumped past that cursor.
        if start > active.offset {
            guard let boundary = data.firstIndex(of: 10) else {
                active.offset = size
                cursors[url] = active
                return
            }
            lineStart = boundary + 1
        }
        var consumed = lineStart
        while lineStart < data.count, let end = data[lineStart...].firstIndex(of: 10) {
            if end - lineStart <= Self.maxLine {
                ingest(Data(data[lineStart..<end]), from: url, at: instant, accountID: accountID)
            }
            consumed = end + 1
            lineStart = consumed
        }
        // Retain an incomplete trailing line and reread it on the next poll.
        active.offset = start + Int64(consumed)
        active.modificationNanoseconds = modification
        if size - active.offset > Self.maxLine { active.offset = size }
        cursors[url] = active
    }

    private func metadataAccount(in data: Data) -> String? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["type"] as? String == "session_meta",
              let payload = root["payload"] as? [String: Any] else { return nil }
        return payload["creator_account_id"] as? String
    }

    private func ingest(_ data: Data, from file: URL, at instant: Date, accountID: String) {
        guard !data.isEmpty,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let timestamp = root["timestamp"] as? String,
              let observed = Self.parseDate(timestamp),
              instant.timeIntervalSince(observed) >= -Self.futureTolerance,
              instant.timeIntervalSince(observed) <= Self.maxAge,
              let limits = payload["rate_limits"] as? [String: Any],
              (limits["limit_id"] == nil || limits["limit_id"] as? String == "codex") else { return }
        for slot in ["primary", "secondary"] {
            guard let values = limits[slot] as? [String: Any],
                  let percent = Self.percent(values) else { continue }
            let seconds = Self.number(values["limit_window_seconds"])
                ?? Self.number(values["window_minutes"]).map { $0 * 60 }
            let cadence = seconds.flatMap(Self.windowToken)
            let reset = Self.reset(values, observed: observed)
            let name = cadence.map { "\($0) window" } ?? "\(slot.capitalized) window"
            let window = QuotaWindow(
                id: "local-mac:openai:\(slot)", provider: "Codex", providerKey: "openai",
                providerLabel: "Codex", sourceApp: "local-mac", label: name,
                remainingPercent: percent, resetAt: reset.map(Self.iso), window: cadence,
                occurredAt: Self.iso(observed), source: "Codex Session Files", accountKey: accountID
            ).normalizedForExport()
            let item = Observation(window: window, date: observed, reset: reset, file: file)
            if let previous = latest[slot], previous.date > observed { continue }
            latest[slot] = item
        }
    }

    private func isFresh(_ item: Observation, at instant: Date) -> Bool {
        let age = instant.timeIntervalSince(item.date)
        return age >= -Self.futureTolerance && age <= Self.maxAge
            && (item.reset == nil || item.reset! > instant)
    }

    private static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite else { return nil }
        return value.doubleValue
    }

    private static func percent(_ values: [String: Any]) -> Double? {
        if values["remaining_percent"] != nil {
            guard let direct = number(values["remaining_percent"]), (0...100).contains(direct) else { return nil }
            return direct
        }
        if let used = number(values["used_percent"]), (0...100).contains(used) { return 100 - used }
        return nil
    }

    private static func reset(_ values: [String: Any], observed: Date) -> Date? {
        if let timestamp = values["resets_at"] as? String,
           let date = parseDate(timestamp),
           date.timeIntervalSince(observed) <= 31_536_000 { return date }
        if let epoch = number(values["resets_at"]) {
            let seconds = epoch > 10_000_000_000 ? epoch / 1_000 : epoch
            if seconds >= 0, seconds <= 4_102_444_800 {
                let date = Date(timeIntervalSince1970: seconds)
                if date.timeIntervalSince(observed) <= 31_536_000 { return date }
            }
        }
        if let seconds = number(values["reset_after_seconds"]),
           (0...31_536_000).contains(seconds) { return observed.addingTimeInterval(seconds) }
        return nil
    }

    private static func windowToken(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 60, seconds <= 31_536_000 else { return nil }
        let rounded = Int(seconds.rounded())
        if rounded % 604_800 == 0 { return "\(rounded / 604_800)w" }
        if rounded % 86_400 == 0 { return "\(rounded / 86_400)d" }
        if rounded % 3_600 == 0 { return "\(rounded / 3_600)h" }
        return nil
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    private static func canonicalPath(_ path: String) -> String {
        if let resolved = Darwin.realpath(path, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        return path
    }
}
