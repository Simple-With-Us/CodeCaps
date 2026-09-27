import XCTest
@testable import QuotaCore

/// The canonical shared-pool rule both platforms now obey, exercised with the
/// per-model rows a real Antigravity payload actually contains.
///
/// Owner report 2026-09-27: tapping an Antigravity card on the iOS companion
/// listed "Gemini 3.5 Flash (Medium)", "Claude Opus 4.6 (Thinking)",
/// "GPT-OSS 120B (Medium)" and so on.  Those are not quota periods, they are
/// observations of two shared pools, each of which has exactly one short cap and
/// one weekly cap.  `AntigravityQuotaGroups` has always said so — "Per-model
/// reports are observations of those pools, never additive quotas" — and the
/// Mac obeys it, which is why the two platforms disagreed.
///
/// These tests pin that contract against real structures rather than against the
/// companion's source text, so the rule itself is what is verified.
final class AntigravitySharedPoolTests: XCTestCase {
    private let now = Date()

    /// One per-model observation, shaped like the rows in the payload.
    private func perModel(
        id: String,
        label: String,
        modelId: String,
        percent: Double,
        window: String? = nil,
        resetHours: Double = 4
    ) -> QuotaWindow {
        QuotaWindow(
            id: id,
            provider: "Antigravity",
            providerKey: "google-antigravity",
            modelId: modelId,
            label: label,
            remainingPercent: percent,
            resetAt: ISO8601DateFormatter().string(
                from: now.addingTimeInterval(resetHours * 3600)),
            window: window,
            occurredAt: ISO8601DateFormatter().string(from: now)
        )
    }

    /// The shape the companion actually received: per-model rows for both pools,
    /// including entries that name a model but no period at all.
    private var thirdPartyPayload: [QuotaWindow] {
        [
            perModel(id: "ag:tp:opus", label: "Claude Opus 4.6 (Thinking)",
                     modelId: "claude-opus-4-6", percent: 100, resetHours: 3.8),
            perModel(id: "ag:tp:sonnet", label: "Claude Sonnet 4.6 (Thinking)",
                     modelId: "claude-sonnet-4-6", percent: 100, resetHours: 3.8),
            perModel(id: "ag:tp:gpt-oss", label: "GPT-OSS 120B (Medium)",
                     modelId: "gpt-oss-120b", percent: 100, window: "5h", resetHours: 3.8),
            perModel(id: "ag:tp:5h", label: "Claude and GPT models (5h)",
                     modelId: "claude-gpt-pool", percent: 100, window: "5h", resetHours: 4.48),
            perModel(id: "ag:tp:weekly", label: "Claude and GPT models (weekly)",
                     modelId: "claude-gpt-pool", percent: 100, window: "weekly", resetHours: 167)
        ]
    }

    private var geminiPayload: [QuotaWindow] {
        [
            perModel(id: "ag:gem:flash-med", label: "Gemini 3.5 Flash (Medium)",
                     modelId: "gemini-3-5-flash", percent: 84, window: "5h", resetHours: 0.9),
            perModel(id: "ag:gem:flash-low", label: "Gemini 3.5 Flash (Low)",
                     modelId: "gemini-3-5-flash", percent: 84, window: "5h", resetHours: 0.9),
            perModel(id: "ag:gem:pro-high", label: "Gemini 3.1 Pro (High)",
                     modelId: "gemini-3-1-pro", percent: 84, window: "5h", resetHours: 0.9),
            perModel(id: "ag:gem:3flash", label: "Gemini 3 Flash",
                     modelId: "gemini-3-flash", percent: 84, window: "5h", resetHours: 0.9)
        ]
    }

    /// A pool has exactly two periods, whatever the payload looks like.  This is
    /// the number of rows the companion now shows per Antigravity card.
    func testAPoolNormalisesToExactlyTwoPeriods() {
        let normalized = AntigravityQuotaGroups.normalize(thirdPartyPayload)
        let ids = normalized.map(\.id).sorted()
        XCTAssertEqual(ids, ["antigravity:third-party:5h", "antigravity:third-party:weekly"],
                       "a pool is a short cap and a weekly cap, nothing else")
    }

    func testPerModelRowsNeverSurviveAsTheirOwnWindows() {
        let normalized = AntigravityQuotaGroups.normalize(thirdPartyPayload)
        for id in normalized.map(\.id) {
            XCTAssertFalse(id.contains("opus"), "a per-model window must not survive normalisation")
            XCTAssertFalse(id.contains("sonnet"), "a per-model window must not survive normalisation")
            XCTAssertFalse(id.contains("gpt-oss"), "a per-model window must not survive normalisation")
        }
    }

    /// Model-named rows are the ones that caused the report, including a Gemini
    /// payload where every row names a model *and* claims a 5h window.
    ///
    /// This payload has no weekly observation at all, so the pool legitimately
    /// publishes only the period it can actually speak for — a period is never
    /// invented from thin air.
    func testGeminiPoolCollapsesToOneRowWhenOnlyOnePeriodIsObserved() {
        let normalized = AntigravityQuotaGroups.normalize(geminiPayload)
        let ids = normalized.map(\.id).sorted()
        XCTAssertEqual(ids, ["antigravity:gemini:5h"],
                       "only an observed period is published; four per-model rows became one")
        XCTAssertLessThanOrEqual(ids.count, 2, "a pool can never exceed its two periods")
    }

    /// Observations of one shared pool are never summed: five models at 84% is
    /// still 84%.
    func testPoolPercentageIsNotSummedOrAveraged() {
        let normalized = AntigravityQuotaGroups.normalize(geminiPayload)
        let fiveHour = normalized.first { $0.id == "antigravity:gemini:5h" }
        XCTAssertEqual(fiveHour?.remainingPercent, 84,
                       "one shared allowance reads the same however many models observe it")
    }

    /// A model reporting a lower value of the same shared pool wins, so the row
    /// never overstates what is left.
    func testLowestObservationOfASharedPoolWinsOnATie() {
        var payload = geminiPayload
        payload.append(
            perModel(id: "ag:gem:pro-low", label: "Gemini 3.1 Pro (Low)",
                     modelId: "gemini-3-1-pro", percent: 40, window: "5h", resetHours: 0.9)
        )
        let normalized = AntigravityQuotaGroups.normalize(payload)
        let fiveHour = normalized.first { $0.id == "antigravity:gemini:5h" }
        XCTAssertEqual(fiveHour?.remainingPercent, 40,
                       "the lowest reading of a shared pool is the honest one")
    }

    /// Both pools are independent: an exhausted Claude/GPT weekly cap must not
    /// make Gemini read as exhausted, which is why the platforms are two cards.
    func testTheTwoPoolsStayIndependent() {
        var payload = thirdPartyPayload
        payload[4].remainingPercent = 0
        payload[4].isExhausted = true
        let pools = AntigravityQuotaGroups.pools(from: payload, now: now)
        XCTAssertEqual(pools.map(\.key), ["third-party"])

        let exhaustedPool = pools.first { $0.key == "third-party" }
        XCTAssertTrue(exhaustedPool?.weeklyExhausted ?? false)
        // The short cap cannot mean anything while the weekly cap is spent.
        XCTAssertFalse((exhaustedPool?.maskedWindowIds ?? []).isEmpty,
                       "the 5h window must be masked under an exhausted weekly cap")

        let withGemini = AntigravityQuotaGroups.pools(from: payload + geminiPayload, now: now)
        let gemini = withGemini.first { $0.key == "gemini" }
        XCTAssertEqual(gemini?.weeklyExhausted, false,
                       "an exhausted Claude/GPT weekly cap must not mask Gemini")
    }

    /// Only the two periods may ever be published, and each carries the pool as
    /// its model type so a consumer can route on the family.
    func testPublishedPeriodsCarryThePoolAsTheirModelType() {
        let normalized = AntigravityQuotaGroups.normalize(thirdPartyPayload)
        for window in normalized {
            XCTAssertEqual(window.modelType, "third-party")
            XCTAssertEqual(window.modelId, nil, "no single model survives the pooling")
            XCTAssertEqual(window.window, window.id.hasSuffix("5h") ? "5h" : "weekly")
        }
    }
}
