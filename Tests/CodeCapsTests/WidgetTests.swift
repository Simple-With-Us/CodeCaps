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

    func testUnknownMetersDoNotRenderUsedSegmentsOrPacingMarkers() throws {
        let source = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetViews.swift"))
        XCTAssertTrue(source.contains("if hasReading, fraction.isFinite, totalW > 0"))
        XCTAssertTrue(source.contains("if hasReading, let elapsed = elapsedFraction"))
        // Every production call site must supply validity, rather than silently
        // accepting the meter's numeric-zero default for unknown readings.
        for path in ["WidgetViews.swift", "WidgetWindowRows.swift"] {
            let text = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/" + path))
            let calls = text.components(separatedBy: "MiniProgressBar(").dropFirst()
            for call in calls {
                XCTAssertTrue(call.prefix(500).contains("hasReading:"), path)
            }
        }
    }

    func testDetailLevelIsConfigurableAndSingleResetStaysUnknown() throws {
        let intent = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetConfigurationIntent.swift"))
        let summary = intent.components(separatedBy: "public static var parameterSummary").last ?? ""
        XCTAssertTrue(summary.contains("$detailLevel"))
        let rows = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetWindowRows.swift"))
        XCTAssertTrue(rows.contains(#"return countdown.isEmpty ? "—" : countdown"#))
    }

    func testWidgetDetailActionStaysInTheWidget() throws {
        let source = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetDetailIntent.swift"))
        XCTAssertTrue(source.contains("openAppWhenRun: Bool = false"))
        XCTAssertTrue(source.contains("defaults.removeObject(forKey: key)"))
        XCTAssertFalse(source.contains("URLSession"))
        let views = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetViews.swift"))
        XCTAssertTrue(views.contains("WidgetPlanDetailView(platform: selected"))
        XCTAssertTrue(views.contains(#"ShowWidgetPlanDetailIntent(planID: "", overviewKey:"#))
    }

    func testWidgetDistinguishesExtraFromUnclassifiedLimit() throws {
        let source = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(source.contains(#"isExtraAllowance ? "Extra" : "Limit""#))
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
    ///
    /// The widget asks the shared rule with the reading's own observation time,
    /// the same field the Mac and the phone ask with, and it only judges
    /// copies:  this Mac's own reading keeps its row.
    func testWidgetDropsACopyOfAPeriodThatEnded() throws {
        let source = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(
            source.contains("QuotaFreshnessRule.isDeadCopy(observedAt: parseDate(from: w.reportedAt) ?? parseDate(from: w.occurredAt),"),
            "the widget must ask the shared rule about a window whose period already ended"
        )
        XCTAssertFalse(
            source.contains("QuotaFreshnessRule.isDeadCopy(observedAt: observed,"),
            "the widget must ask the shared rule with the reading's own observation time"
        )
        XCTAssertTrue(
            source.contains("QuotaWindowVocabulary.isOwnDeviceWindow("),
            "the widget must only judge copies, so this Mac's own reading keeps its row"
        )
    }

    /// This Mac's own reading is this device's own reading, and the widget can
    /// only tell it from another machine's copy when the payload names the
    /// installation that wrote it.  Every fleet-sourced window names a
    /// producer instance, so without that the widget read this Mac's own
    /// expired reading as somebody else's copy and deleted it, while the Mac
    /// kept it, and the row vanished instead of greying out.
    ///
    /// `WidgetPresentation.swift` is not in the macOS test target, so the
    /// wiring is pinned here by reading the source.
    func testWidgetAsksWithThePayloadsOwningInstallation() throws {
        let source = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(
            source.contains("let producerInstanceId: String?"),
            "the widget's payload must carry the installation that wrote it"
        )
        XCTAssertTrue(
            source.contains("ownInstanceId: envelope.producerInstanceId"),
            "the widget must ask the own-device rule with the owning installation's id"
        )
        XCTAssertTrue(
            source.contains("ownInstanceId: ownInstanceId"),
            "the widget's own-device rule must receive the owning installation's id"
        )
        XCTAssertFalse(
            source.contains("ownInstanceId: \"codecaps\""),
            "the widget must not invent an owning installation id"
        )
    }

    /// Only a fresh window may spend the widget's Antigravity pool, and the
    /// freshest window wins.  The phone has to agree with both, or the same
    /// payload reads exhausted on one surface and live on the other.
    func testWidgetOnlyLetsAFreshWindowSpendTheAntigravityPool() throws {
        let source = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(
            source.contains("let weeklyExhausted = isFresh(weeklyWin)"),
            "only a fresh window may spend the widget's Antigravity pool"
        )
        XCTAssertTrue(
            source.contains("func isFresher(_ candidate: WireRawWindow, than current: WireRawWindow?) -> Bool {"),
            "the widget must pick the freshest window of a pool period"
        )
    }

    /// Only a fresh window may cap a plan in the widget.  A stale window said
    /// how the plan looked when the reading was taken.
    func testWidgetOnlyLetsAFreshWindowCapAPlan() throws {
        let source = try readSource(at: Self.widgetPresentationURL)
        let atCapMethod = source
            .components(separatedBy: "public func atCapWindow(now: Date = Date()) -> WidgetWindowItem? {")
            .dropFirst()
            .first?
            .components(separatedBy: "\n    }")
            .first ?? ""
        XCTAssertFalse(atCapMethod.isEmpty, "the widget must decide caps through its window selector")
        // A platform that reports only supplementary video windows keeps them,
        // and a stale window that is at cap with a reset still ahead may name
        // the cap;  every other cap pick comes from the fresh windows.
        XCTAssertTrue(
            atCapMethod.contains("let planWindows = windows.filter { !$0.isSupplementaryVideoQuota && !$0.isModelDetail }"),
            "the widget's cap window never comes from a supplementary video pool or a per-model detail"
        )
        XCTAssertTrue(
            atCapMethod.contains("let capPool = planWindows.isEmpty ? windows : planWindows"),
            "a platform reporting only video windows keeps them, otherwise they leave the cap pool"
        )
        XCTAssertTrue(
            atCapMethod.contains("$0.isFresh(now: now)"),
            "the widget's cap window must be chosen from the fresh windows"
        )
        XCTAssertTrue(
            atCapMethod.contains(".filter { !$0.isMasked && $0.remainingPercent != nil }"),
            "masked and unknown windows must not cap a plan"
        )
        XCTAssertTrue(
            atCapMethod.contains(".filter { WidgetPresentation.isAtCap(percent: $0.remainingPercent, isExhausted: $0.isExhausted) }"),
            "the widget must use the shared cap rule after freshness filtering"
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
            source.contains("let fresh = primary.filter { $0.isFresh(now: now) && !$0.isMasked }"),
            "only fresh, unmasked readings may contribute to the pool cap"
        )
        XCTAssertTrue(
            source.contains("let isExhausted = weeklyExhausted || QuotaCapRule.isAtCap(remainingPercent: fresh.compactMap(\\.remainingPercent).min())"),
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

    /// CC-227: malformed App Group JSON must fall through to sandbox stores;
    /// only a decoded empty snapshot stops without resurrecting stale rows.
    func testWidgetAppGroupSnapshotReadUsesSharedPolicy() throws {
        let provider = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetDataProvider.swift"))
        XCTAssertTrue(
            provider.contains("AppGroupSnapshotReadPolicy.decision"),
            "the widget must classify App Group reads through the shared policy"
        )
        XCTAssertTrue(
            provider.contains("case .stopAuthoritativeEmpty:"),
            "a valid empty snapshot must be authoritative"
        )
        XCTAssertTrue(
            provider.contains("case .stopAuthoritativeContent:"),
            "a valid non-empty snapshot must be authoritative"
        )
        // A failed App Group read used to return this tuple before any fallback.
        // The same tuple is the honest empty state after every store has been tried,
        // so the ban covers the App Group tier and the later stores, and the one
        // allowed occurrence has to sit in the final empty state.
        let appGroupMarker = "// 1. App Group container"
        let sandboxMarker = "// 2. Sandbox Application Support"
        let honestEmptyMarker = "// 5. Unconfigured / no data synced state"
        let emptyReturn = "return ([], nil, true)"
        guard
            let appGroupStart = provider.range(of: appGroupMarker)?.lowerBound,
            let sandboxStart = provider.range(of: sandboxMarker)?.lowerBound,
            let honestEmptyStart = provider.range(of: honestEmptyMarker)?.lowerBound,
            appGroupStart < sandboxStart,
            sandboxStart < honestEmptyStart
        else {
            return XCTFail("App Group, sandbox, and the final empty state must stay in that order")
        }
        let appGroupTier = provider[appGroupStart..<sandboxStart]
        XCTAssertTrue(
            appGroupTier.contains(appGroupMarker),
            "the App Group tier must stay above the sandbox fallback"
        )
        XCTAssertFalse(
            appGroupTier.contains(emptyReturn),
            "decode failure must not blank the widget before probing fallbacks"
        )
        XCTAssertFalse(
            provider[sandboxStart..<honestEmptyStart].contains(emptyReturn),
            "a missed sandbox reading must keep probing the later stores"
        )
        XCTAssertEqual(
            provider.components(separatedBy: emptyReturn).count - 1,
            1,
            "the blanking return belongs only to the final empty state"
        )
        XCTAssertTrue(
            provider[honestEmptyStart...].contains(emptyReturn),
            "an unconfigured widget still ends on the honest empty state"
        )
        XCTAssertTrue(
            provider.contains("Read or decode failures fall through."),
            "the widget must document fall-through on decode failure"
        )
        XCTAssertFalse(
            provider.contains("platforms.isEmpty ? nil : platforms"),
            "filtered-empty snapshots must stay authoritative, not fall through as decode failures"
        )
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

    /// Owner 2026-11-09: the small widget keeps days-and-hours off its rows;
    /// tapping a row reveals the plan's 5h/7d windows with the time remaining
    /// beside each bar.  Every other surface keeps the countdown on the row.
    func testSmallWidgetHidesCountdownUntilTap() throws {
        let views = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetViews.swift"))
        let smallView = views.components(separatedBy: "struct OverviewSmallView").last?
            .components(separatedBy: "// MARK: - Overview Medium View").first ?? ""
        XCTAssertTrue(smallView.contains("showsCountdown: false"), "Small rows must not show the days-and-hours countdown")
        XCTAssertTrue(smallView.contains("showsCadenceToken: false"), "Small rows must not show the 5h/7d duration tokens either")
        XCTAssertTrue(smallView.contains("ShowWidgetPlanDetailIntent"), "Small rows must tap through to the plan detail")
        XCTAssertTrue(smallView.contains("selectedSmallDetail"), "Small view must render the tapped plan detail")
        XCTAssertTrue(smallView.contains("smallDetailScope"), "Small taps must not leak into larger widgets' shared detail scope")
        XCTAssertTrue(smallView.contains("detailLevel != .compact"), "The compact detail level turns small tap-through off too")
        XCTAssertTrue(smallView.contains("planDetailWindows"), "Small detail shows the plan's 5h/7d windows")
        let provider = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetDataProvider.swift"))
        XCTAssertTrue(provider.contains("smallDetailScope"))
        XCTAssertTrue(provider.contains("$0.id == id && $0.hasModelDetails"), "Larger widgets still detail only model-detail plans")
        XCTAssertTrue(views.contains("compactLabels && !window.cadenceToken.isEmpty"), "Compact detail falls back to the full label when a window has no token")
        let rows = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetWindowRows.swift"))
        XCTAssertTrue(rows.contains("var showsCountdown: Bool = true"), "Countdown stays on everywhere else by default")
        let presentation = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(presentation.contains("planDetailWindows"))
    }

    func testWindowCaptionRowNamesTheWindow() throws {
        let rows = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetWindowRows.swift"))
        XCTAssertTrue(rows.contains("struct WindowCaptionRow"))
        XCTAssertTrue(rows.contains("struct PlanBarRow"))
        XCTAssertTrue(rows.contains("struct PlanDualBarRow"))
        // The Mac meter grammar: token, bar, percent and countdown on one
        // line, with the percent and the reset trailing on the right of the
        // bar (CC-213, owner 2026-11-07).  The small widget uses it too
        // (owner 2026-11-08); the escape hatch must stay named.
        XCTAssertTrue(rows.contains("struct WidgetMeterRow"))
        XCTAssertTrue(rows.contains("usesMeterLayout"))
        XCTAssertTrue(rows.contains("struct PlanGrid"))
        XCTAssertTrue(rows.contains("quotasPerProvider"))
        // The mark replaces the app name in the corner; the asset itself belongs
        // to the owning seat, so this only asserts the view looks for it and
        // degrades to nothing rather than a reserved gap.
        XCTAssertTrue(rows.contains("codecaps-mark"))
        let presentation = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(presentation.contains("static func shortCadence"))
        XCTAssertTrue(presentation.contains("static func resetCaption"))
        XCTAssertTrue(presentation.contains("func dualWindows(now:"))
        // QA 2026-11-06, verified against the real wire capture (committed
        // verbatim at Tests/Fixtures/qa3-wire-regression-fixture.json):  the
        // codecaps 5h and the collector weekly share series "general", the
        // collector's 5h headline is series "minimax:coding-plan", and
        // Copilot's Chat and Completions share the canonical key "monthly".
        // The dedupe identity must be the triple of video class, aliased
        // series, and canonical cadence:  video partitions first so a
        // supplementary video window can never fold into a plan window;  the
        // MiniMax alias set is bounded to the producer's verified
        // general/coding-plan equivalence;  the canonical cadence keeps one
        // model's 5-hour, daily and weekly windows separate.
        XCTAssertTrue(presentation.contains("static func allowanceSeries(forWireId id: String) -> String"))
        XCTAssertTrue(presentation.contains(#"parts[0] == "producer""#))
        XCTAssertTrue(presentation.contains("static func normalizedAllowanceSeries(providerKey: String, series: String) -> String"))
        XCTAssertTrue(presentation.contains(#""minimax:coding-plan", "coding-plan""#))
        // The bounded xAI subscription-pool alias (qa4 wire capture:
        // "grok:subscription" from the codecaps reader and "xai:subscription"
        // from the collector are one allowance).
        XCTAssertTrue(presentation.contains(#"providerKey == "xai", series.lowercased() == "grok:subscription""#))
        XCTAssertTrue(presentation.contains(#"item.isSupplementaryVideoQuota ? "video|" : "plan|""#))
        // The cadence leg must be canonicalised into the wire namespace, not
        // keyed on the display cadence, or a pre-windowKey copy ("weekly")
        // splits from its keyed copy ("7d") - same kody finding as PR #370.
        XCTAssertTrue(presentation.contains("static func canonicalWireCadence("))
        XCTAssertTrue(presentation.contains(#"case QuotaWindowVocabulary.sevenDay: return "7d""#))
    }

    func testWidgetPairsMetersWithSharedCadenceRule() throws {
        let presentation = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(
            presentation.contains("QuotaMeterCadence.isShort"),
            "widget pairing must ask the shared short-cadence rule"
        )
        XCTAssertTrue(
            presentation.contains("window.isSupplementaryVideoQuota"),
            "widget pairing must honour the carried supplementary-video flag"
        )
    }

    func testWidgetBarRemainingSegmentUsesMacGrammar() throws {
        let presentation = try readSource(at: Self.widgetPresentationURL)
        XCTAssertTrue(presentation.contains("quotaBarRemainingColor"))
        let widgetPaths = [
            "ios/CodeCapsCompanion/Widgets/WidgetWindowRows.swift",
            "ios/CodeCapsCompanion/Widgets/WidgetViews.swift",
        ]
        for relativePath in widgetPaths {
            let text = try readSource(at: Self.repoRoot.appendingPathComponent(relativePath))
            let calls = text.components(separatedBy: "MiniProgressBar(").dropFirst()
            XCTAssertFalse(calls.isEmpty, relativePath)
            for call in calls {
                let segment = String(call.prefix(600))
                XCTAssertTrue(
                    segment.contains("WidgetPresentation.quotaBarRemainingColor"),
                    "\(relativePath) must tint the remaining segment with Mac glance ink, not status or primary"
                )
                XCTAssertFalse(
                    segment.contains("color: .primary"),
                    "\(relativePath) must not leave .primary on a quota bar remaining segment (CC-228)"
                )
                XCTAssertFalse(
                    segment.contains("color: statusColor"),
                    "\(relativePath) must not tint the bar from statusColor (CC-223)"
                )
            }
        }
        let rows = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetWindowRows.swift"))
        XCTAssertFalse(rows.contains("color: statusColor,\n                    elapsedFraction: window?.elapsedFraction()"))
    }

    func testAccessoryRectangularSingleWindowBarUsesQuotaInkNotPrimary() throws {
        let views = try readSource(at: Self.repoRoot.appendingPathComponent("ios/CodeCapsCompanion/Widgets/WidgetViews.swift"))
        let elseBranch = views.components(separatedBy: "if entry.quotasPerProvider == .twoIfAvailable, let pair = platform.dualWindows()").last ?? ""
        let singleWindowBranch = elseBranch.components(separatedBy: "} else {").dropFirst().first?
            .components(separatedBy: "case .accessoryInline:").first ?? ""
        XCTAssertTrue(
            singleWindowBranch.contains("MiniProgressBar"),
            "non-dual accessory rectangular must still draw a quota bar"
        )
        XCTAssertTrue(
            singleWindowBranch.contains("WidgetPresentation.quotaBarRemainingColor"),
            "non-dual accessory rectangular must match Mac glance remaining ink (CC-228)"
        )
        XCTAssertFalse(
            singleWindowBranch.contains("color: .primary"),
            "non-dual accessory rectangular must not use .primary on the bar"
        )
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

    func testDualWindowsSelectionSkipsSupplementaryVideoQuota() {
        let windows = [
            window("minimax:5h", percent: 81, hoursToReset: 2),
            FixtureWindow(id: "minimax:video", percent: 100, hoursToReset: 20, masked: false, label: "1d window", isSupplementaryVideoQuota: true),
            window("minimax:7d", percent: 5, hoursToReset: 66)
        ]
        let dual = dualWindows(windows, providerKey: "minimax")
        XCTAssertEqual(dual?.0.id, "minimax:5h")
        XCTAssertEqual(dual?.1.id, "minimax:7d", "the video daily must not displace the weekly coding window")
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
        // A `var`, not a `let`:  a `let` with a default is excluded from the
        // memberwise initializer, and the MiniMax video fixture passes one.
        var label: String = ""
        // Mirrors WidgetWindowItem.isSupplementaryVideoQuota:  the identity
        // is carried, not re-derived from the display label.
        var isSupplementaryVideoQuota: Bool = false
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

    private func dualWindows(_ windows: [FixtureWindow], providerKey: String = "") -> (FixtureWindow, FixtureWindow)? {
        guard windows.count >= 2 else { return nil }
        let visible = windows.filter { !$0.masked }
        let pool = visible.count >= 2 ? visible : windows
        guard pool.count >= 2 else { return nil }
        // Mirrors WidgetPresentation: a MiniMax supplementary video quota
        // never takes a bar from the plan's own windows when two remain.
        // The carried flag decides, not the display label - the label
        // rewrite drops the video tokens (Kody review, PR #367).
        let planWindows = pool.filter { !$0.isSupplementaryVideoQuota }
        // Mirrors production exactly:  no fallback to the pool - a plan
        // with fewer than two of its own windows has no pair, so a video
        // row can never slip in beside one plan bar (Sentry review, PR
        // #369).
        guard planWindows.count >= 2 else { return nil }
        return (planWindows[0], planWindows[1])
    }
}
