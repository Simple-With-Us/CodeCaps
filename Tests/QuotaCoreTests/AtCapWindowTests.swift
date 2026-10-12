import Foundation
@testable import QuotaCore
import XCTest

/// Pins the rule every surface asks when it decides whether to draw a bar or
/// say "At Cap".
///
/// The failure this guards against is a plan that cannot be used at all —
/// Claude's weekly allowance spent — drawing a full bar labelled 100% because
/// its 5-hour window still had headroom (owner 2026-10-11).  The widget target
/// cannot import QuotaCore, so it mirrors this rule in
/// `WidgetPresentation.isAtCap(percent:isExhausted:)`; these tests are the
/// shared half of that contract.
final class AtCapWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    private func snapshot(
        id: String,
        label: String = "Window",
        token: String? = nil,
        remaining: Double?,
        resetIn: TimeInterval?,
        provider: String = "anthropic",
        model: String? = nil,
        exhausted: Bool = false
    ) -> QuotaWindowSnapshot {
        let iso = ISO8601DateFormatter()
        return QuotaWindowSnapshot(window: QuotaWindow(
            id: id,
            provider: provider,
            providerKey: provider,
            providerLabel: provider,
            modelId: model,
            label: label,
            remainingPercent: remaining,
            remainingUnknown: remaining == nil,
            isExhausted: exhausted,
            resetAt: resetIn.map { iso.string(from: now.addingTimeInterval($0)) },
            window: token,
            occurredAt: iso.string(from: now)), now: now)
    }

    private func section(_ windows: [QuotaWindowSnapshot]) -> QuotaPlatformSection {
        QuotaPlatformSection(
            providerKey: "anthropic",
            providerLabel: "Claude",
            via: nil,
            expected: true,
            windows: windows)
    }

    // MARK: One window

    func testZeroRemainingIsACap() {
        XCTAssertTrue(snapshot(id: "w", remaining: 0, resetIn: day).isAtCap)
    }

    func testAPositiveReadingIsNotACap() {
        XCTAssertFalse(snapshot(id: "w", remaining: 100, resetIn: day).isAtCap)
    }

    func testNoReadingIsNotACap() {
        XCTAssertFalse(snapshot(id: "w", remaining: nil, resetIn: day).isAtCap,
                       "an unreadable window is not a spent one")
    }

    func testAnExplicitExhaustedFlagIsACapWithoutAPercentage() {
        XCTAssertTrue(snapshot(id: "w", remaining: nil, resetIn: day, exhausted: true).isAtCap)
    }

    func testAFreshPositiveReadingBeatsAStaleExhaustedFlag() {
        // `normalizedForExport` only ever sets `isExhausted`, never clears it, so
        // a window that was spent and then refilled keeps the flag.  Believing
        // the flag would keep reporting a cap after the allowance came back.
        XCTAssertFalse(snapshot(id: "w", remaining: 100, resetIn: day, exhausted: true).isAtCap,
                       "the reading is the fresher evidence")
    }

    // MARK: A plan

    func testOneSpentWindowCapsThePlan() {
        let subject = section([
            snapshot(id: "session", token: "5h", remaining: 100, resetIn: 5 * hour),
            snapshot(id: "weekly", token: "168h", remaining: 0, resetIn: day + 21 * hour),
        ])
        XCTAssertTrue(subject.isAtCap)
        XCTAssertEqual(subject.atCapWindow()?.window.id, "weekly")
    }

    func testTheSoonestSpentResetIsReported() {
        let subject = section([
            snapshot(id: "weekly", token: "168h", remaining: 0, resetIn: 5 * day),
            snapshot(id: "session", token: "5h", remaining: 0, resetIn: 3 * hour),
        ])
        XCTAssertEqual(subject.atCapWindow()?.window.id, "session")
    }

    func testASpentWindowWithNoResetSortsLast() {
        let subject = section([
            snapshot(id: "unknown-reset", remaining: 0, resetIn: nil),
            snapshot(id: "session", token: "5h", remaining: 0, resetIn: 3 * hour),
        ])
        XCTAssertEqual(subject.atCapWindow()?.window.id, "session",
                       "a reset that is known is more use than one that is not")
    }

    func testHeadroomOnEveryWindowIsNotACap() {
        let subject = section([
            snapshot(id: "session", token: "5h", remaining: 92, resetIn: 3 * hour),
            snapshot(id: "weekly", token: "168h", remaining: 11, resetIn: 4 * day),
        ])
        XCTAssertFalse(subject.isAtCap)
        XCTAssertNil(subject.atCapWindow())
    }

    func testAWindowWithNoReadingDoesNotCapThePlan() {
        let subject = section([
            snapshot(id: "session", remaining: nil, resetIn: 3 * hour),
            snapshot(id: "weekly", remaining: 40, resetIn: 4 * day),
        ])
        XCTAssertFalse(subject.isAtCap)
    }

    func testASupplementaryVideoAllowanceDoesNotCapMiniMax() {
        let subject = section([
            snapshot(id: "session", token: "5h", remaining: 64, resetIn: 3 * hour, provider: "minimax"),
            snapshot(id: "video", label: "Video generation", remaining: 0, resetIn: day,
                     provider: "minimax", model: "video-hailuo"),
        ])
        XCTAssertFalse(subject.isAtCap,
                       "the video bonus is not the coding subscription")
    }

    func testAnEmptySectionIsNotACap() {
        XCTAssertFalse(QuotaPlatformSection(
            providerKey: "anthropic", providerLabel: "Claude",
            via: nil, expected: true, windows: []).isAtCap)
    }
}