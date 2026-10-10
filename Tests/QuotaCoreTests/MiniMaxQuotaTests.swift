import Foundation
import XCTest
@testable import QuotaCore

final class MiniMaxQuotaTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_789_000_000)

    func testCountFieldsAreRemainingCountsAndNoAggregateCapIsInvented() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(#"{"api_key":"test-key"}"#, to: home.appendingPathComponent(".mmx/config.json"))
        let reader = makeReader(home: home, body: #"{"base_resp":{"status_code":0},"model_remains":[{"model_name":"MiniMax-M2","current_interval_usage_count":1444,"current_interval_total_count":1500,"current_weekly_usage_count":349,"current_weekly_total_count":350}]}"#)

        let result = await reader.read()
        let windows = result.windows.filter { $0.providerKey == "minimax" }
        XCTAssertEqual(windows.count, 2)
        let interval = try XCTUnwrap(windows.first { $0.window == nil || $0.window == "" || $0.id.contains(":interval") })
        XCTAssertEqual(interval.remainingPercent ?? -1, 1444.0 / 1500.0 * 100, accuracy: 0.0001)
        XCTAssertEqual(interval.absoluteRemaining, 1444)
        XCTAssertEqual(interval.absoluteLimit, 1500)
        XCTAssertFalse(windows.contains { $0.id.contains("coding-plan") || $0.label.lowercased().contains("all models") })
    }

    func testTimePlanUsesExplicitPercentagesAndMillisecondResets() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(#"{"api_key":"test-key"}"#, to: home.appendingPathComponent(".mmx/config.json"))
        let body = #"{"base_resp":{"status_code":0},"model_remains":[{"model_name":"general","current_interval_usage_count":0,"current_interval_total_count":0,"current_weekly_usage_count":0,"current_weekly_total_count":0,"current_interval_remaining_percent":99,"current_weekly_remaining_percent":97,"remains_time":14998196,"weekly_remains_time":547798196}]}"#
        let result = await makeReader(home: home, body: body).read()
        let windows = result.windows.filter { $0.providerKey == "minimax" }
        XCTAssertEqual(windows.count, 2)
        let interval = try XCTUnwrap(windows.first { $0.id.hasSuffix(":interval") })
        let weekly = try XCTUnwrap(windows.first { $0.id.hasSuffix(":weekly") })
        XCTAssertEqual(interval.remainingPercent, 99)
        XCTAssertEqual(weekly.remainingPercent, 97)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        XCTAssertEqual(interval.resetAt, formatter.string(from: observedAt.addingTimeInterval(14998196 / 1000)))
        XCTAssertEqual(weekly.resetAt, formatter.string(from: observedAt.addingTimeInterval(547798196 / 1000)))
        XCTAssertNil(interval.absoluteLimit)
        XCTAssertNil(weekly.absoluteLimit)
    }

    /// Each window's own start time is carried through as its explicit period
    /// start for the elapsed-time marker, and a window the API gives no start
    /// time for has none, so its marker is derived from its cadence or omitted.
    func testWindowStartTimesBecomeExplicitPeriodStarts() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(#"{"api_key":"test-key"}"#, to: home.appendingPathComponent(".mmx/config.json"))
        let body = #"{"base_resp":{"status_code":0},"model_remains":[{"model_name":"general","current_interval_remaining_percent":60,"current_weekly_remaining_percent":90,"current_interval_start_time":"2026-09-30T05:00:00Z","current_interval_end_time":"2026-09-30T10:00:00Z","current_weekly_start_time":"2026-09-28T00:00:00Z","current_weekly_end_time":"2026-10-05T00:00:00Z"}]}"#
        let result = await makeReader(home: home, body: body).read()
        let windows = result.windows.filter { $0.providerKey == "minimax" }
        let interval = try XCTUnwrap(windows.first { $0.id.hasSuffix(":interval") })
        let weekly = try XCTUnwrap(windows.first { $0.id.hasSuffix(":weekly") })
        XCTAssertEqual(interval.periodStart, "2026-09-30T05:00:00Z")
        XCTAssertEqual(interval.window, "5h")
        XCTAssertEqual(interval.label, "5-hour window")
        XCTAssertEqual(weekly.periodStart, "2026-09-28T00:00:00Z")
        XCTAssertEqual(weekly.window, "1w")
        XCTAssertEqual(weekly.label, "weekly window")

        let noStarts = #"{"base_resp":{"status_code":0},"model_remains":[{"model_name":"general","current_interval_remaining_percent":99,"current_weekly_remaining_percent":97,"remains_time":14998196,"weekly_remains_time":547798196}]}"#
        let bare = await makeReader(home: home, body: noStarts).read().windows.filter { $0.providerKey == "minimax" }
        XCTAssertTrue(bare.allSatisfy { $0.periodStart == nil })
    }

    func testNonPositiveCountsDoNotBecomeAQuota() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(#"{"api_key":"test-key"}"#, to: home.appendingPathComponent(".mmx/config.json"))
        let body = #"{"base_resp":{"status_code":0},"model_remains":[{"model_name":"video","current_interval_usage_count":0,"current_interval_total_count":0,"current_weekly_usage_count":0,"current_weekly_total_count":0}]}"#
        let result = await makeReader(home: home, body: body).read()
        let video = try XCTUnwrap(result.windows.first { $0.providerKey == "minimax" })
        XCTAssertNil(video.remainingPercent)
        XCTAssertNil(video.absoluteRemaining)
        XCTAssertNil(video.absoluteLimit)
        XCTAssertEqual(video.status, .unknown)
    }

    private func makeReader(home: URL, body: String) -> LocalQuotaReader {
        LocalQuotaReader(
            homeDirectory: home,
            now: { self.observedAt },
            fetchJSON: { request in
                XCTAssertEqual(request.url?.host, "api.minimax.io")
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (Data(body.utf8), response)
            },
            runAntigravity: { Data(#"{}"#.utf8) }
        )
    }

    func testMiniMaxCadenceOrderStandardizedFiveHourFirst() {
        let weekly = QuotaWindow(
            id: "local-mac:minimax:general:weekly",
            provider: "minimax",
            providerKey: "minimax",
            label: "weekly window",
            remainingPercent: 10,
            occurredAt: "2026-10-04T12:00:00Z"
        )
        let fiveHour = QuotaWindow(
            id: "local-mac:minimax:general:interval",
            provider: "minimax",
            providerKey: "minimax",
            label: "5-hour window",
            remainingPercent: 90,
            occurredAt: "2026-10-04T12:00:00Z"
        )
        let response = QuotaResponse(generatedAt: "2026-10-04T12:00:00Z", windows: [weekly, fiveHour], skipModelTypes: [])
        let sections = response.platformSections(now: Date())
        let section = sections.first { $0.providerKey == "minimax" }
        XCTAssertNotNil(section)
        XCTAssertEqual(section?.windows.count, 2)
        XCTAssertEqual(section?.windows[0].window.id, "local-mac:minimax:general:interval")
        XCTAssertEqual(section?.windows[1].window.id, "local-mac:minimax:general:weekly")
    }

    private func makeHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("minimax-quota-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".mmx"), withIntermediateDirectories: true)
        return home
    }

    private func write(_ value: String, to url: URL) throws {
        try Data(value.utf8).write(to: url, options: .atomic)
    }
}
