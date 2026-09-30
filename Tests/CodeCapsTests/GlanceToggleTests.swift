import AppKit
import XCTest
@testable import CodeCaps
import QuotaCore

/// Pins the 2026-09-30 Glance changes that are not the alarm rules themselves:
/// the This Mac / Fleet Reported switch and its memory, the header text, the
/// Antigravity "Third-Party" name and marks, and the row spacing — measured,
/// so nothing truncates at the longest realistic values.
@MainActor
final class GlanceToggleTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() {
        super.setUp()
        suiteName = "com.jays.codecaps.glance-toggle." + UUID().uuidString
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - View switch

    func testGlanceOpensOnThisMacByDefault() {
        XCTAssertEqual(MonitorModel(defaults: defaults).glanceView, .thisMac)
    }

    func testTheLastViewIsRememberedAcrossLaunches() {
        let first = MonitorModel(defaults: defaults)
        first.glanceView = .fleetReported
        XCTAssertEqual(MonitorModel(defaults: defaults).glanceView, .fleetReported)
        first.glanceView = .thisMac
        XCTAssertEqual(MonitorModel(defaults: defaults).glanceView, .thisMac)
    }

    func testSwitchLabelsUseTheHeadingSmallCaps() {
        XCTAssertEqual(GlanceViewMode.allCases.map(\.eyebrow), ["THIS MAC", "FLEET REPORTED"])
        XCTAssertEqual(GlanceViewMode.allCases.map(\.title), ["This Mac", "Fleet Reported"])
    }

    func testHeaderCountsProvidersOnThisMacAndReportingSourcesInTheFleet() {
        let checked = Date(timeIntervalSince1970: 1_790_000_000)
        let time = checked.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(glanceHeaderStatus(view: .thisMac, reporting: 6, total: 7, sources: 2, checked: checked),
                       "6 of 7  ·  \(time)")
        XCTAssertEqual(glanceHeaderStatus(view: .fleetReported, reporting: 6, total: 7, sources: 2, checked: checked),
                       "2 sources  ·  \(time)")
        XCTAssertEqual(glanceHeaderStatus(view: .fleetReported, reporting: 0, total: 0, sources: 1, checked: nil),
                       "1 source")
        XCTAssertEqual(glanceHeaderStatus(view: .fleetReported, reporting: 6, total: 7, sources: 0, checked: checked),
                       time, "no sources: just the time")
    }

    func testAlarmsAllIsSharedWithTheManagerAndPersists() {
        let model = MonitorModel(defaults: defaults)
        XCTAssertTrue(model.alarmsAll)
        model.alarmsAll = false
        model.toggleAlarm(for: "anthropic")
        XCTAssertTrue(model.isProviderAlarmSelected("anthropic"))
        XCTAssertTrue(model.isAlarmEnabled(for: "anthropic"))
        XCTAssertFalse(model.isAlarmEnabled(for: "openai"))

        let relaunched = MonitorModel(defaults: defaults)
        XCTAssertFalse(relaunched.alarmsAll)
        XCTAssertTrue(relaunched.isProviderAlarmSelected("anthropic"))
    }

    func testPopoverHeightIsTheSameForBothViews() {
        let model = MonitorModel(defaults: defaults)
        model.glanceView = .thisMac
        let local = QuotaGlanceMetrics.popoverHeight(for: model)
        model.glanceView = .fleetReported
        XCTAssertEqual(QuotaGlanceMetrics.popoverHeight(for: model), local,
                       "flipping the switch while the popover is open must not resize it")
    }

    func testFleetRowsFeedTheAlarmInAScopeOfTheirOwn() {
        let iso = ISO8601DateFormatter()
        let model = MonitorModel(defaults: defaults)
        model.injectForTests(sections: [], now: now)
        model.injectFleetForTests(groups: [FleetWindowGroup(id: "mini", title: "Mac mini", windows: [
            QuotaWindow(id: "mini:claude:7d", provider: "anthropic", providerKey: "anthropic", label: "7d window",
                        remainingPercent: 40, resetAt: iso.string(from: now.addingTimeInterval(86_400)),
                        window: "168h", occurredAt: iso.string(from: now)),
        ])])
        let observations = model.resetAlarmObservationsForCurrentReadings()
        XCTAssertEqual(observations.map(\.scope), ["fleet:mini"])
        XCTAssertEqual(observations.map(\.providerId), ["anthropic"], "keyed by provider, like the This Mac row")
    }

    // MARK: - Antigravity names and marks

    func testTheThirdPartyPoolIsCalledThirdParty() {
        XCTAssertEqual(AntigravityDisplay.poolTitle("third-party"), "Third-Party")
        XCTAssertEqual(AntigravityDisplay.poolTitle("gemini"), "Gemini")
        XCTAssertEqual(AntigravityDisplay.rowTitle("third-party"), "Antigravity · Third-Party")
        XCTAssertEqual(AntigravityDisplay.windowLabel("Third-Party Models · Weekly"), "Third-Party · Weekly")
        XCTAssertEqual(AntigravityDisplay.poolName(in: "Third-Party · Weekly"), "Third-Party")
        XCTAssertEqual(compactWindowName("Third-Party Models · 5-hour"), "Third-Party · 5h")
    }

    func testEachAntigravityPoolWearsItsOwnMark() {
        let gemini = PlatformLogoImage.load(providerKey: "google-antigravity:gemini", style: .standard)
        XCTAssertNotNil(gemini, "the Gemini pool uses the colour Gemini star")
        XCTAssertEqual(gemini?.isTemplate, false, "the colour star keeps its gradient")

        let thirdParty = PlatformLogoImage.load(providerKey: "google-antigravity:third-party", style: .standard)
        XCTAssertNotNil(thirdParty, "the Third-Party pool uses the one-colour star")
        XCTAssertEqual(thirdParty?.isTemplate, true, "a one-colour mark follows Light and Dark")
        XCTAssertTrue(PlatformLogoImage.isMonochromeMark("google-antigravity:third-party"))
        XCTAssertFalse(PlatformLogoImage.isMonochromeMark("google-antigravity:gemini"))
        XCTAssertNotNil(PlatformLogoImage.load(providerKey: "google-antigravity:some-new-pool", style: .template),
                        "a pool with no mark of its own falls back to the platform's mark")
    }

    func testOneColourMarksFollowLightAndDarkAndBrandColoursStay() {
        // Near-black on the dark Glance surface was the bug for these four.
        for key in ["openai", "codex", "cursor", "minimax", "xai", "grok", "grok-cli", "grok-bot"] {
            XCTAssertTrue(PlatformLogoImage.isMonochromeMark(key), "\(key) is a one-colour mark")
            XCTAssertEqual(PlatformLogoImage.load(providerKey: key, style: .standard)?.isTemplate, true,
                           "\(key) must adapt to a dark surface in the default Glance style")
        }
        for key in ["anthropic", "claude", "google-antigravity:gemini", "google-antigravity"] {
            XCTAssertFalse(PlatformLogoImage.isMonochromeMark(key), "\(key) keeps its brand colour")
        }
    }

    // MARK: - Spacing, measured

    private func width(_ text: String, size: CGFloat = 11, weight: NSFont.Weight = .medium,
                       monospacedDigits: Bool = false) -> CGFloat {
        let font = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    func testOneHundredPercentLeavesARealGapBeforeTheCountdown() {
        let gap = Metrics.glanceMeterPercentWidth - width("100%", monospacedDigits: true)
        XCTAssertGreaterThanOrEqual(gap, 10, "\"100%\" and the countdown must never touch again")
    }

    func testTheLongestCountdownsFitTheirColumn() {
        let start = now
        let longest = [
            glanceResetCountdown(start.addingTimeInterval(6 * 86_400 + 23 * 3_600 + 59 * 60), now: start),
            glanceResetCountdown(start.addingTimeInterval(17 * 86_400 + 4 * 3_600 + 57 * 60), now: start),
            glanceResetCountdown(start.addingTimeInterval(29 * 86_400 + 23 * 3_600 + 59 * 60), now: start),
        ]
        XCTAssertEqual(longest, ["6d 23h 59m", "17d 4h 57m", "29d 23h 59m"])
        for value in longest {
            XCTAssertLessThanOrEqual(width(value), Metrics.glanceMeterCountdownWidth,
                                     "'\(value)' would truncate in the countdown column")
        }
    }

    func testCaptionsAndTitlesFitTheirColumns() {
        for caption in ["5h", "7d", "1m", "24h", "Plan", "14d"] {
            XCTAssertLessThanOrEqual(width(caption), Metrics.glanceMeterCaptionWidth, caption)
        }
        for title in ["Antigravity", "Claude Code", "Grok Bot", "MiniMax", "Cursor", "Codex"] {
            XCTAssertLessThanOrEqual(width(title, size: 13), Metrics.glanceRowTitleWidth, title)
        }
    }

    func testTheTwoMeterGroupsHaveClearlyMoreSpaceBetweenThemThanTheColumns() {
        XCTAssertGreaterThanOrEqual(Metrics.glanceMeterGroupGap, 2 * Metrics.glanceColumnGap)
    }

    func testTheRowStillFitsThePopoverWithTheAlarmBellShowing() {
        XCTAssertLessThanOrEqual(Metrics.glanceRowIntrinsicWidth, Metrics.glanceWidth)
    }
}
