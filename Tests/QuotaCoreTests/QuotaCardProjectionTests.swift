import XCTest
@testable import QuotaCore

final class QuotaCardProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func row(_ id: String, _ provider: String, _ token: String?, _ percent: Double?,
                     label: String = "Quota", model: String? = nil, age: Double = 0,
                     reset: Double = 3600, source: String? = nil) -> QuotaCardProjection.Reading {
        .init(id: id, providerKey: provider, label: label, window: token, modelId: model,
              remainingPercent: percent, resetAt: now.addingTimeInterval(reset),
              reportedAt: now.addingTimeInterval(-age), source: source)
    }

    func testPlanAndUnknownCopiesDoNotDisplaceMiniMaxOrCodexMeters() {
        for provider in ["minimax", "openai"] {
            let rows = [row("plan", provider, nil, nil, label: "Plan"),
                        row("unknown", provider, "7d", nil),
                        row("short", provider, "5h", 92),
                        row("weekly", provider, "7d", 74),
                        row("p:plan-metadata", provider, nil, 100, label: "Plan Details")]
            XCTAssertEqual(QuotaCardProjection.selectedIndices(in: rows, now: now).map { rows[$0].id }, ["short", "weekly"])
        }
    }

    func testPrimaryModelIdsDoNotCreateDuplicateAllowancesButFableIsDistinct() {
        let rows = [row("unknown", "anthropic", "7d", nil),
                    row("short", "anthropic", "5h", 80), row("weekly", "anthropic", "7d", 0),
                    row("fable", "anthropic", "7d", 0, model: "Fable"),
                    row("sonnet", "anthropic", "7d", 15, model: "sonnet")]
        let selected = QuotaCardProjection.selectedIndices(in: rows, now: now).map { rows[$0] }
        XCTAssertEqual(selected.map(\.id), ["short", "weekly", "fable"])
        XCTAssertEqual(selected.last?.displayLabel, "Fable limit")
        XCTAssertNotEqual(rows[2].allowanceKey, rows[3].allowanceKey)
        let minimax = [row("older", "minimax", "5h", 2, model: "MiniMax-M2", age: 30),
                       row("newer", "minimax", "5h", 92, model: "MiniMax-M2.5")]
        XCTAssertEqual(QuotaCardProjection.selectedIndices(in: minimax, now: now), [1])
    }

    func testMeasurableMacReadingWinsMirrorAndUnknownMacNeverWinsReading() {
        let rows = [row("mirror", "github-copilot", "1m", 0),
                    row("local-mac:copilot:premium", "github-copilot", "1m", 100, age: 30),
                    row("local-mac:copilot:unknown", "github-copilot", "1m", nil)]
        XCTAssertEqual(QuotaCardProjection.selectedIndices(in: rows, now: now), [1])
        XCTAssertEqual(QuotaCardProjection.preferredIndex(in: [rows[0], rows[2]], now: now), 0)
        let expiredMac = row("local-mac:old", "github-copilot", "1m", 0, age: 60, reset: -1)
        XCTAssertEqual(QuotaCardProjection.preferredIndex(in: [rows[0], expiredMac], now: now), 0)
    }

    func testUnknownOnlyProviderHasNoInventedQuotaAndCountOnlyExtraSurvives() {
        XCTAssertEqual(QuotaCardProjection.selectedIndices(in: [row("unknown", "grok", "7d", nil)], now: now), [])
        var extra = row("extra", "muse-assist", nil, nil, label: "Additional tokens")
        extra.absoluteRemaining = 42
        let weekly = row("weekly", "muse-assist", "7d", 47)
        XCTAssertEqual(QuotaCardProjection.selectedIndices(in: [extra, weekly], now: now), [1, 0])
        XCTAssertNotEqual(extra.allowanceKey, weekly.allowanceKey)
        extra.absoluteRemaining = .nan
        XCTAssertFalse(extra.hasReading)
    }

    func testCanonicalAntigravityPoolRowsDriveBothPeriodsAndArgonStaysSeparate() {
        let rows = [row("raw:gemini:5h", "google-antigravity", "5h", 7),
                    row("antigravity:gemini:5h", "google-antigravity", "5h", 63, age: 10),
                    row("antigravity:gemini:weekly", "google-antigravity", "7d", 1),
                    row("argon", "google-antigravity", "5h", 0, model: "Argon")]
        XCTAssertEqual(QuotaCardProjection.selectedPoolIndices(in: rows, poolKey: "gemini", now: now), [1, 2])
        XCTAssertEqual(rows[3].displayLabel, "Argon limit")
        XCTAssertEqual(rows[3].detailName, "Argon")
        XCTAssertEqual(rows[0].detailName, nil)
        XCTAssertEqual([rows[1], rows[2]].compactMap(\.remainingPercent).min(), 1)
    }

    func testEqualTimePoolObservationsUseLowerReadingWithoutAveraging() {
        let rows = [row("a", "google-antigravity", "7d", 63), row("b", "google-antigravity", "7d", 7)]
        XCTAssertEqual(QuotaCardProjection.selectedPoolIndices(in: rows, poolKey: "gemini", now: now), [1])
    }

    /// Main's reviewed headline rule (PR #376): a Muse Assist extra meter
    /// with headroom headlines the card; the plan's spent window does not
    /// out-shout it.
    func testMuseAssistExtraHeadlinesWhileItHasRoom() {
        let weekly = CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, remainingPercent: 47)
        let extra = CardHeadline.Reading(isMuseAssistExtra: true, isMasked: false, remainingPercent: 81)
        XCTAssertEqual(CardHeadline.percent([weekly, extra]), 81)
        XCTAssertEqual(CardHeadline.percent([.init(isMuseAssistExtra: false, isMasked: false, remainingPercent: 0), extra]), 81)
    }

    func testExpiredCanonicalPoolCannotReplaceCurrentObservation() {
        let rows = [row("antigravity:gemini:weekly", "google-antigravity", "7d", 0, age: 100, reset: -1),
                    row("raw", "google-antigravity", "7d", 51)]
        XCTAssertEqual(QuotaCardProjection.selectedPoolIndices(in: rows, poolKey: "gemini", now: now), [1])
    }
}
