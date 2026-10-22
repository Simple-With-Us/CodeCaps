import XCTest
@testable import QuotaCore

/// The one rule for "may this window stand in for a plan hitting its cap",
/// shared by the Mac's menu-bar window, its picture in picture and the phone
/// companion.
///
/// Owner 2026-10-21: the phone showed no message for Codex or Antigravity
/// being at its cap, and while fixing that the two surfaces were found to
/// answer the same question differently, so the rule moved here where both
/// surfaces call it.
final class QuotaCapRuleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func facts(
        id: String,
        percent: Double?,
        resetsIn: TimeInterval? = 3600,
        isMasked: Bool = false,
        isSupplementaryVideoQuota: Bool = false,
        isScopedPoolAllowance: Bool = false,
        isSubModelLimit: Bool = false
    ) -> QuotaCapRule.WindowFacts {
        QuotaCapRule.WindowFacts(
            id: id,
            remainingPercent: percent,
            resetAt: resetsIn.map { now.addingTimeInterval($0) },
            isMasked: isMasked,
            isSupplementaryVideoQuota: isSupplementaryVideoQuota,
            isScopedPoolAllowance: isScopedPoolAllowance,
            isSubModelLimit: isSubModelLimit
        )
    }

    // MARK: - The reading decides

    func testAReadingOfZeroIsTheCap() {
        XCTAssertTrue(QuotaCapRule.isAtCap(remainingPercent: 0))
    }

    func testAReadingWithHeadroomIsNotTheCap() {
        XCTAssertFalse(QuotaCapRule.isAtCap(remainingPercent: 50))
        XCTAssertFalse(QuotaCapRule.isAtCap(remainingPercent: 0.6))
    }

    /// A reading is rounded to the nearest whole percent on screen, so 0.4% is
    /// drawn as 0%.  The rule has to agree with what is drawn, or the owner is
    /// told a plan is not capped while its meter reads 0%.
    ///
    /// This is the drift the reviewer found:  the Antigravity pool's weekly
    /// test counted 0.4% as spent while this rule called it headroom, so the
    /// same pool was capped on one surface and not on the other, and the
    /// at-cap summary line went missing beside the weekly.
    func testAReadingAtTheRoundingThresholdIsTheCap() {
        XCTAssertTrue(QuotaCapRule.isAtCap(remainingPercent: 0.4))
        XCTAssertTrue(QuotaCapRule.isAtCap(remainingPercent: 0))
    }

    /// One number, so no surface can drift from another.
    ///
    /// The Antigravity grouper and this rule used to carry the threshold
    /// separately, one of them at 0.5 and the other at 0, and the owner saw
    /// two different answers about one account.
    func testEverySurfaceReadsTheSameSpentThreshold() {
        XCTAssertEqual(
            AntigravityQuotaGroups.weeklySpentThreshold,
            QuotaCapRule.spentThreshold,
            "the Antigravity pool and the shared cap rule must use one threshold"
        )
    }

    func testNoReadingIsNotTheCap() {
        XCTAssertFalse(QuotaCapRule.isAtCap(remainingPercent: nil))
    }

    func testANonFiniteReadingIsNotTheCap() {
        XCTAssertFalse(QuotaCapRule.isAtCap(remainingPercent: .nan))
        XCTAssertFalse(QuotaCapRule.isAtCap(remainingPercent: .infinity))
    }

    func testAReadingIsBoundedBeforeItIsJudged() {
        XCTAssertEqual(QuotaCapRule.bounded(-5), 0)
        XCTAssertEqual(QuotaCapRule.bounded(500), 100)
        XCTAssertNil(QuotaCapRule.bounded(nil))
        XCTAssertNil(QuotaCapRule.bounded(.nan))
    }

    // MARK: - The binding window

    func testTheSpentWindowBinds() {
        let binding = QuotaCapRule.bindingWindow(in: [facts(id: "weekly", percent: 0)])
        XCTAssertEqual(binding?.id, "weekly")
    }

    /// The Mac's rule:  a reading decides whenever there is one, even when the
    /// window still carries an exhausted flag, which the export never clears.
    /// The phone used to let the flag win, and could announce a cap directly
    /// above a meter that read 50%.
    func testTheProvidersExhaustedWordCannotOverrideAReading() {
        let binding = QuotaCapRule.bindingWindow(in: [facts(id: "weekly", percent: 50)])
        XCTAssertNil(binding, "a window with room left must not be reported as capped")
    }

    func testAWindowWithNoReadingNeverBinds() {
        let binding = QuotaCapRule.bindingWindow(in: [facts(id: "weekly", percent: nil)])
        XCTAssertNil(binding, "a window with no reading reports no cap at all")
    }

    func testAmongSpentWindowsTheOneThatResetsLastBinds() {
        let binding = QuotaCapRule.bindingWindow(in: [
            facts(id: "five-hour", percent: 0, resetsIn: 3600),
            facts(id: "weekly", percent: 0, resetsIn: 86_400)
        ])
        XCTAssertEqual(binding?.id, "weekly", "the plan stays capped until the last window recovers")
    }

    func testAMaskedWindowNeverBinds() {
        let binding = QuotaCapRule.bindingWindow(in: [facts(id: "five-hour", percent: 0, isMasked: true)])
        XCTAssertNil(binding, "a masked reading is a number that must not be believed")
    }

    func testAScopedPoolAllowanceNeverBinds() {
        let binding = QuotaCapRule.bindingWindow(in: [
            facts(id: "additional:pool", percent: 0, isScopedPoolAllowance: true)
        ])
        XCTAssertNil(binding, "an allowance beside the subscription is not the subscription hitting its cap")
    }

    func testASupplementaryVideoAllowanceNeverBinds() {
        let binding = QuotaCapRule.bindingWindow(in: [
            facts(id: "video", percent: 0, isSupplementaryVideoQuota: true)
        ])
        XCTAssertNil(binding)
    }

    func testAPrimaryWindowBeatsASubModelWindow() {
        let binding = QuotaCapRule.bindingWindow(in: [
            facts(id: "primary", percent: 50),
            facts(id: "sub-model", percent: 0, isSubModelLimit: true)
        ])
        XCTAssertNil(binding, "the plan is capped by the window it is sold on, not by a sub-model of it")
    }

    func testAPlanOfOnlySubModelWindowsIsStillCapped() {
        let binding = QuotaCapRule.bindingWindow(in: [
            facts(id: "sub-model", percent: 0, isSubModelLimit: true)
        ])
        XCTAssertEqual(binding?.id, "sub-model", "a plan whose windows are all sub-model windows is capped by them")
    }

    // MARK: - The window kinds the rule skips

    func testMiniMaxVideoAllowanceIsSupplementary() {
        XCTAssertTrue(
            QuotaCapRule.isSupplementaryVideoQuota(providerKey: "minimax", modelId: "video", label: "Video")
        )
        XCTAssertTrue(
            QuotaCapRule.isSupplementaryVideoQuota(providerKey: "minimax", label: "Hailuo allowance")
        )
        XCTAssertFalse(
            QuotaCapRule.isSupplementaryVideoQuota(providerKey: "minimax", label: "5-hour window")
        )
        XCTAssertFalse(
            QuotaCapRule.isSupplementaryVideoQuota(providerKey: "openai", label: "Video")
        )
    }

    func testCodexCodeReviewAndAdditionalPoolsAreScopedAllowances() {
        XCTAssertTrue(QuotaCapRule.isScopedPoolAllowance(providerKey: "openai", id: "code-review"))
        XCTAssertTrue(QuotaCapRule.isScopedPoolAllowance(providerKey: "openai", id: "openai:additional:pool"))
        XCTAssertTrue(QuotaCapRule.isScopedPoolAllowance(providerKey: "openai", id: "local-mac:openai:code-review:x"))
        XCTAssertFalse(QuotaCapRule.isScopedPoolAllowance(providerKey: "openai", id: "openai:primary"))
        XCTAssertFalse(
            QuotaCapRule.isScopedPoolAllowance(providerKey: "anthropic", id: "code-review"),
            "a Claude sub-model quota still caps its plan, so it is not a scoped allowance"
        )
    }

    func testAnArgonWindowIsASubModelLimit() {
        XCTAssertTrue(
            QuotaCapRule.isSubModelLimit(providerKey: "google-antigravity", id: "gemini", modelId: "argon", label: "Gemini")
        )
        XCTAssertTrue(
            QuotaCapRule.isSubModelLimit(providerKey: "google-antigravity", id: "gemini", label: "Gemini 4 Argon")
        )
        XCTAssertFalse(
            QuotaCapRule.isSubModelLimit(providerKey: "google-antigravity", id: "gemini", label: "Gemini Models")
        )
    }

    func testAnAnthropicModelWindowIsASubModelLimit() {
        XCTAssertTrue(
            QuotaCapRule.isSubModelLimit(providerKey: "anthropic", id: "claude", modelId: "claude-sonnet-5", label: "Claude")
        )
        XCTAssertTrue(
            QuotaCapRule.isSubModelLimit(providerKey: "anthropic", id: "claude", label: "Claude Opus 4.6")
        )
        XCTAssertFalse(
            QuotaCapRule.isSubModelLimit(providerKey: "anthropic", id: "claude", label: "5-hour window")
        )
    }

    // MARK: - The Mac and the shared rule answer the same way

    /// The drift guard.
    ///
    /// The Mac's `QuotaPlatformSection.atCapWindow()` and the phone's
    /// `CompanionQuotaItem.atCapWindow()` used to be two implementations of
    /// one question and they disagreed:  the phone let a provider's exhausted
    /// word override a reading that said there was room left, so it could
    /// announce a cap directly above a meter that read 50%.  Both now call
    /// this rule.
    ///
    /// This test says the Mac's answer and the rule's answer are the same
    /// answer.  The facts are taken from the windows through the shared
    /// predicates, which is where the window kinds come from on both
    /// surfaces, so a future edit that drops one of them from the Mac's
    /// mapping shows up here as a disagreement.
    ///
    /// The phone's model is not compiled into the macOS test target, so its
    /// half of the contract is pinned by `CompanionModelTests`, which checks
    /// that the phone calls `QuotaCapRule.bindingWindow` rather than keeping a
    /// copy of the rule.
    func testTheMacAndTheSharedRulePickTheSameWindow() {
        let cases: [(name: String, windows: [QuotaWindowSnapshot])] = [
            ("one spent window", [snapshot(id: "weekly", remaining: 0, resetIn: 86_400)]),
            ("one window with room", [snapshot(id: "weekly", remaining: 50, resetIn: 86_400)]),
            ("a reading that rounds to zero", [snapshot(id: "weekly", remaining: 0.4, resetIn: 86_400)]),
            ("one window with no reading", [snapshot(id: "weekly", remaining: nil, resetIn: 86_400)]),
            (
                "two spent windows",
                [
                    snapshot(id: "five-hour", remaining: 0, resetIn: 3_600),
                    snapshot(id: "weekly", remaining: 0, resetIn: 86_400)
                ]
            ),
            (
                "a spent window and one with room",
                [
                    snapshot(id: "five-hour", remaining: 0, resetIn: 3_600),
                    snapshot(id: "weekly", remaining: 80, resetIn: 86_400)
                ]
            ),
            (
                "a spent window with a stale exhausted flag",
                [snapshot(id: "weekly", remaining: 100, resetIn: 86_400, exhausted: true)]
            ),
            (
                "a window with room and a spent sub-model window",
                [
                    snapshot(id: "primary", remaining: 50, resetIn: 3_600, provider: "anthropic"),
                    snapshot(
                        id: "claude-opus-4-6",
                        remaining: 0,
                        resetIn: 3_600,
                        provider: "anthropic",
                        model: "claude-opus-4-6"
                    )
                ]
            ),
            (
                "a plan of only sub-model windows",
                [snapshot(id: "claude-opus-4-6", remaining: 0, resetIn: 3_600, provider: "anthropic", model: "claude-opus-4-6")]
            ),
            (
                "a spent code review pool beside a window with room",
                [
                    snapshot(id: "primary", remaining: 80, resetIn: 3_600, provider: "openai"),
                    snapshot(id: "openai:code-review", remaining: 0, resetIn: 3_600, provider: "openai")
                ]
            )
        ]

        for testCase in cases {
            let section = QuotaPlatformSection(
                providerKey: "anthropic",
                providerLabel: "Claude",
                via: nil,
                expected: true,
                windows: testCase.windows
            )
            let macAnswer = section.atCapWindow()?.window.id

            let ruleFacts = testCase.windows.map {
                QuotaCapRule.WindowFacts(
                    id: $0.window.id,
                    remainingPercent: $0.remainingPercent,
                    resetAt: $0.resetAt,
                    isSupplementaryVideoQuota: $0.window.isSupplementaryVideoQuota,
                    isScopedPoolAllowance: $0.window.isScopedPoolAllowance,
                    isSubModelLimit: $0.window.isSubModelLimit
                )
            }
            let ruleAnswer = QuotaCapRule.bindingWindow(in: ruleFacts)?.id

            XCTAssertEqual(
                macAnswer,
                ruleAnswer,
                "the Mac and the shared rule disagree for \(testCase.name)"
            )
        }
    }

    // MARK: - The binding window is found by position

    /// A duplicate id must not make the cap line name the wrong window.
    ///
    /// One list can carry two snapshots of the same window id, the same window
    /// reported by two sources.  The rule picks the one that resets last, and
    /// the caller used to re-find the window by id afterwards, which returned
    /// the first snapshot carrying that id instead, so the countdown named the
    /// wrong window (Kody review 2026-10-21).
    func testADuplicateIdStillBindsTheWindowThatResetsLast() throws {
        let windows = [
            snapshot(id: "weekly", remaining: 0, resetIn: 3_600),
            snapshot(id: "weekly", remaining: 0, resetIn: 86_400)
        ]
        let facts = windows.map {
            QuotaCapRule.WindowFacts(
                id: $0.window.id,
                remainingPercent: $0.remainingPercent,
                resetAt: $0.resetAt,
                isSupplementaryVideoQuota: $0.window.isSupplementaryVideoQuota,
                isScopedPoolAllowance: $0.window.isScopedPoolAllowance,
                isSubModelLimit: $0.window.isSubModelLimit
            )
        }

        XCTAssertEqual(
            QuotaCapRule.bindingWindowIndex(in: facts),
            1,
            "the rule must bind the spent window that resets last"
        )
        XCTAssertEqual(
            QuotaCapRule.bindingWindow(in: facts)?.resetAt,
            facts[1].resetAt,
            "the rule's answer must be the window it bound, not the first one with that id"
        )

        let section = QuotaPlatformSection(
            providerKey: "anthropic",
            providerLabel: "Claude",
            via: nil,
            expected: true,
            windows: windows
        )
        XCTAssertEqual(
            section.atCapWindow()?.resetAt,
            windows[1].resetAt,
            "the Mac must name the window the rule bound, not the first snapshot with that id"
        )
    }

    // MARK: - A cadence is a token, never prose

    /// The at-cap line used to re-derive the cadence from its text with a
    /// substring matcher, so a value such as "notweekly" was read as a weekly
    /// window (Kody rule 40, binding 2026-10-21).  A cadence names its period
    /// through whole tokens, exactly as the widget's own grouping rule does.
    func testACadenceNamesItsPeriodThroughWholeTokensOnly() {
        XCTAssertEqual(QuotaWindowVocabulary.atCapCadence(cadence: "7-day"), "7-day")
        XCTAssertEqual(QuotaWindowVocabulary.atCapCadence(cadence: "5-hour"), "5-hour")
        XCTAssertEqual(QuotaWindowVocabulary.atCapCadence(cadence: "weekly"), "7-day")
        XCTAssertEqual(QuotaWindowVocabulary.atCapCadence(cadence: "notweekly"), "Other limit")
        XCTAssertEqual(QuotaWindowVocabulary.atCapCadence(cadence: "notdaily"), "Other limit")
        XCTAssertEqual(QuotaWindowVocabulary.atCapCadence(cadence: "notamonth"), "Other limit")
    }

    private func snapshot(
        id: String,
        remaining: Double?,
        resetIn: TimeInterval,
        provider: String = "anthropic",
        model: String? = nil,
        exhausted: Bool = false
    ) -> QuotaWindowSnapshot {
        let iso = ISO8601DateFormatter()
        return QuotaWindowSnapshot(
            window: QuotaWindow(
                id: id,
                provider: provider,
                providerKey: provider,
                providerLabel: provider,
                modelId: model,
                label: "Window",
                remainingPercent: remaining,
                remainingUnknown: remaining == nil,
                isExhausted: exhausted,
                resetAt: iso.string(from: now.addingTimeInterval(resetIn)),
                window: nil,
                occurredAt: iso.string(from: now)
            ),
            now: now
        )
    }
}
