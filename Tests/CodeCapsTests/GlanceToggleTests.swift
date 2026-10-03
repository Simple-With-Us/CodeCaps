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

    func testSwitchLabelsReadFromMacAndFromFleetInTitleCase() {
        // The label on the switch is the title itself: not capitals, not small
        // caps (owner delta 2026-09-30).
        XCTAssertEqual(GlanceViewMode.allCases.map(\.title), ["From Mac", "From Fleet"])
        for mode in GlanceViewMode.allCases {
            XCTAssertNotEqual(mode.title, mode.title.uppercased(), "\(mode.title) is not all capitals")
            XCTAssertNotEqual(mode.title, mode.title.lowercased(), "\(mode.title) is not all lower case")
            XCTAssertTrue(mode.title.split(separator: " ").allSatisfy { $0.first?.isUppercase == true },
                          "\(mode.title) is Title Case")
        }
    }

    func testTheSwitchTooltipsAreSentencesThatNameTheirSide() {
        XCTAssertEqual(GlanceViewMode.fromMac.detail, "Quotas this Mac reads from the AI tools signed in on it.")
        XCTAssertEqual(GlanceViewMode.fromFleet.detail, "Quotas your other machines report to your fleet endpoint.")
        for mode in GlanceViewMode.allCases {
            XCTAssertNotEqual(mode.detail, mode.title, "a tooltip that repeats the label says nothing")
            XCTAssertFalse(mode.detail.contains("FROM"), "no capitals-only copy left over")
        }
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
        XCTAssertEqual(glanceHeaderParts(view: .fromMac, reporting: 6, total: 7, sources: 2, checked: checked),
                       ["6 of 7", time])
        XCTAssertEqual(glanceHeaderParts(view: .fromFleet, reporting: 6, total: 7, sources: 2, checked: checked),
                       ["2 sources", time])
        XCTAssertEqual(glanceHeaderParts(view: .fromFleet, reporting: 0, total: 0, sources: 1, checked: nil),
                       ["1 source"])
        XCTAssertEqual(glanceHeaderParts(view: .fromFleet, reporting: 6, total: 7, sources: 0, checked: checked),
                       [time], "no sources: just the time")
    }

    func testTheHeaderIsSpokenWithCommasNotBullets() {
        let checked = Date(timeIntervalSince1970: 1_790_000_000)
        let time = checked.formatted(date: .omitted, time: .shortened)
        let parts = glanceHeaderParts(view: .fromMac, reporting: 6, total: 7, sources: 2, checked: checked)
        XCTAssertEqual(parts, ["6 of 7", time])
        XCTAssertEqual(parts.joined(separator: ", "), "6 of 7, \(time)")
        XCTAssertFalse(parts.contains { $0.contains("•") }, "the dots are drawn, not typed into the text")
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

    /// Owner 2026-10-01: "don't capitalize the first letter of fleet URL unless
    /// doing so for all parts of the url".  A host keeps its own casing —
    /// `api.minimax.io`, not `API.MINIMAX.IO` — because a shouted hostname
    /// implies a formality the URL does not have, and the band is already
    /// visually distinct from the rows under it.  A name that is not a host is
    /// still shouted, so a machine name reads as a band.
    func testAHostKeepsItsOwnCasingAndANameIsStillShouted() {
        XCTAssertEqual(glanceFleetGroupHeading("chatgpt.com"), "chatgpt.com")
        XCTAssertEqual(glanceFleetGroupHeading(FleetOrigin.title(for: "chatgpt.com")), "chatgpt.com")
        XCTAssertEqual(glanceFleetGroupHeading("api.minimax.io"), "api.minimax.io")
        XCTAssertEqual(glanceFleetGroupHeading("Mac mini"), "MAC MINI")
        XCTAssertFalse(glanceFleetGroupHeading("build-box").contains("FLEET"))
    }

    /// The reader labels named a command, not a thing, and two of them are
    /// local readers on this Mac rather than remote machines reporting in.
    func testReaderSourceLabelsSayWhatTheyActuallyAre() {
        XCTAssertEqual(glanceFleetSourceLabel("gbu"), "Grok Bot CLI (gbu)")
        XCTAssertEqual(glanceFleetSourceLabel("Antigravity quota summary"),
                       "Antigravity Summary (This Mac)")
        XCTAssertEqual(glanceFleetSourceLabel("chatgpt.com"), "chatgpt.com",
                       "an unfamiliar source passes through unchanged")
    }

    func testASourceThatNamesNothingGetsAPlainHeading() {
        // No source, no sourceApp: FleetOrigin.identity falls back to "fleet".
        let noName = QuotaWindow(id: "x", provider: "openai", label: "5h window", occurredAt: "2026-09-30T12:00:00Z")
        XCTAssertEqual(FleetOrigin.identity(of: noName), "fleet")
        XCTAssertEqual(glanceFleetGroupHeading(FleetOrigin.title(for: FleetOrigin.identity(of: noName))),
                       "UNNAMED SOURCE", "not a bare FLEET under the From Fleet switch")
        // A name of only separators has no words left once it is titled.
        XCTAssertEqual(FleetOrigin.title(for: " - _ "), "")
        XCTAssertEqual(glanceFleetGroupHeading(FleetOrigin.title(for: " - _ ")), "UNNAMED SOURCE")
        XCTAssertEqual(glanceFleetGroupHeading(""), "UNNAMED SOURCE")
        XCTAssertEqual(glanceFleetGroupHeading("  Mac mini "), "MAC MINI", "trimmed")
        // A source that only names its app still gets a real heading.
        let appOnly = QuotaWindow(id: "y", provider: "openai", sourceApp: "chatgpt.com", label: "5h window",
                                occurredAt: "2026-09-30T12:00:00Z")
        XCTAssertEqual(glanceFleetGroupHeading(FleetOrigin.title(for: FleetOrigin.identity(of: appOnly))),
                       "chatgpt.com")
    }

    func testTextOnTheHeadingBandIsReadableInBothAppearances() {
        func components(_ color: Color, _ appearance: NSAppearance.Name) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            var value: (r: CGFloat, g: CGFloat, b: CGFloat) = (0, 0, 0)
            NSAppearance(named: appearance)?.performAsCurrentDrawingAppearance {
                if let rgb = NSColor(color).usingColorSpace(.sRGB) {
                    value = (rgb.redComponent, rgb.greenComponent, rgb.blueComponent)
                }
            }
            return value
        }
        func relativeLuminance(_ c: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
            func lin(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b)
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let band = relativeLuminance(components(Theme.groupBand, appearance))
            let label = relativeLuminance(components(Theme.groupBandLabel, appearance))
            let contrast = (max(band, label) + 0.05) / (min(band, label) + 0.05)
            XCTAssertGreaterThanOrEqual(contrast, 4.5,
                                        "\(appearance.rawValue): the source name and its time on the band")
        }
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
            glanceResetCountdown(start.addingTimeInterval(29 * 86_400 + 59 * 60), now: start),
        ]
        XCTAssertEqual(longest, ["6d 23h", "17d 4h", "29d 23h", "31d 23h", "23h 59m", "29d 59m"])
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
        // Owner delta 2026-09-30, twice: the gap was doubled to 48pt because the
        // row read cramped, then the 624pt popover that bought read too wide and
        // it came back to 28pt.  What separates the two windows is the gap plus
        // the countdown column's trailing slack, so 28pt is the floor that still
        // reads as two columns rather than one run-on.
        XCTAssertGreaterThanOrEqual(Metrics.glanceMeterGroupGap, 28)
    }

    func testTheBarsAreThickerAndTheElapsedMarkerTaller() {
        // 1.5x the 4pt bar, and 2x the 8pt (4pt bar + 2pt either side) marker.
        XCTAssertGreaterThanOrEqual(Metrics.glanceMeterBarHeight, 4 * 1.5)
        XCTAssertGreaterThanOrEqual(Metrics.glanceMeterMarkerHeight, 8 * 2)
        XCTAssertEqual(QuotaUsageBar.markerWidth, 2, "the marker keeps its width")
    }

    // MARK: - The header, laid out

    /// The natural width of the header line at one count and time: everything
    /// at its real type size, the springs at their minimum.
    private func headerIdealWidth(parts: [String], view: GlanceViewMode = .fromMac) -> CGFloat {
        let bar = GlanceHeaderBar(view: .constant(view), alarmsAll: .constant(true), parts: parts,
                                  isRefreshing: false, refresh: {})
        return NSHostingView(rootView: bar.fixedSize(horizontal: true, vertical: false)).fittingSize.width
    }

    func testTheHeaderFitsOnOneLineWithRoomToSpareAtTheWidestCountAndTime() {
        // The widest realistic header: a double-digit count and a double-digit
        // hour, in either view.
        let cases: [(GlanceViewMode, [String])] = [
            (.fromMac, ["12 of 12", "12:59 PM"]),
            (.fromMac, ["88 of 88", "12:59 PM"]),
            (.fromFleet, ["12 sources", "12:59 PM"]),
            (.fromFleet, ["2 sources", "9:13 AM"]),
            (.fromMac, ["7 of 7", "9:13 AM"]),
            (.fromMac, []),
        ]
        for (view, parts) in cases {
            let ideal = headerIdealWidth(parts: parts, view: view)
            XCTAssertGreaterThan(ideal, 0)
            // `ideal` already holds the spring at its minimum; what is left of
            // the popover beyond it is the spring growing.
            let spare = Metrics.glanceWidth - ideal
            XCTAssertGreaterThanOrEqual(spare, 2 * Metrics.glanceHeaderClusterGap,
                                        "\(view) \(parts): the title, switch and cluster must never crowd")
        }
    }

    func testAWiderCountOrTimeOnlyTakesSpaceFromTheSpring() {
        let narrow = headerIdealWidth(parts: ["7 of 7", "9:13 AM"])
        let wide = headerIdealWidth(parts: ["88 of 88", "12:59 PM"])
        XCTAssertGreaterThan(wide, narrow)
        // The title, the switch and every fixed gap are the same either way, so
        // the difference is exactly the two phrases' extra text.
        let extra = width("88 of 88", monospacedDigits: true) - width("7 of 7", monospacedDigits: true)
            + width("12:59 PM", monospacedDigits: true) - width("9:13 AM", monospacedDigits: true)
        XCTAssertEqual(wide - narrow, extra, accuracy: 4)
    }

    func testTheTitleIsSetClearlyApartFromTheSwitch() {
        // Owner delta 2026-09-30: the switch sat cramped against "CodeCaps".
        // It was the same 10pt as every other header gap.
        XCTAssertGreaterThanOrEqual(Metrics.glanceHeaderTitleGap, 20)
        XCTAssertGreaterThan(Metrics.glanceHeaderTitleGap, Metrics.glanceHeaderItemGap,
                             "the title is a group of its own, not another neighbour")
        // And the width really is spent.  With no count or time, the header is
        // the gutters, the title, that gap, the switch, the spring at its
        // minimum, the bell, one gap and the 16pt refresh button.
        let toggle = NSHostingView(rootView: GlanceViewToggle(selection: .constant(.fromMac))).fittingSize.width
        let bell = NSHostingView(rootView: GlanceAlarmAllToggle(isOn: .constant(true))).fittingSize.width
        let expected = Metrics.glanceGutter * 2 + width("CodeCaps", size: 13, weight: .semibold)
            + Metrics.glanceHeaderTitleGap + toggle + Metrics.glanceHeaderClusterGap
            + bell + Metrics.glanceHeaderItemGap + 16
        XCTAssertEqual(headerIdealWidth(parts: []), expected, accuracy: 3)
    }

    func testTheSwitchIsTwoEqualBoxesInTitleCase() {
        let widest = GlanceViewMode.allCases.map { width($0.title, size: 11, weight: .semibold) }.max() ?? 0
        let box = widest + 2 * Metrics.glanceHeaderSegmentPadding
        let host = NSHostingView(rootView: GlanceViewToggle(selection: .constant(.fromMac)))
        XCTAssertEqual(host.fittingSize.width, 2 * box + 1, accuracy: 2, "two equal boxes and the hairline between")
        XCTAssertEqual(host.fittingSize.height, Metrics.glanceHeaderControlHeight)
        // Flipping the selection must not change the switch's shape.
        let flipped = NSHostingView(rootView: GlanceViewToggle(selection: .constant(.fromFleet)))
        XCTAssertEqual(flipped.fittingSize, host.fittingSize)
    }

    func testEveryHeaderControlSharesOneHeightSoTheySitOnOneCentreLine() {
        let bell = NSHostingView(rootView: GlanceAlarmAllToggle(isOn: .constant(true)))
        XCTAssertEqual(bell.fittingSize.height, Metrics.glanceHeaderControlHeight)
        let toggle = NSHostingView(rootView: GlanceViewToggle(selection: .constant(.fromMac)))
        XCTAssertEqual(toggle.fittingSize.height, Metrics.glanceHeaderControlHeight)
        let bar = GlanceHeaderBar(view: .constant(.fromMac), alarmsAll: .constant(true),
                                  parts: ["7 of 7", "9:13 AM"], isRefreshing: false, refresh: {})
        XCTAssertEqual(NSHostingView(rootView: bar.fixedSize(horizontal: true, vertical: false)).fittingSize.height,
                       Metrics.glanceHeaderHeight)
        XCTAssertGreaterThanOrEqual((Metrics.glanceHeaderHeight - Metrics.glanceHeaderControlHeight) / 2, 8,
                                    "comfortable padding above and below the controls")
    }

    func testTheRowStillFitsThePopoverWithTheAlarmBellShowing() {
        XCTAssertLessThanOrEqual(Metrics.glanceRowIntrinsicWidth, Metrics.glanceWidth)
    }
}
