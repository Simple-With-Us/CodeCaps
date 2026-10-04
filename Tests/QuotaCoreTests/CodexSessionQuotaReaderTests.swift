import Foundation
import XCTest
@testable import QuotaCore

final class CodexSessionQuotaReaderTests: XCTestCase {
    private let clock = ISO8601DateFormatter().date(from: "2026-10-03T12:00:00Z")!

    func testMatchingAccountAndStableObservationAcrossPolls() async throws {
        let fixture = try Fixture(now: clock)
        defer { fixture.remove() }
        try fixture.auth("account-a")
        let file = try fixture.session("a.jsonl", account: "account-a", lines: [
            fixture.event(at: "2026-10-03T11:55:00Z", used: 20, secondary: 35)
        ])
        let reader = CodexSessionQuotaReader(homeDirectory: fixture.home, now: { self.clock })
        let first = await reader.read()
        XCTAssertEqual(first.windows.map(\.id), ["local-mac:openai:primary", "local-mac:openai:secondary"])
        XCTAssertEqual(first.windows.first?.remainingPercent, 80)
        XCTAssertEqual(first.windows.first?.source, "Codex Session Files")
        XCTAssertEqual(first.windows.first?.accountKey, "account-a")
        XCTAssertEqual(first.windows.first?.occurredAt, "2026-10-03T11:55:00Z")
        let repeatRead = await reader.read()
        XCTAssertEqual(repeatRead.windows, first.windows)
        try fixture.append(fixture.event(at: "2026-10-03T11:58:00Z", used: 30), to: file)
        let updated = await reader.read()
        XCTAssertEqual(updated.windows.first?.remainingPercent, 70)
        XCTAssertEqual(updated.windows.first?.occurredAt, "2026-10-03T11:58:00Z")
        XCTAssertEqual(updated.windows.last?.occurredAt, "2026-10-03T11:55:00Z")
    }

    func testMissingAndMismatchedMetadataFailClosedAndAccountSwitchClearsCache() async throws {
        let fixture = try Fixture(now: clock)
        defer { fixture.remove() }
        try fixture.auth("account-a")
        _ = try fixture.session("a.jsonl", account: "account-a", lines: [fixture.event(at: "2026-10-03T11:55:00Z", used: 20)])
        let reader = CodexSessionQuotaReader(homeDirectory: fixture.home, now: { self.clock })
        let first = await reader.read()
        XCTAssertEqual(first.windows.count, 1)
        try fixture.auth("account-b")
        let switched = await reader.read()
        XCTAssertTrue(switched.windows.isEmpty)
        _ = try fixture.session("b.jsonl", account: nil, lines: [fixture.event(at: "2026-10-03T11:56:00Z", used: 10)])
        let missingMetadata = await reader.read()
        XCTAssertTrue(missingMetadata.windows.isEmpty)
        _ = try fixture.session("c.jsonl", account: "account-b", lines: [fixture.event(at: "2026-10-03T11:57:00Z", used: 40)])
        let result = await reader.read()
        XCTAssertEqual(result.windows.first?.remainingPercent, 60)
        XCTAssertEqual(result.windows.first?.accountKey, "account-b")
    }

    func testPartialLineCompletesWithoutStampingPollTime() async throws {
        let fixture = try Fixture(now: clock)
        defer { fixture.remove() }
        try fixture.auth("account-a")
        let file = try fixture.session("a.jsonl", account: "account-a", lines: [])
        let event = fixture.event(at: "2026-10-03T11:50:00Z", used: 25)
        try fixture.append(String(event.dropLast()), to: file)
        let reader = CodexSessionQuotaReader(homeDirectory: fixture.home, now: { self.clock })
        let partial = await reader.read()
        XCTAssertTrue(partial.windows.isEmpty)
        try fixture.append(String(event.suffix(1)) + "\n", to: file)
        let completed = await reader.read()
        XCTAssertEqual(completed.windows.first?.occurredAt, "2026-10-03T11:50:00Z")
    }

    func testTruncationAndRotationRestartAtNewMetadata() async throws {
        let fixture = try Fixture(now: clock)
        defer { fixture.remove() }
        try fixture.auth("account-a")
        let file = try fixture.session("a.jsonl", account: "account-a", lines: [fixture.event(at: "2026-10-03T11:40:00Z", used: 10)])
        let reader = CodexSessionQuotaReader(homeDirectory: fixture.home, now: { self.clock })
        let first = await reader.read()
        XCTAssertEqual(first.windows.first?.remainingPercent, 90)
        try fixture.replace(file, account: "account-a", lines: [fixture.event(at: "2026-10-03T11:45:00Z", used: 20)])
        let truncated = await reader.read()
        XCTAssertEqual(truncated.windows.first?.remainingPercent, 80)
        try FileManager.default.removeItem(at: file)
        try fixture.replace(file, account: "account-a", lines: [fixture.event(at: "2026-10-03T11:50:00Z", used: 30)])
        let rotated = await reader.read()
        XCTAssertEqual(rotated.windows.first?.remainingPercent, 70)
    }

    func testSymlinkAndUnknownPoolAreIgnored() async throws {
        let fixture = try Fixture(now: clock)
        defer { fixture.remove() }
        try fixture.auth("account-a")
        let outside = fixture.home.appendingPathComponent("outside.jsonl")
        try fixture.replace(outside, account: "account-a", lines: [fixture.event(at: "2026-10-03T11:55:00Z", used: 5)])
        try FileManager.default.createSymbolicLink(at: fixture.day.appendingPathComponent("link.jsonl"), withDestinationURL: outside)
        _ = try fixture.session("other.jsonl", account: "account-a", lines: [fixture.event(at: "2026-10-03T11:55:00Z", used: 5, limitID: "other-pool")])
        let reader = CodexSessionQuotaReader(homeDirectory: fixture.home, now: { self.clock })
        let result = await reader.read()
        XCTAssertTrue(result.windows.isEmpty)
    }

    func testBoundsAndInvalidEventsDoNotCreateQuota() async throws {
        let fixture = try Fixture(now: clock)
        defer { fixture.remove() }
        try fixture.auth("account-a")
        let oversized = String(repeating: "x", count: 70_000)
        _ = try fixture.session("a.jsonl", account: "account-a", lines: [
            fixture.event(at: "2026-10-03T11:55:00Z", used: 10, extra: oversized),
            fixture.event(at: "2026-10-03T12:10:00Z", used: 10),
            fixture.event(at: "2026-10-01T11:55:00Z", used: 10),
            fixture.event(at: "2026-10-03T11:55:00Z", used: 120),
            fixture.event(at: "2026-10-03T11:55:00Z", used: -1)
        ])
        let reader = CodexSessionQuotaReader(homeDirectory: fixture.home, now: { self.clock })
        let result = await reader.read()
        XCTAssertTrue(result.windows.isEmpty)
        XCTAssertNotNil(result.issues["openai"])
    }

    func testNoQuotaEventDoesNotReplaceLastObservation() async throws {
        let fixture = try Fixture(now: clock)
        defer { fixture.remove() }
        try fixture.auth("account-a")
        let file = try fixture.session("a.jsonl", account: "account-a", lines: [fixture.event(at: "2026-10-03T11:55:00Z", used: 20)])
        let reader = CodexSessionQuotaReader(homeDirectory: fixture.home, now: { self.clock })
        let original = await reader.read()
        try fixture.append(#"{"timestamp":"2026-10-03T11:59:00Z","type":"event_msg","payload":{"type":"other"}}"# + "\n", to: file)
        let unchanged = await reader.read()
        XCTAssertEqual(unchanged.windows, original.windows)
    }
}

private struct Fixture {
    let home: URL
    let day: URL

    init(now: Date) throws {
        home = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("CodexQuota-\(UUID().uuidString)")
        day = home.appendingPathComponent(".codex/sessions/2026/10/03")
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
    }

    func remove() { try? FileManager.default.removeItem(at: home) }

    func auth(_ account: String) throws {
        let url = home.appendingPathComponent(".codex/auth.json")
        let data = try JSONSerialization.data(withJSONObject: ["tokens": ["account_id": account]])
        try data.write(to: url)
    }

    func session(_ name: String, account: String?, lines: [String]) throws -> URL {
        let url = day.appendingPathComponent(name)
        try replace(url, account: account, lines: lines)
        return url
    }

    func replace(_ url: URL, account: String?, lines: [String]) throws {
        let meta = try JSONSerialization.data(withJSONObject: ["type": "session_meta", "payload": account.map { ["creator_account_id": $0] } ?? [:]])
        let content = String(data: meta, encoding: .utf8)! + "\n" + lines.map { $0 + "\n" }.joined()
        try Data(content.utf8).write(to: url)
    }

    func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    func event(at timestamp: String, used: Double, secondary: Double? = nil,
               limitID: String = "codex", extra: String? = nil) -> String {
        var limits: [String: Any] = ["limit_id": limitID,
                                     "primary": ["used_percent": used, "window_minutes": 300, "reset_after_seconds": 3600]]
        if let secondary { limits["secondary"] = ["used_percent": secondary, "window_minutes": 10080, "reset_after_seconds": 604800] }
        var payload: [String: Any] = ["type": "token_count", "rate_limits": limits]
        if let extra { payload["ignored"] = extra }
        let root: [String: Any] = ["timestamp": timestamp, "type": "event_msg", "payload": payload]
        let data = try! JSONSerialization.data(withJSONObject: root)
        return String(data: data, encoding: .utf8)!
    }
}
