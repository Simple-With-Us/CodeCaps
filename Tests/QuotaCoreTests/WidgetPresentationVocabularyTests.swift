import XCTest
@testable import QuotaCore

/// WidgetPresentation lives in the iOS target; these tests pin the shared
/// vocabulary helpers the widget parser calls through QuotaWindowVocabulary.
final class WidgetPresentationVocabularyTests: XCTestCase {
    func testFormatCadenceUsesHyphenatedLabels() {
        XCTAssertEqual(
            QuotaWindowVocabulary.standardCadence(windowToken: "7d", label: "weekly cap"),
            "7-day"
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.standardCadence(windowToken: "1m", label: "billing"),
            "1-month"
        )
    }

    func testPopoverCaptionMatchesMenuBarUnits() {
        XCTAssertEqual(
            QuotaWindowVocabulary.popoverCaption(windowToken: "7d", label: "7-day window"),
            "7d"
        )
    }

    /// Owner 2026-10-21 saw "7d 7-day" duplicate in the Mac widget caption row
    /// for the Antigravity weekly allowance.  The cadence token sits on the
    /// same line as the qualifier, so the qualifier must NEVER repeat the
    /// cadence form ("7-day" / "5-hour" / "1-month").  Short nouns ("weekly",
    /// "monthly", "additional") are the only forms the caption supports.
    ///
    /// Kody review 2026-10-21: the forbidden list named "7-day", "5-hour",
    /// "1-month" and "Other limit" but left the daily cadence and the compact
    /// tokens ("1d", "7d", "5h", "1m", "+") unguarded, so the stated invariant
    /// was not actually enforced.  The list below is the shared one the
    /// vocabulary ships.
    func testBarQualifierConstantsAreShortNounsNotCadenceForms() {
        XCTAssertEqual(QuotaWindowVocabulary.barQualifierWeekly, "weekly")
        XCTAssertEqual(QuotaWindowVocabulary.barQualifierMonthly, "monthly")
        XCTAssertEqual(QuotaWindowVocabulary.barQualifierDaily, "daily allowance")
        XCTAssertEqual(QuotaWindowVocabulary.barQualifierHourly, "hourly")
        XCTAssertEqual(QuotaWindowVocabulary.barQualifierAdditional, "additional")

        for constant in [
            QuotaWindowVocabulary.barQualifierWeekly,
            QuotaWindowVocabulary.barQualifierMonthly,
            QuotaWindowVocabulary.barQualifierDaily,
            QuotaWindowVocabulary.barQualifierHourly,
            QuotaWindowVocabulary.barQualifierAdditional
        ] {
            for forbiddenCadenceForm in QuotaWindowVocabulary.barQualifierForbiddenCadenceForms {
                XCTAssertNotEqual(constant, forbiddenCadenceForm,
                    "qualifier '\(constant)' must not repeat the cadence form '\(forbiddenCadenceForm)'.")
            }
        }

        XCTAssertTrue(QuotaWindowVocabulary.barQualifierForbiddenCadenceForms.contains(QuotaWindowVocabulary.oneDay),
            "the daily cadence form must stay on the forbidden list.")
        for compactToken in ["5h", "1d", "7d", "1m", "+"] {
            XCTAssertTrue(QuotaWindowVocabulary.barQualifierForbiddenCadenceForms.contains(compactToken),
                "the compact cadence token '\(compactToken)' must stay on the forbidden list.")
        }
    }

    /// Kody review 2026-10-21: the daily qualifier restated the cadence the
    /// caption token already showed, so a daily window read "1d daily".  The
    /// qualifier names the kind of allowance instead.
    func testDailyQualifierDoesNotRestateTheCadenceToken() {
        // The production label for a daily window is "1-day window":  the
        // widget's label pipeline rewrites the prose away.
        let qualifier = QuotaWindowVocabulary.barQualifier(
            forCadence: QuotaWindowVocabulary.oneDay,
            label: "1-day window",
            sharesCadence: true
        )
        XCTAssertEqual(qualifier, "daily allowance")
        XCTAssertNotEqual(qualifier, "daily")

        let token = QuotaWindowVocabulary.popoverCaption(windowToken: "1-day", label: "1-day window")
        XCTAssertEqual(token, "1d")
        let caption = "\(token) \(qualifier)"
        XCTAssertEqual(caption, "1d daily allowance")
        XCTAssertNotEqual(caption, "1d daily")
    }

    /// Kody review 2026-10-21: the qualifier is named from the canonical
    /// cadence the caption row prints, not from prose words in the label.
    ///
    /// The widget builds every window label through
    /// `QuotaWindowVocabulary.windowLabel(...)`, which rewrites the label into
    /// the hyphenated cadence copy ("7-day window"), so a matcher that looks
    /// for "weekly" in the label never matched a label the widget renders and
    /// the owner-approved "weekly" / "additional" pair never appeared.
    func testBarQualifierIsNamedFromTheCadenceNotTheLabel() {
        XCTAssertEqual(
            QuotaWindowVocabulary.barQualifier(
                forCadence: QuotaWindowVocabulary.sevenDay,
                label: "7-day window",
                sharesCadence: true
            ),
            QuotaWindowVocabulary.barQualifierWeekly
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barQualifier(
                forCadence: QuotaWindowVocabulary.oneMonth,
                label: "1-month window",
                sharesCadence: true
            ),
            QuotaWindowVocabulary.barQualifierMonthly
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barQualifier(
                forCadence: QuotaWindowVocabulary.fiveHour,
                label: "5-hour window",
                sharesCadence: true
            ),
            QuotaWindowVocabulary.barQualifierHourly
        )
        // A label that still carries prose cannot rename the cadence the row
        // already prints.
        XCTAssertEqual(
            QuotaWindowVocabulary.barQualifier(
                forCadence: QuotaWindowVocabulary.sevenDay,
                label: "Free weekly limit",
                sharesCadence: true
            ),
            QuotaWindowVocabulary.barQualifierWeekly
        )
        // A lone bar needs none.
        XCTAssertEqual(
            QuotaWindowVocabulary.barQualifier(
                forCadence: QuotaWindowVocabulary.sevenDay,
                label: "7-day window",
                sharesCadence: false
            ),
            ""
        )
        // The extra allowance is the one case the label still names.
        XCTAssertEqual(
            QuotaWindowVocabulary.barQualifier(
                forCadence: QuotaWindowVocabulary.sevenDay,
                label: "Additional allowance",
                sharesCadence: true
            ),
            QuotaWindowVocabulary.barQualifierAdditional
        )
    }

    /// Kody rule "Avoid Substring Matching for Canonical Limit/Window Labels"
    /// (binding, 2026-10-21): the prose fallback in the cadence group reads
    /// whole lexical tokens, so "nothourly" is not an hourly window.
    func testBarCadenceGroupFallbackMatchesExactTokensNotSubstrings() {
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "", label: "nothourly"),
            QuotaWindowVocabulary.otherLimit
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "", label: "unhourlyplan"),
            QuotaWindowVocabulary.otherLimit
        )
    }

    /// The canonical labels the vocabulary produces must resolve back to
    /// themselves when they are handed to the cadence lookup as a token.
    ///
    /// The widget passes a window's canonical cadence back through
    /// `standardCadence(windowToken:label:)`, and an extra allowance is looked
    /// up with an empty label, so a canonical label that did not resolve would
    /// collapse that row to "Other limit" and lose the period it doubles.
    func testCanonicalCadenceLabelsRoundTripThroughTheToken() {
        for canonical in [
            QuotaWindowVocabulary.fiveHour,
            QuotaWindowVocabulary.oneDay,
            QuotaWindowVocabulary.sevenDay,
            QuotaWindowVocabulary.oneMonth
        ] {
            XCTAssertEqual(
                QuotaWindowVocabulary.standardCadence(windowToken: canonical, label: ""),
                canonical,
                "the canonical label '\(canonical)' must resolve back to itself."
            )
        }
    }

    /// Kody review 2026-10-21: a lone bar printing a cadence word says the
    /// same thing twice, so the qualifier is only printed when a sibling bar
    /// shares the cadence.
    func testLoneCadenceBarPrintsNoQualifierAndSharedCadenceDoes() {
        let lone = QuotaWindowVocabulary.barQualifiers(forBars: [
            QuotaWindowVocabulary.BarCaption(cadence: "Weekly", label: "Weekly cap")
        ])
        XCTAssertEqual(lone, [""])

        // The Antigravity weekly bar sits beside a 5-hour bar, a different
        // cadence, so neither bar needs a qualifier.
        let mixedCadences = QuotaWindowVocabulary.barQualifiers(forBars: [
            QuotaWindowVocabulary.BarCaption(cadence: "5h", label: "5-hour window"),
            QuotaWindowVocabulary.BarCaption(cadence: "Weekly", label: "Weekly cap")
        ])
        XCTAssertEqual(mixedCadences, ["", ""])

        // Two 7-day bars share one cadence, so they read "weekly" and
        // "additional" (owner-approved, 2026-10-21).
        let sharedCadence = QuotaWindowVocabulary.barQualifiers(forBars: [
            QuotaWindowVocabulary.BarCaption(cadence: "7d", label: "Free weekly limit"),
            QuotaWindowVocabulary.BarCaption(cadence: "7d", label: "Additional allowance")
        ])
        XCTAssertEqual(sharedCadence, [
            QuotaWindowVocabulary.barQualifierWeekly,
            QuotaWindowVocabulary.barQualifierAdditional
        ])

        // Two daily bars share one cadence and read the allowance word.
        let sharedDaily = QuotaWindowVocabulary.barQualifiers(forBars: [
            QuotaWindowVocabulary.BarCaption(cadence: "Daily", label: "Daily cap"),
            QuotaWindowVocabulary.BarCaption(cadence: "Daily", label: "Daily allowance cap")
        ])
        XCTAssertEqual(sharedDaily, [
            QuotaWindowVocabulary.barQualifierDaily,
            QuotaWindowVocabulary.barQualifierDaily
        ])
    }

    /// The same rule, driven by the labels the widget actually renders.
    ///
    /// A window label is built through `QuotaWindowVocabulary.windowLabel(...)`,
    /// which rewrites the prose into the hyphenated cadence copy, so the
    /// production shape of a 7-day window is "7-day window" and not "Free
    /// weekly limit".  The pair the owner approved has to come out of that
    /// shape too (Kody review 2026-10-21).
    func testProductionLabelsNameTheQualifierFromTheCadence() {
        let sharedWeek = QuotaWindowVocabulary.barQualifiers(forBars: [
            QuotaWindowVocabulary.BarCaption(cadence: "7-day", label: "7-day window"),
            QuotaWindowVocabulary.BarCaption(cadence: "7-day", label: "Additional allowance")
        ])
        XCTAssertEqual(sharedWeek, [
            QuotaWindowVocabulary.barQualifierWeekly,
            QuotaWindowVocabulary.barQualifierAdditional
        ])

        // Two windows of different periods are not siblings, so a lone 7-day
        // bar prints no qualifier at all.
        let loneWeek = QuotaWindowVocabulary.barQualifiers(forBars: [
            QuotaWindowVocabulary.BarCaption(cadence: "7-day", label: "7-day window"),
            QuotaWindowVocabulary.BarCaption(cadence: "5-hour", label: "5-hour window")
        ])
        XCTAssertEqual(loneWeek, ["", ""])
    }

    /// The cadence group is what decides whether two bars share a cadence, so
    /// it has to follow the period rather than the wording.
    func testBarCadenceGroupFollowsThePeriod() {
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "Weekly", label: "Weekly cap"),
            QuotaWindowVocabulary.sevenDay
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "5h", label: "5-hour window"),
            QuotaWindowVocabulary.fiveHour
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "Daily", label: "Daily cap"),
            QuotaWindowVocabulary.oneDay
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "1m", label: "Billing cycle"),
            QuotaWindowVocabulary.oneMonth
        )
        // The window's own cadence wins over the label's prose, because that
        // is the cadence the caption token beside the bar prints.  A group
        // that disagreed with the token gave a bar a qualifier that named a
        // period its own token contradicted (Kody review 2026-10-21).
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "5h", label: "Weekly cap"),
            QuotaWindowVocabulary.fiveHour
        )
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "7-day", label: "7-day window"),
            QuotaWindowVocabulary.sevenDay
        )
        // An extra allowance is looked up without its label, so it keeps the
        // period it doubles instead of collapsing to "Other limit".
        XCTAssertEqual(
            QuotaWindowVocabulary.barCadenceGroup(cadence: "7-day", label: "Additional allowance"),
            QuotaWindowVocabulary.sevenDay
        )
    }

    /// A sanitized Muse Assist wire payload, as the reader files it today.
    ///
    /// The weekly limit arrives with a "weekly" token.  The extra allowance
    /// arrives with no token at all and with a label the pipeline has already
    /// rewritten to the catch-all "Other limit" copy, so nothing in the label
    /// says what kind of window it is.  The provider and the missing token are
    /// the whole of the signal, which is why the identity has to be carried
    /// with the window instead of read back from its label.
    private struct MuseAssistWireWindow {
        let id: String
        let label: String
        let window: String?
        let providerKey: String

        /// The canonical cadence the widget gives this window.
        var canonicalCadence: String {
            QuotaWindowVocabulary.standardCadence(windowToken: window, label: label)
        }

        /// The label the widget renders for this window.
        var displayLabel: String {
            QuotaWindowVocabulary.windowLabel(windowToken: window, existingLabel: label)
        }

        /// The bar facts the widget's qualifier resolution sees.
        var barCaption: QuotaWindowVocabulary.BarCaption {
            QuotaWindowVocabulary.BarCaption(
                cadence: canonicalCadence,
                label: displayLabel,
                isExtraAllowance: QuotaWindowVocabulary.isExtraAllowance(
                    providerKey: providerKey,
                    label: label,
                    windowToken: window
                )
            )
        }
    }

    private let museAssistWeekly = MuseAssistWireWindow(
        id: "weekly",
        label: "weekly window",
        window: "weekly",
        providerKey: "muse-assist"
    )

    private let museAssistExtra = MuseAssistWireWindow(
        id: "extra",
        label: "Other limit window",
        window: nil,
        providerKey: "muse-assist"
    )

    /// The extra-allowance identity comes from the provider and the wire
    /// label, because the rendered label cannot answer it.
    func testExtraAllowanceIdentityIsReadFromTheWireNotTheDisplayLabel() {
        XCTAssertTrue(
            QuotaWindowVocabulary.isExtraAllowance(
                providerKey: "muse-assist",
                label: "Other limit window",
                windowToken: nil
            ),
            "a tokenless Muse Assist window that names no period is the extra allowance."
        )
        XCTAssertFalse(
            QuotaWindowVocabulary.isExtraAllowance(
                providerKey: "muse-assist",
                label: "8h window",
                windowToken: "8h"
            ),
            "a Muse Assist window with a real token is a meter, not extra usage."
        )
        XCTAssertFalse(
            QuotaWindowVocabulary.isExtraAllowance(
                providerKey: "anthropic",
                label: "Other limit window",
                windowToken: nil
            ),
            "another provider's unknown window is not the Muse Assist extra allowance."
        )
        // A label that names the kind is an extra allowance for any provider.
        XCTAssertTrue(
            QuotaWindowVocabulary.isExtraAllowance(
                providerKey: "anthropic",
                label: "Additional allowance",
                windowToken: "7d"
            )
        )
    }

    /// The owner-approved pair, driven by the real Muse Assist wire shapes.
    ///
    /// The extra allowance names no period of its own, so it cannot join the
    /// weekly's group by itself and the pair never appeared:  the weekly bar
    /// read no qualifier and the extra bar read none either.  It is extra
    /// capacity of the period it doubles, so it joins the one sibling that has
    /// a period, and the two bars read "weekly" and "additional" (owner,
    /// 2026-10-21).
    func testMuseAssistExtraAllowanceReadsAdditionalBesideTheWeekly() {
        let bars = [museAssistWeekly, museAssistExtra]

        // The wire shapes are what the reader files:  the weekly carries a
        // token, the extra carries none and its label is the catch-all copy.
        XCTAssertEqual(museAssistWeekly.canonicalCadence, QuotaWindowVocabulary.sevenDay)
        XCTAssertEqual(museAssistWeekly.displayLabel, "7-day window")
        XCTAssertEqual(museAssistExtra.canonicalCadence, QuotaWindowVocabulary.otherLimit)
        XCTAssertEqual(museAssistExtra.displayLabel, "Other limit window")

        let qualifiers = QuotaWindowVocabulary.barQualifiers(forBars: bars.map(\.barCaption))
        XCTAssertEqual(qualifiers, [
            QuotaWindowVocabulary.barQualifierWeekly,
            QuotaWindowVocabulary.barQualifierAdditional
        ])

        // The caption row is the token beside the qualifier, and the extra
        // allowance keeps the "+" marker the owner uses for extra quota.
        let weeklyToken = QuotaWindowVocabulary.popoverCaption(
            windowToken: museAssistWeekly.canonicalCadence,
            label: museAssistWeekly.displayLabel
        )
        let extraToken = QuotaWindowVocabulary.popoverCaption(
            windowToken: museAssistExtra.canonicalCadence,
            label: museAssistExtra.displayLabel
        )
        XCTAssertEqual(weeklyToken, "7d")
        XCTAssertEqual(extraToken, "+")
        XCTAssertEqual("\(weeklyToken) \(qualifiers[0])", "7d weekly")
        XCTAssertEqual("\(extraToken) \(qualifiers[1])", "+ additional")
    }

    /// The sibling has to be unambiguous:  with two different periods beside
    /// it, an extra allowance cannot know which one it doubles, so it stays on
    /// its own and neither bar prints a qualifier.
    func testExtraAllowanceDoesNotJoinWhenItsSiblingsDisagree() {
        let qualifiers = QuotaWindowVocabulary.barQualifiers(forBars: [
            QuotaWindowVocabulary.BarCaption(cadence: "7-day", label: "7-day window"),
            QuotaWindowVocabulary.BarCaption(cadence: "5-hour", label: "5-hour window"),
            QuotaWindowVocabulary.BarCaption(
                cadence: QuotaWindowVocabulary.otherLimit,
                label: "Other limit window",
                isExtraAllowance: true
            )
        ])
        XCTAssertEqual(qualifiers, ["", "", ""])
    }

    /// An extra allowance on its own still prints no qualifier:  there is no
    /// sibling to tell it apart from.
    func testLoneExtraAllowancePrintsNoQualifier() {
        let qualifiers = QuotaWindowVocabulary.barQualifiers(forBars: [
            QuotaWindowVocabulary.BarCaption(
                cadence: QuotaWindowVocabulary.otherLimit,
                label: "Other limit window",
                isExtraAllowance: true
            )
        ])
        XCTAssertEqual(qualifiers, [""])
    }
}
