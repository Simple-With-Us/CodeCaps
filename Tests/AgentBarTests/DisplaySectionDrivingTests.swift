import XCTest
@testable import AgentBar
@testable import QuotaCore

/// `DisplaySection.driving` is the single window a Glance or sidebar row is
/// about: the lowest remaining percentage, falling back to the first window
/// when none reports one.  When two windows tie on their percentage, the row
/// used to flip between them on every refresh.  Audit fix #4 captures the
/// driving window's id at construction time so `driving` returns the same
/// snapshot every call, regardless of which copy of the section is in hand.
@MainActor
final class DisplaySectionDrivingTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-13T10:05:00Z")!
    private let observedAt = "2026-09-13T10:00:00Z"

    /// Two windows with the same remaining percentage must resolve to the same
    /// driving window across many calls.  Without the captured id, the choice
    /// depends on the order SwiftUI happens to hand us today.
    func testDrivingIsStableAcrossRepeatedCallsWhenPercentagesTie() {
        let section = QuotaPlatformSection(
            providerKey: "anthropic",
            providerLabel: "Claude",
            via: nil,
            expected: true,
            windows: [
                snapshot("claude-5h", percent: 40, label: "5-hour"),
                snapshot("claude-weekly", percent: 40, label: "Weekly"),
            ])
        let rows = DisplaySection.rows(for: section, now: now)
        XCTAssertEqual(rows.count, 1)
        let row = try! XCTUnwrap(rows.first)

        var chosen: [String] = []
        for _ in 0..<16 {
            chosen.append(row.driving?.window.id ?? "")
        }
        XCTAssertTrue(chosen.allSatisfy { $0 == chosen.first }, "driving must not flip: \(chosen)")
    }

    /// The preferred id drives the choice when it points at a window in the
    /// section, even if the same percentage also exists on a different window.
    func testTheCapturedDrivingIdWinsOverFirstMatchByPercentage() {
        let section = QuotaPlatformSection(
            providerKey: "anthropic",
            providerLabel: "Claude",
            via: nil,
            expected: true,
            windows: [
                snapshot("claude-5h", percent: 40, label: "5-hour"),
                snapshot("claude-weekly", percent: 40, label: "Weekly"),
            ])
        let drivingId = "claude-weekly"
        let row = DisplaySection(id: "anthropic",
                                 providerKey: "anthropic",
                                 title: "Claude",
                                 platformTitle: "Claude",
                                 section: section,
                                 poolKey: nil,
                                 remainingPercent: 40,
                                 resetAt: nil,
                                 maskedWindowIds: [],
                                 drivingWindowId: drivingId)
        XCTAssertEqual(row.driving?.window.id, drivingId)
    }

    /// When the captured id is absent, the lowest percentage wins; ties break
    /// on the first match, which is the previous behaviour and remains in place
    /// so this audit fix does not silently reorder existing rows.
    func testLowestPercentStillWinsWhenNoCapturedIdIsPresent() {
        let section = QuotaPlatformSection(
            providerKey: "anthropic",
            providerLabel: "Claude",
            via: nil,
            expected: true,
            windows: [
                snapshot("claude-5h", percent: 70, label: "5-hour"),
                snapshot("claude-weekly", percent: 30, label: "Weekly"),
            ])
        let rows = DisplaySection.rows(for: section, now: now)
        let row = try! XCTUnwrap(rows.first)
        XCTAssertEqual(row.driving?.window.id, "claude-weekly")
    }

    private func snapshot(_ id: String, percent: Double, label: String) -> QuotaWindowSnapshot {
        QuotaWindowSnapshot(window: QuotaWindow(
            id: id, provider: "Claude", providerKey: "anthropic",
            label: label, remainingPercent: percent,
            occurredAt: observedAt), now: now)
    }
}