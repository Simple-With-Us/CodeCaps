import AppKit
import SwiftUI
import XCTest
@testable import CodeCaps
import QuotaCore

/// Pins the 2026-09-30 Glance changes that are not the alarm rules themselves:
/// the From Mac / From Fleet switch and its memory, the header text, the
/// Antigravity "Third-Party" name and marks, the source headings, and the row
/// spacing — measured, so nothing truncates at the longest realistic values.
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

    func testGlanceOpensOnFromMacByDefault() {
        XCTAssertEqual(MonitorModel(defaults: defaults).glanceView, .fromMac)
    }

    func testTheLastViewIsRememberedAcrossLaunches() {
        let first = MonitorModel(defaults: defaults)
        first.glanceView = .fromFleet
        XCTAssertEqual(MonitorModel(defaults: defaults).glanceView, .fromFleet)
        first.glanceView = .fromMac
        XCTAssertEqual(MonitorModel(defaults: defaults).glanceView, .fromMac)
    }

    func testSwitchLabelsReadFromMacAndFromFleet() {
        XCTAssertEqual(GlanceViewMode.allCases.map(\.eyebrow), ["FROM MAC", "FROM FLEET"])
        XCTAssertEqual(GlanceViewMode.allCases.map(\.title), ["From Mac", "From Fleet"])
    }

    func testTheRenameKeepsTheStoredChoice() {
        // An install from before the rename saved these raw values.
        defaults.set("fleetReported", forKey: "glanceView")
        XCTAssertEqual(MonitorModel(defaults: defaults).glanceView, .fromFleet)
        defaults.set("thisMac", forKey: "glanceView")
        XCTAssertEqual(MonitorModel(defaults: defaults).glanceView, .fromMac)
    }

    func testHeaderCountsProvidersFromMacAndReportingSourcesFromTheFleet() {
        let checked = Date(timeIntervalSince1970: 1_790_000_000)
        let time = checked.formatted(date: .omitted, time: .shortened)
        XCTAssertEqual(glanceHeaderSeparator, "   •   ", "a bullet with three spaces either side")
        XCTAssertEqual(glanceHeaderStatus(view: .fromMac, reporting: 6, total: 7, sources: 2, checked: checked),
                       "6 of 7   •   \(time)")
        XCTAssertEqual(glanceHeaderStatus(view: .fromFleet, reporting: 6, total: 7, sources: 2, checked: checked),
                       "2 sources   •   \(time)")
        XCTAssertEqual(glanceHeaderStatus(view: .fromFleet, reporting: 0, total: 0, sources: 1, checked: nil),
                       "1 source")
        XCTAssertEqual(glanceHeaderStatus(view: .fromFleet, reporting: 6, total: 7, sources: 0, checked: checked),
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
        model.glanceView = .fromMac
        let local = QuotaGlanceMetrics.popoverHeight(for: model)
        model.glanceView = .fromFleet
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
        XCTAssertEqual(observations.map(\.providerId), ["anthropic"], "keyed by provider, like the From Mac row")
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

    func testTheThirdPartyStarIsSolidBlackOnLightAndWhiteOnDark() {
        XCTAssertTrue(PlatformLogoImage.usesSolidTone("google-antigravity:third-party"))
        XCTAssertFalse(PlatformLogoImage.usesSolidTone("google-antigravity:gemini"), "the Gemini star keeps its colour")
        XCTAssertFalse(PlatformLogoImage.usesSolidTone("openai"), "other one-colour marks keep the ink tone")

        func resolved(_ appearance: NSAppearance.Name) -> NSColor? {
            var color: NSColor?
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                color = NSColor(Theme.solidMark).usingColorSpace(.sRGB)
            }
            return color
        }
        let light = resolved(.aqua)
        let dark = resolved(.darkAqua)
        XCTAssertEqual(light?.redComponent ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(light?.greenComponent ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(light?.blueComponent ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(dark?.redComponent ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(dark?.greenComponent ?? -1, 1, accuracy: 0.001)
        XCTAssertEqual(dark?.blueComponent ?? -1, 1, accuracy: 0.001)
    }

    func testTheGeminiRowShowsTheColourStarInTheDefaultGlanceStyle() {
        let model = MonitorModel(defaults: defaults)
        XCTAssertEqual(model.glanceMarkStyle(for: AntigravityDisplay.providerKey), .standard)
        let star = PlatformLogoImage.load(providerKey: "google-antigravity:gemini",
                                          style: model.glanceMarkStyle(for: AntigravityDisplay.providerKey))
        XCTAssertNotNil(star)
        XCTAssertEqual(star?.isTemplate, false, "drawn in its own colours, not as a silhouette")
    }

    // MARK: - From Fleet headings

    func testFleetHeadingsAreTheSourceInCapitals() {
        XCTAssertEqual(glanceFleetGroupHeading("chatgpt.com"), "CHATGPT.COM")
        XCTAssertEqual(glanceFleetGroupHeading(FleetOrigin.title(for: "chatgpt.com")), "CHATGPT.COM")
        XCTAssertEqual(glanceFleetGroupHeading("Mac mini"), "MAC MINI")
        XCTAssertFalse(glanceFleetGroupHeading("build-box").contains("FLEET"))
    }

    func testTheHeadingBandIsDarkerThanTheListInBothAppearances() {
        func luminance(_ color: Color, _ appearance: NSAppearance.Name) -> CGFloat {
            var value: CGFloat = -1
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                if let rgb = NSColor(color).usingColorSpace(.sRGB) {
                    value = 0.2126 * rgb.redComponent + 0.7152 * rgb.greenComponent + 0.0722 * rgb.blueComponent
                }
            }
            return value
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            XCTAssertLessThan(luminance(Theme.groupBand, appearance), luminance(Theme.background, appearance),
                              "\(appearance.rawValue): the heading band must be darker than the list")
        }
    }

    func testAFleetMiniMaxRowNeverExpands() {
        let minimax = DisplaySection.rows(for: QuotaPlatformSection(
            providerKey: "minimax", providerLabel: "MiniMax", via: nil, expected: true, windows: []), now: now)[0]
        XCTAssertFalse(glanceRowAllowsExpansion(minimax, origin: .fleet))
        XCTAssertTrue(glanceRowAllowsExpansion(minimax, origin: .local), "the local MiniMax row still opens")
        let claude = DisplaySection.rows(for: QuotaPlatformSection(
            providerKey: "anthropic", providerLabel: "Claude", via: nil, expected: true, windows: []), now: now)[0]
        XCTAssertTrue(glanceRowAllowsExpansion(claude, origin: .fleet))
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
            glanceResetCountdown(start.addingTimeInterval(31 * 86_400 + 23 * 3_600 + 59 * 60), now: start),
            glanceResetCountdown(start.addingTimeInterval(23 * 3_600 + 59 * 60), now: start),
        ]
        XCTAssertEqual(longest, ["6d 23h", "17d 4h", "29d 23h", "31d 23h", "23h 59m"])
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
        // Owner delta 2026-09-30: clearly more than the 24pt it was.
        XCTAssertGreaterThanOrEqual(Metrics.glanceMeterGroupGap, 48)
    }

    func testTheBarsAreThickerAndTheElapsedMarkerTaller() {
        // 1.5x the 4pt bar, and 2x the 8pt (4pt bar + 2pt either side) marker.
        XCTAssertGreaterThanOrEqual(Metrics.glanceMeterBarHeight, 4 * 1.5)
        XCTAssertGreaterThanOrEqual(Metrics.glanceMeterMarkerHeight, 8 * 2)
        XCTAssertEqual(QuotaUsageBar.markerWidth, 2, "the marker keeps its width")
    }

    func testTheHeaderFitsOnOneLine() {
        // "CodeCaps", the switch, and "ALL   •   6 of 7   •   4:27 PM" with
        // the refresh button, gaps and gutters, at their real type sizes.
        let switchWidth = GlanceViewMode.allCases.reduce(CGFloat(1)) {
            $0 + width($1.eyebrow, size: 10, weight: .bold) + CGFloat($1.eyebrow.count) * 0.8 + 16
        }
        let trailing = 11 + 4 + width("ALL", weight: .semibold)
            + width(glanceHeaderSeparator + "88 of 88" + glanceHeaderSeparator + "12:59 PM", weight: .regular,
                    monospacedDigits: true)
        let total = Metrics.glanceGutter * 2 + width("CodeCaps", size: 13, weight: .semibold)
            + switchWidth + trailing + 16 + 10 * 3 + 8
        XCTAssertLessThanOrEqual(total, Metrics.glanceWidth)
    }

    func testTheRowStillFitsThePopoverWithTheAlarmBellShowing() {
        XCTAssertLessThanOrEqual(Metrics.glanceRowIntrinsicWidth, Metrics.glanceWidth)
    }
}
