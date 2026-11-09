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

    func testJsonShapedMetadataIdIsNotAQuotaReading() {
        // Producer-scoped window ids are serialized JSON, so a metadata id
        // ends in `"]`, not in the bare ":plan-metadata" token (qa3 wire
        // fixture): match the marker anywhere in the id (Kody, PR #388).
        let jsonId = "[\"producer\",\"4f938669-72f9-4386-8808-6408a031ab4d\",\"minimax:plan-metadata\"]"
        let metadata = row(jsonId, "minimax", nil, 100, label: "Usage notes")
        XCTAssertFalse(metadata.isQuota)
        let quota = row("short", "minimax", "5h", 92)
        let rows = [metadata, quota]
        XCTAssertEqual(QuotaCardProjection.selectedIndices(in: rows, now: now).map { rows[$0].id }, ["short"])
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

    /// The merged headline rule (#374):  a Muse Assist extra meter with room
    /// headlines the card,  and it also stands in when the plan itself reads
    /// spent.  The weekly leads only when no extra reading exists.
    func testAMuseExtraWithRoomHeadlinesTheCard() {
        let weekly = CardHeadline.Reading(isMuseAssistExtra: false, isMasked: false, remainingPercent: 47)
        let extra = CardHeadline.Reading(isMuseAssistExtra: true, isMasked: false, remainingPercent: 81)
        XCTAssertEqual(CardHeadline.percent([weekly, extra]), 81)
        XCTAssertEqual(CardHeadline.percent([.init(isMuseAssistExtra: false, isMasked: false, remainingPercent: 0), extra]), 81)
        XCTAssertEqual(CardHeadline.percent([weekly]), 47)
    }

    func testExpiredCanonicalPoolCannotReplaceCurrentObservation() {
        let rows = [row("antigravity:gemini:weekly", "google-antigravity", "7d", 0, age: 100, reset: -1),
                    row("raw", "google-antigravity", "7d", 51)]
        XCTAssertEqual(QuotaCardProjection.selectedPoolIndices(in: rows, poolKey: "gemini", now: now), [1])
    }

    /// The bare-cadence fallback in `allowanceKey` carries the provider, so
    /// two providers' identical cadences never collapse into one grouping
    /// bucket (Kody review, PR #367).
    func testBareCadenceAllowanceKeyIsProviderPrefixed() {
        let grok = row("grok-weekly", "grok-bot", "7d", 50)
        let cursor = row("cursor-weekly", "cursor", "7d", 90)
        XCTAssertNotEqual(grok.allowanceKey, cursor.allowanceKey,
                          "two providers' weekly windows must not share an allowance key")
        XCTAssertTrue(grok.allowanceKey.hasPrefix("grok-bot:"))
        // Within one provider the primary rows still group together.
        XCTAssertEqual(grok.allowanceKey,
                       row("grok-weekly-copy", "grok-bot", "7d", 51).allowanceKey)
    }

    /// Model classification is by exact token: a model id that merely
    /// contains the word is not the Fable limit (Kody review, PR #367).
    func testFableDetectionIsExactTokenNotSubstring() {
        XCTAssertNotNil(row("claude:fable", "anthropic", "7d", 0, model: "Fable").detailName)
        XCTAssertNil(row("claude:fable-era", "anthropic", "7d", 0, model: "Fable-era").detailName,
                      "fable-era is its own model, not the Fable limit")
        XCTAssertNil(row("claude:fabled", "anthropic", "7d", 0, model: "Fabled").detailName)
        XCTAssertNil(row("antigravity:argonaut", "google-antigravity", "5h", 0, model: "Argonaut").detailName,
                      "Argonaut is not the Argon limit")
        XCTAssertNotNil(row("gemini:argon", "google-antigravity", "5h", 0, model: "Argon").detailName)
    }
}
