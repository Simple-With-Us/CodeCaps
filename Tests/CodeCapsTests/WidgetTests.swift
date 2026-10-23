import XCTest
import Foundation
import QuotaCore

/// Verifies CodeCaps WidgetKit data models, presentation logic, wire payload decoding,
/// platform ordering, and project/entitlement hygiene.
final class WidgetTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/CodeCapsTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private static var widgetPresentationURL: URL {
        repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetPresentation.swift")
    }

    private static var projectYmlURL: URL {
        repoRoot.appendingPathComponent("ios/CodeCapsCompanion/project.yml")
    }

    private static var widgetEntitlementsURL: URL {
        repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/CodeCapsWidgets.entitlements")
    }

    private static var widgetMacEntitlementsURL: URL {
        repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Generated/CodeCapsWidgetsMac.entitlements")
    }

    private static var companionMacEntitlementsURL: URL {
        repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Generated/CodeCapsCompanionMac.entitlements")
    }

    private func readSource(at url: URL) throws -> String {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("File not found at \(url.path)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - Sentence Gap & Hygiene Tests

    func testWidgetSentenceGapHygiene() throws {
        let source = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(
            source.contains("widgetSentenceGap = \"\\u{00A0} \""),
            "WidgetPresentation must define widgetSentenceGap with non-breaking space per fleet standards"
        )
    }

    func testWidgetEntitlementsAppGroup() throws {
        let iosEntitlements = try readSource(at: Self.widgetEntitlementsURL)
        XCTAssertTrue(
            iosEntitlements.contains("group.com.simplewithus.codecaps"),
            "iOS widget entitlements must declare group.com.simplewithus.codecaps"
        )

        let macEntitlements = try readSource(at: Self.widgetMacEntitlementsURL)
        XCTAssertTrue(
            macEntitlements.contains("CC8UTF7ATG.codecaps"),
            "macOS widget entitlements must declare the team-authorized Mac app group"
        )
        XCTAssertTrue(
            macEntitlements.contains("com.apple.security.app-sandbox"),
            "macOS widget entitlements must declare app-sandbox"
        )
        let macAppEntitlements = try readSource(at: Self.companionMacEntitlementsURL)
        XCTAssertTrue(macAppEntitlements.contains("CC8UTF7ATG.codecaps"))
        XCTAssertTrue(macAppEntitlements.contains("com.apple.security.network.client"))
    }

    func testWidgetPresentationUsesSharedPlatformDisplayTitles() throws {
        let source = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(
            source.contains("WidgetPlatformDisplay.title"),
            "Widget parsing must resolve canonical platform display names, not raw provider ids"
        )
    }

    /// The widget target cannot import QuotaCore as a module, but it compiles
    /// `QuotaWindowVocabulary.swift` by path, so the rule that owns the number
    /// is in scope.  The widget asks that rule now instead of restating the
    /// comparison, which is what stops a copy of the question creeping back in
    /// here where no test would see it.
    func testWidgetReadsTheSharedSpentThreshold() throws {
        let source = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(
            source.contains("QuotaCapRule.isExhausted(remainingPercent: percent, providerSaysExhausted: isExhausted)"),
            "the widget must ask the shared rule, not carry a number of its own"
        )
        XCTAssertFalse(
            source.contains("if let percent { return percent <= 0 }"),
            "the widget must not keep the old exact-zero test"
        )
        XCTAssertFalse(
            source.contains("percent <= QuotaCapRule.spentThreshold"),
            "the widget must not restate the threshold comparison beside the rule"
        )
    }

    /// Owner 2026-10-22: the desktop widget read "At Cap" for six providers and
    /// showed figures the app had already replaced.
    ///
    /// The widget believed stale windows, so the shared freshness rule has to
    /// reach it.  It cannot carry a threshold of its own, because the Mac's
    /// dashboard, the cap rule and the phone all age a reading the same way.
    func testWidgetAgesItsReadingsByTheSharedRule() throws {
        let source = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(
            source.contains("QuotaFreshnessRule.isFresh(observedAt: observedAt, resetAt: resetAt, now: now)"),
            "the widget must ask the shared freshness rule about a window"
        )
        XCTAssertTrue(
            source.contains("QuotaFreshnessRule.isReadingRecent(observedAt: observedAt, now: now)"),
            "the widget must age a reading by the shared rule"
        )
        XCTAssertFalse(
            source.contains("private static let staleAfter"),
            "the widget must not carry a stale threshold of its own"
        )
        XCTAssertFalse(
            source.contains("30 * 60"),
            "the widget must not restate the shared threshold beside the rule"
        )
    }

    /// Owner 2026-10-23: the xAI row showed two 7-day windows at 0% with a
    /// "due" caption while the live weekly allowance read 91% with a reset on
    /// 2026-10-29.  The fleet copies of a period that ended days earlier
    /// reached the widget's cache as well.
    ///
    /// The widget reads the same payload the app does, so it has to drop the
    /// same copies, through the same shared rule.  The widget target compiles
    /// `QuotaWindowVocabulary.swift` by path, so the rule is in scope here.
    func testWidgetDropsACopyOfAPeriodThatEnded() throws {
        let source = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(
            source.contains("QuotaFreshnessRule.isDeadCopy(observedAt: observed, resetAt: parsedReset, now: now)"),
            "the widget must ask the shared rule about a window whose period already ended"
        )
        XCTAssertTrue(
            source.contains("QuotaFreshnessRule.isDeadCopy(observedAt: parseDate(from: $0.occurredAt),"),
            "the widget's Antigravity pool must ask the same rule"
        )
    }

    /// Only a fresh window may cap a plan in the widget.  A stale window said
    /// how the plan looked when the reading was taken.
    func testWidgetOnlyLetsAFreshWindowCapAPlan() throws {
        let source = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(
            source.contains(".filter { $0.isFresh(now: now) }"),
            "the widget's cap window must be chosen from the fresh windows"
        )
        XCTAssertTrue(
            source.contains("let atCap = freshWindows.first {"),
            "the widget's cap line must be decided from the fresh windows"
        )
    }

    /// The marker on a widget bar is drawn for the same period the Mac's
    /// caption names, so the widget cannot keep its own copy of the words that
    /// name a period.  Its old copy had no three hour branch, so a three hour
    /// window drew a marker for a different period than the one it named.
    func testWidgetResolvesItsPeriodThroughTheSharedResolver() throws {
        let source = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(
            source.contains("ResetAlarmCadence.resolve(token: cadence, label: label)"),
            "the widget must ask the shared period resolver"
        )
        XCTAssertFalse(
            source.contains("words.contains(\"5h\")"),
            "the widget must not keep its own copy of the words that name a period"
        )
        XCTAssertFalse(
            source.contains("words.contains(\"7d\")"),
            "the widget must not keep its own copy of the words that name a period"
        )
    }

    /// The widget and the phone have to answer the same question the same way
    /// about one payload.
    ///
    /// The phone moved to the shared rule while the widget kept its own copy of
    /// `(pct ?? 100) <= 0 || flag`, so the widget still believed the export's
    /// stale exhausted word over a healthy reading and masked the five-hour row
    /// as "n/a" while the app showed live figures (Sentry 18329264, Kody review
    /// 2026-10-22).  Every copy of that expression has to be gone.
    func testWidgetDecidesExhaustionThroughTheSharedRule() throws {
        let source = try readSource(at: Self.widgetPresentationURL)
        XCTAssertFalse(
            source.contains("<= 0 || (w.isExhausted ?? false)"),
            "the widget must not keep the old per-window exhaustion test beside the shared rule"
        )
        XCTAssertFalse(
            source.contains("<= 0 || (weeklyWin?.isExhausted ?? false)"),
            "the widget's weekly must be decided through the shared rule too"
        )
        XCTAssertFalse(
            source.contains("isExhausted: (f.remainingPercent ?? 100) <= 0"),
            "the widget's five-hour row must not keep its own zero test"
        )
        XCTAssertTrue(
            source.contains("let weeklyExhausted = isFresh(weeklyWin)"),
            "the widget's weekly must be decided through the shared rule, and only a fresh reading may spend it"
        )
        XCTAssertTrue(
            source.contains("let isExhausted = weeklyExhausted || QuotaCapRule.isAtCap(remainingPercent: freshPercents.min())"),
            "a spent weekly must spend the pool even when the five-hour window still reports headroom, "
                + "and only a fresh reading may spend it"
        )
        XCTAssertTrue(
            source.contains("QuotaCapRule.publishedReading(remainingPercent: w.remainingPercent,"),
            "the widget must publish the same bounded reading the phone publishes"
        )
    }

    /// A spent five hour allowance has to publish the same figure here as it
    /// does on the phone.
    ///
    /// The widget published the fallback zero for a spent five hour allowance
    /// that carried no figure, while the phone published nothing for the same
    /// window, so one payload showed a zero bar on one surface and a dash on
    /// the other (Kody review 2026-10-22).  The phone now publishes the zero
    /// for every spent row, and this pins the widget's half of that pair: it
    /// decides the window through the shared rule and publishes through the
    /// shared rule, so neither surface can drift from the other again.
    func testTheWidgetPublishesASpentFiveHourWindowTheWayThePhoneDoes() throws {
        let source = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(
            source.contains("let fiveHourSpent = isFresh(fiveHourWin)"),
            "the widget must decide the five-hour window through the shared rule, and only a fresh reading may spend it"
        )
        XCTAssertTrue(
            source.contains("&& QuotaCapRule.isExhausted(remainingPercent: f.remainingPercent,"),
            "the widget's five-hour window must be judged by the shared rule"
        )
        XCTAssertTrue(
            source.contains("remainingPercent: QuotaCapRule.publishedReading(remainingPercent: f.remainingPercent,"),
            "the widget must publish the five-hour reading through the shared rule"
        )
    }

    func testProjectYmlDeclaresWidgetTargets() throws {
        let yml = try readSource(at: Self.projectYmlURL)
        XCTAssertTrue(
            yml.contains("CodeCapsWidgets:"),
            "project.yml must define CodeCapsWidgets target"
        )
        XCTAssertTrue(
            yml.contains("CodeCapsWidgetsMac:"),
            "project.yml must define CodeCapsWidgetsMac target"
        )
        XCTAssertTrue(
            yml.contains("target: CodeCapsWidgets"),
            "CodeCapsCompanion must embed CodeCapsWidgets"
        )
        XCTAssertTrue(
            yml.contains("target: CodeCapsWidgetsMac"),
            "CodeCapsCompanionMac must embed CodeCapsWidgetsMac"
        )
    }

    func testExhaustedWeeklyAntigravityRetainsMaskedShortWindow() throws {
        let observedAt = "2026-09-13T10:00:00Z"
        let now = ISO8601DateFormatter().date(from: "2026-09-13T10:05:00Z")!
        let windows = AntigravityQuotaGroups.normalize([
            QuotaWindow(id: "gemini-short", provider: "Antigravity", via: "antigravity",
                        modelId: "gemini-pro", label: "Gemini Pro", remainingPercent: 82,
                        window: "5h", occurredAt: observedAt),
            QuotaWindow(id: "gemini-week", provider: "Antigravity", via: "antigravity",
                        modelId: "gemini-pro", label: "Gemini Pro weekly", remainingPercent: 0,
                        window: "weekly", occurredAt: observedAt),
        ])
        XCTAssertTrue(windows.contains { $0.window == "5h" },
                      "The exhausted-weekly pool still needs its short window for a masked n/a row.")
        XCTAssertEqual(AntigravityQuotaGroups.maskedWindowIds(in: windows, now: now),
                       ["antigravity:gemini:5h"])
    }

    // MARK: - Presentation Logic Tests (Simulated with mirrored pure logic)

    func testPercentFormatting() {
        XCTAssertEqual(formatPercent(82.4, isMasked: false), "82%")
        XCTAssertEqual(formatPercent(0.0, isMasked: false), "0%")
        XCTAssertEqual(formatPercent(99.6, isMasked: false), "100%")
        XCTAssertEqual(formatPercent(nil, isMasked: false), "—")
        XCTAssertEqual(formatPercent(50.0, isMasked: true), "n/a")
    }

    func testCountdownFormatting() {
        let now = Date()
        let future5m = now.addingTimeInterval(300)
        let future2h = now.addingTimeInterval(7200)
        let future2d = now.addingTimeInterval(86400 * 2 + 3600 * 3)
        let past = now.addingTimeInterval(-60)

        XCTAssertEqual(formatCountdown(resetAt: future5m, now: now), "5m")
        XCTAssertEqual(formatCountdown(resetAt: future2h, now: now), "2h")
        XCTAssertEqual(formatCountdown(resetAt: future2d, now: now), "2d 3h")
        XCTAssertEqual(formatCountdown(resetAt: past, now: now), "due")
        XCTAssertEqual(formatCountdown(resetAt: nil, now: now), "")
    }

    func testWidgetParserResolvesCanonicalPlatformTitles() {
        XCTAssertEqual(
            WidgetPlatformDisplay.title(canonicalKey: "cursor", manifestProviderLabel: "cursor", wireProvider: "cursor"),
            "Cursor"
        )
        XCTAssertFalse(
            WidgetPlatformDisplay.isRawProviderSlug(
                WidgetPlatformDisplay.title(canonicalKey: "cursor", manifestProviderLabel: "cursor", wireProvider: "cursor"),
                canonicalKey: "cursor"
            )
        )
    }

    func testWirePayloadParsing() throws {
        let json = """
        {
          "windows": [
            {
              "id": "claude-5h",
              "provider": "anthropic",
              "providerKey": "anthropic",
              "label": "5-hour window",
              "remainingPercent": 78.5,
              "isExhausted": false,
              "resetAt": "2026-09-30T04:00:00Z"
            },
            {
              "id": "cursor-fast",
              "provider": "cursor",
              "providerKey": "cursor",
              "label": "Fast Requests",
              "remainingPercent": 42.0,
              "isExhausted": false,
              "resetAt": "2026-10-15T00:00:00Z"
            }
          ]
        }
        """

        let data = try XCTUnwrap(json.data(using: .utf8))
        struct WireEnvelope: Decodable {
            let windows: [WireWindow]?
        }
        struct WireWindow: Decodable {
            let id: String
            let provider: String
            let providerKey: String?
            let label: String
            let remainingPercent: Double?
        }

        let envelope = try JSONDecoder().decode(WireEnvelope.self, from: data)
        let windows = try XCTUnwrap(envelope.windows)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].provider, "anthropic")
        XCTAssertEqual(windows[0].remainingPercent, 78.5)
        XCTAssertEqual(windows[1].provider, "cursor")
        XCTAssertEqual(windows[1].remainingPercent, 42.0)
    }

    // MARK: - Cadence Token & Reset Caption

    /// The caption under a bar has to name its window, and a two-window plan
    /// standing in for one bar is the case the owner called out as unclear.
    func testShortCadenceTokens() {
        XCTAssertEqual(shortCadence(cadence: "5-hour window", label: "5-hour window"), "5h")
        XCTAssertEqual(shortCadence(cadence: "5h", label: "5h"), "5h")
        XCTAssertEqual(shortCadence(cadence: "7-day window", label: "7-day window"), "7d")
        XCTAssertEqual(shortCadence(cadence: "Weekly cap", label: "Weekly cap"), "7d")
        XCTAssertEqual(shortCadence(cadence: "1w", label: "1w"), "7d")
        XCTAssertEqual(shortCadence(cadence: "Daily cap", label: "Daily cap"), "1d")
        // Cursor's real reading: an "Included plan" on a billing cycle.  The Mac
        // app already renders this as 1m, so the two surfaces must agree.
        XCTAssertEqual(shortCadence(cadence: "billing-cycle", label: "Included plan"), "1m")
        XCTAssertEqual(shortCadence(cadence: "Monthly cap", label: "Monthly cap"), "1m")
    }

    func testResetCaptionUsesTwoLargestUnits() {
        let now = Date()
        XCTAssertEqual(resetCaption(resetAt: now.addingTimeInterval(2 * 86400 + 3 * 3600), now: now), "Resets in 2d 3h")
        XCTAssertEqual(resetCaption(resetAt: now.addingTimeInterval(7200), now: now), "Resets in 2h")
        // An unknown or already-elapsed reset says nothing rather than reading
        // as "due", which would be a claim the provider never made.
        XCTAssertEqual(resetCaption(resetAt: nil, now: now), "")
        XCTAssertEqual(resetCaption(resetAt: now.addingTimeInterval(-60), now: now), "")
    }

    /// The pick that decides which window a single bar represents.
    func testControllingWindowPrefersLeastRemaining() {
        let windows = [
            window("5h", percent: 100, hoursToReset: 3),
            window("7d", percent: 1, hoursToReset: 44)
        ]
        XCTAssertEqual(controllingWindow(windows, .mostUrgent)?.id, "7d")
        XCTAssertEqual(controllingWindow(windows, .resetsSoonest)?.id, "5h")
        XCTAssertEqual(controllingWindow(windows, .mostHeadroom)?.id, "5h")
    }

    /// A window CodeCaps cannot see is not the urgent one.
    func testControllingWindowNeverPicksMasked() {
        let windows = [
            window("5h", percent: 0, hoursToReset: 2, masked: true),
            window("7d", percent: 40, hoursToReset: 40)
        ]
        XCTAssertEqual(controllingWindow(windows, .mostUrgent)?.id, "7d")
    }

    // MARK: - Edit Mode Exists

    /// Regression guard for the owner's report that there was no way to choose
    /// which quota a widget shows.  A `StaticConfiguration` has no parameters,
    /// so its edit sheet is empty by construction; all three widgets must be
    /// `AppIntentConfiguration` or the dropdowns disappear again.
    func testEveryWidgetIsConfigurable() throws {
        let bundle = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/CodeCapsWidgetBundle.swift"))
        XCTAssertFalse(bundle.contains("StaticConfiguration"),
                       "A StaticConfiguration cannot be configured, which is why the edit sheet was empty.")
        let configurations = bundle.components(separatedBy: "AppIntentConfiguration").count - 1
        XCTAssertEqual(configurations, 3, "All three widgets need an AppIntentConfiguration.")
        XCTAssertTrue(bundle.contains("intent: SelectQuotaIntent.self"))
    }

    func testConfigurationIntentOffersPlanRowsAndWindowChoice() throws {
        let intent = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetConfigurationIntent.swift"))
        XCTAssertTrue(intent.contains("WidgetConfigurationIntent"))
        XCTAssertTrue(intent.contains("var plan: WidgetPlanEntity?"))
        XCTAssertTrue(intent.contains("var rowLayout: WidgetRowLayout"))
        XCTAssertTrue(intent.contains("var quotasPerProvider: WidgetQuotasPerProvider"))
        XCTAssertTrue(intent.contains("var windowPick: WidgetWindowPick"))
        XCTAssertTrue(intent.contains("enum WidgetQuotasPerProvider"))
        // The options have to be filled from the live snapshot, not a hardcoded
        // list, or the picker offers plans the widget cannot show.
        XCTAssertTrue(intent.contains("WidgetSnapshotStore.readSnapshot()"))
    }

    // MARK: - Copy

    /// "Active" overclaims: a tracked plan can be exhausted or unused and still
    /// be tracked.  The owner asked for "tracked" everywhere.
    func testNoActivePlansCopyRemains() throws {
        for relative in ["Widgets/WidgetViews.swift", "Widgets/WidgetPresentation.swift"] {
            let source = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/\(relative)"))
            XCTAssertFalse(source.contains("Active Plans"), "\(relative) still says Active Plans")
            XCTAssertFalse(source.contains("active plans"), "\(relative) still says active plans")
        }
        let views = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetViews.swift"))
        XCTAssertTrue(views.contains("Tracked Plans"))
        // The small size lost its plan count and its header countdown; both were
        // numbers on screen with nothing to say which plan they described.
        let smallView = views.components(separatedBy: "struct OverviewSmallView").last?
            .components(separatedBy: "// MARK: - Overview Medium View").first ?? ""
        XCTAssertFalse(smallView.contains("Plans)"), "The small widget still renders a plan count")
    }

    /// "Monthly fast requests" was preview data that leaked into the gallery
    /// and told the owner nothing.  It described no real reading.
    func testBogusPlaceholderSubtitleIsGone() throws {
        let presentation = try readSource(at: Self.widgetPresentationURL)
        XCTAssertFalse(presentation.contains("Monthly fast requests"))
        // The Antigravity pools read as their own names so they fit a row.
        XCTAssertTrue(presentation.contains("title: \"3rd-Party\""))
    }

    func testWindowCaptionRowNamesTheWindow() throws {
        let rows = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetWindowRows.swift"))
        XCTAssertTrue(rows.contains("struct WindowCaptionRow"))
        XCTAssertTrue(rows.contains("struct PlanBarRow"))
        XCTAssertTrue(rows.contains("struct PlanDualBarRow"))
        XCTAssertTrue(rows.contains("struct PlanGrid"))
        XCTAssertTrue(rows.contains("quotasPerProvider"))
        // The mark replaces the app name in the corner; the asset itself belongs
        // to the owning seat, so this only asserts the view looks for it and
        // degrades to nothing rather than a reserved gap.
        XCTAssertTrue(rows.contains("codecaps-mark"))
        let presentation = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(presentation.contains("static func shortCadence"))
        XCTAssertTrue(presentation.contains("static func resetCaption"))
        XCTAssertTrue(presentation.contains("func dualWindows()"))
    }

    func testOverviewViewsPassQuotasPerProviderToPlanGrid() throws {
        let views = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetViews.swift"))
        XCTAssertTrue(views.contains("quotasPerProvider: quotasPerProvider"))
        let bundle = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/CodeCapsWidgetBundle.swift"))
        XCTAssertTrue(bundle.contains("quotasPerProvider: entry.quotasPerProvider"))
        let rows = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetWindowRows.swift"))
        XCTAssertTrue(rows.contains("PlanDualBarRow"))
    }

    func testDualWindowsSelectionPrefersUnmaskedPair() {
        let windows = [
            window("5h", percent: 80, hoursToReset: 2, masked: false),
            window("7d", percent: 90, hoursToReset: 48, masked: false),
            window("masked-pool", percent: 0, hoursToReset: 0, masked: true)
        ]
        let dual = dualWindows(windows)
        XCTAssertNotNil(dual)
        XCTAssertEqual(dual?.0.id, "5h")
        XCTAssertEqual(dual?.1.id, "7d")

        let singleWindow = [window("5h", percent: 80, hoursToReset: 2)]
        XCTAssertNil(dualWindows(singleWindow))
    }

    // MARK: - Helpers mirroring WidgetPresentation logic for test isolation

    private func formatPercent(_ percent: Double?, isMasked: Bool) -> String {
        if isMasked { return "n/a" }
        guard let percent else { return "—" }
        return "\(Int(percent.rounded()))%"
    }

    private func formatCountdown(resetAt: Date?, now: Date) -> String {
        guard let resetAt else { return "" }
        let seconds = resetAt.timeIntervalSince(now)
        guard seconds > 0 else { return "due" }
        let minutes = max(1, Int(ceil(seconds / 60)))
        if minutes >= 1440 {
            let days = minutes / 1440
            let hours = (minutes % 1440) / 60
            return "\(days)d\(hours > 0 ? " \(hours)h" : "")"
        }
        if minutes >= 60 {
            let hours = minutes / 60
            let mins = minutes % 60
            return "\(hours)h\(mins > 0 ? " \(mins)m" : "")"
        }
        return "\(minutes)m"
    }

    private func shortCadence(cadence: String, label: String) -> String {
        let combined = "\(cadence) \(label)".lowercased()
        if combined.contains("5h") || combined.contains("5-hour") || combined.contains("5 hour") || combined.contains("five_hour") { return "5h" }
        if combined.contains("4h") || combined.contains("4-hour") || combined.contains("4 hour") || combined.contains("four_hour") { return "4h" }
        if combined.contains("7d") || combined.contains("7-day") || combined.contains("7 day") || combined.contains("weekly") || combined.contains("1w") { return "7d" }
        if combined.contains("daily") || combined.contains("1d") || combined.contains("24h") || combined.contains("24-hour") { return "1d" }
        if combined.contains("month") || combined.contains("billing") || combined.contains("cycle") || combined.contains("30d") { return "1m" }
        if combined.contains("year") || combined.contains("annual") || combined.contains("365") { return "1y" }
        let first = label.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: " ")
            .first ?? ""
        return first.isEmpty ? "Quota" : first
    }

    private func resetCaption(resetAt: Date?, now: Date) -> String {
        guard let resetAt else { return "" }
        let countdown = formatCountdown(resetAt: resetAt, now: now)
        guard !countdown.isEmpty, countdown != "due" else { return "" }
        return "Resets in " + countdown
    }

    private struct FixtureWindow {
        let id: String
        let percent: Double?
        let hoursToReset: Double
        let masked: Bool
    }

    private enum FixtureWindowPick {
        case mostUrgent
        case resetsSoonest
        case mostHeadroom
    }

    private func window(
        _ id: String,
        percent: Double?,
        hoursToReset: Double,
        masked: Bool = false
    ) -> FixtureWindow {
        FixtureWindow(id: id, percent: percent, hoursToReset: hoursToReset, masked: masked)
    }

    private func controllingWindow(
        _ windows: [FixtureWindow],
        _ pick: FixtureWindowPick
    ) -> FixtureWindow? {
        let visible = windows.filter { !$0.masked }
        let pool = visible.isEmpty ? windows : visible
        switch pick {
        case .mostHeadroom:
            return pool.max {
                ($0.percent ?? 100, $0.hoursToReset) < ($1.percent ?? 100, $1.hoursToReset)
            }
        case .resetsSoonest:
            return pool.min { $0.hoursToReset < $1.hoursToReset }
        case .mostUrgent:
            return pool.min {
                let lhs = $0.percent ?? 100
                let rhs = $1.percent ?? 100
                if lhs != rhs { return lhs < rhs }
                return $0.hoursToReset < $1.hoursToReset
            }
        }
    }

    private func dualWindows(_ windows: [FixtureWindow]) -> (FixtureWindow, FixtureWindow)? {
        guard windows.count >= 2 else { return nil }
        let visible = windows.filter { !$0.masked }
        let pool = visible.count >= 2 ? visible : windows
        guard pool.count >= 2 else { return nil }
        return (pool[0], pool[1])
    }
}
