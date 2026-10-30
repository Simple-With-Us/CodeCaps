import XCTest
@testable import QuotaCore

/// The PiP HUD's quota rows (owner report, 2026-10-30): a collapsed row keeps
/// its most constrained meter, a platform's own windows come before its
/// per-model windows, and a per-model window is named by its model.
final class QuotaWindowPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(id: String, remaining: Double?, provider: String = "anthropic",
                          via: String? = nil, model: String? = nil, label: String = "7-day",
                          window: String? = "7d") -> QuotaWindowSnapshot {
        let iso = ISO8601DateFormatter()
        return QuotaWindowSnapshot(
            window: QuotaWindow(
                id: id,
                provider: provider,
                providerKey: provider,
                providerLabel: provider,
                via: via,
                modelId: model,
                modelType: model,
                label: label,
                remainingPercent: remaining,
                remainingUnknown: remaining == nil,
                isExhausted: false,
                resetAt: iso.string(from: now.addingTimeInterval(3_600)),
                window: window,
                occurredAt: iso.string(from: now)
            ),
            now: now
        )
    }

    // MARK: Collapsing to one meter

    func testCollapsedRowKeepsTheLowestRemainingMeter() {
        let fiveHour = snapshot(id: "five_hour", remaining: 15, label: "5-hour", window: "5h")
        let weekly = snapshot(id: "seven_day", remaining: 7)
        let kept = QuotaWindowPresentation.collapsedMeters([fiveHour, weekly], limit: 1)
        XCTAssertEqual(kept.map(\.window.id), ["seven_day"],
                       "One meter must be the most constrained window, not the first one")
    }

    func testCollapsedRowKeepsTheFirstMeterWhenItIsLowest() {
        let fiveHour = snapshot(id: "five_hour", remaining: 3, label: "5-hour", window: "5h")
        let weekly = snapshot(id: "seven_day", remaining: 40)
        XCTAssertEqual(QuotaWindowPresentation.collapsedMeters([fiveHour, weekly], limit: 1).map(\.window.id),
                       ["five_hour"])
    }

    func testCollapsedRowRanksAnUnknownPercentageLast() {
        let unknown = snapshot(id: "extra", remaining: nil)
        let weekly = snapshot(id: "seven_day", remaining: 90)
        XCTAssertEqual(QuotaWindowPresentation.collapsedMeters([unknown, weekly], limit: 1).map(\.window.id),
                       ["seven_day"])
    }

    func testRowWithRoomKeepsEveryMeterInOrder() {
        let fiveHour = snapshot(id: "five_hour", remaining: 15, label: "5-hour", window: "5h")
        let weekly = snapshot(id: "seven_day", remaining: 7)
        XCTAssertEqual(QuotaWindowPresentation.collapsedMeters([fiveHour, weekly], limit: 2).map(\.window.id),
                       ["five_hour", "seven_day"])
        XCTAssertEqual(QuotaWindowPresentation.collapsedMeters([fiveHour, weekly], limit: 0).count, 0)
    }

    // MARK: Platform detail order

    func testPerModelWindowsSortAfterThePlatformsOwnWindows() {
        let fiveHour = snapshot(id: "five_hour", remaining: 15, label: "5-hour", window: "5h")
        let fable = snapshot(id: "seven_day_fable", remaining: 0, model: "fable")
        let weekly = snapshot(id: "seven_day", remaining: 7)
        let ordered = QuotaWindowPresentation.primaryFirst([fiveHour, fable, weekly])
        XCTAssertEqual(ordered.map(\.window.id), ["five_hour", "seven_day", "seven_day_fable"])
    }

    func testArgonWindowsSortAfterGeminiWindows() {
        let argon5h = snapshot(id: "argon-5h", remaining: 50, provider: "google-antigravity",
                               via: "antigravity", model: "argon", label: "Gemini 4 Argon · 5-hour", window: "5h")
        let gemini5h = snapshot(id: "gemini-5h", remaining: 80, provider: "google-antigravity",
                                via: "antigravity", label: "Gemini Models · 5-hour", window: "5h")
        let gemini7d = snapshot(id: "gemini-7d", remaining: 60, provider: "google-antigravity",
                                via: "antigravity", label: "Gemini Models · 7-day")
        XCTAssertEqual(QuotaWindowPresentation.primaryFirst([argon5h, gemini5h, gemini7d]).map(\.window.id),
                       ["gemini-5h", "gemini-7d", "argon-5h"])
    }

    // MARK: Model names

    func testClaudeModelWindowIsNamedByItsModel() {
        let fable = snapshot(id: "seven_day_fable", remaining: 0, model: "fable")
        XCTAssertEqual(fable.window.subModelName, "Fable",
                       "The reader's model id names the window when its label is only the cadence")
    }

    func testModelNameComesFromTheReadersLabelWhenItHasOne() {
        let argon = snapshot(id: "argon-7d", remaining: 50, provider: "google-antigravity",
                             via: "antigravity", model: "argon", label: "Gemini 4 Argon · 7-day")
        XCTAssertEqual(argon.window.subModelName, "Gemini 4 Argon")
    }

    func testPrimaryWindowsHaveNoModelName() {
        XCTAssertNil(snapshot(id: "seven_day", remaining: 7).window.subModelName)
        XCTAssertNil(snapshot(id: "gemini-7d", remaining: 60, provider: "google-antigravity",
                              via: "antigravity", label: "Gemini Models · 7-day").window.subModelName)
    }

    func testOpenAIScopedPoolsKeepTheirOwnLabel() {
        let review = snapshot(id: "openai:code-review", remaining: 90, provider: "openai",
                              label: "Code Review · 7-day")
        XCTAssertTrue(review.window.isSubModelLimit)
        XCTAssertNil(review.window.subModelName)
    }
}
