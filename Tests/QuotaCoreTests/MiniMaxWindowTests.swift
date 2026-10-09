import Foundation
import XCTest
@testable import QuotaCore

/// MiniMax's coding-plan interval window is 5 hours.
///
/// It used to be *derived* from the payload's `start_time` / `end_time` pair.
/// MiniMax reports a rolling interval whose boundaries drift, so that
/// subtraction intermittently produced a 4-hour token, which reached the Glance
/// row, the menu bar and reset notifications as "4h window".  The owner
/// reported it as a historic hallucination, and these tests pin the correct
/// value so the derivation cannot creep back.
final class MiniMaxWindowTests: XCTestCase {
    private func payload(intervalStart: String?, intervalEnd: String) -> [String: Any] {
        var row: [String: Any] = [
            "model_name": "general",
            "current_interval_remaining_percent": 50,
            "end_time": intervalEnd,
        ]
        if let intervalStart { row["start_time"] = intervalStart }
        return ["base_resp": ["status_code": 0], "model_remains": [row]]
    }

    private func generalWindow(_ root: [String: Any]) throws -> QuotaWindow {
        let windows = MiniMaxWindowProbe.parse(root, observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let tokens = windows.map { $0.window ?? "nil" }.joined(separator: ", ")
        let general = try XCTUnwrap(
            windows.first(where: { $0.modelId?.lowercased() == "general" }),
            "no general window parsed; tokens were: \(tokens)")
        return general
    }

    /// The reported bug: a start/end pair 4 hours apart produced "4h".
    func testAFourHourWideIntervalStillReportsFiveHours() throws {
        let root = payload(intervalStart: "2026-09-20T00:00:00Z", intervalEnd: "2026-09-20T04:00:00Z")
        let window = try generalWindow(root)
        XCTAssertEqual(window.window, "5h", "a drifting interval boundary must not shrink the window to 4h")
        XCTAssertEqual(window.label, "5-hour window")
    }

    /// The common case: the boundaries agree with 5 hours.
    func testAFiveHourWideIntervalReportsFiveHours() throws {
        let root = payload(intervalStart: "2026-09-20T00:00:00Z", intervalEnd: "2026-09-20T05:00:00Z")
        let window = try generalWindow(root)
        XCTAssertEqual(window.window, "5h")
        XCTAssertEqual(window.label, "5-hour window")
    }

    /// No start time at all is the normal shape of the payload; it must still
    /// name the window rather than falling back to an unlabelled one.
    func testAMissingStartTimeStillReportsFiveHours() throws {
        let root = payload(intervalStart: nil, intervalEnd: "2026-09-20T05:00:00Z")
        let window = try generalWindow(root)
        XCTAssertEqual(window.window, "5h")
        XCTAssertEqual(window.label, "5-hour window")
    }

    /// Only the general coding window is pinned.  Video is a separate,
    /// supplementary allowance with its own daily cadence, and must not be
    /// relabelled as the 5-hour coding window.
    func testVideoWindowsAreNotRelabelledAsTheCodingWindow() throws {
        let root: [String: Any] = [
            "base_resp": ["status_code": 0],
            "model_remains": [
                ["model_name": "video", "current_interval_remaining_count": 3,
                 "current_interval_total_count": 5, "end_time": "2026-09-20T04:00:00Z"],
            ],
        ]
        let windows = MiniMaxWindowProbe.parse(root, observedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let video = try XCTUnwrap(windows.first(where: { $0.modelId?.lowercased() == "video" }))
        XCTAssertNotEqual(video.window, "5h", "the supplementary video allowance is not the 5-hour coding window")
        XCTAssertEqual(video.label, "Video")
    }
}