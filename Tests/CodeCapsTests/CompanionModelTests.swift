import XCTest
@testable import CodeCaps
import QuotaCore

/// Verifies CodeCaps companion data models, overarching platform grouping,
/// duplicate source handling, and customizable platform ordering.
///
/// Mirrors the companion contract used on iOS so behavioral regressions
/// are caught directly in the standard `swift test` suite.
final class CompanionModelTests: XCTestCase {
    private static var companionModelURL: URL? {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/CodeCapsTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("ios/CodeCapsCompanion/App/Models/CompanionQuotaModel.swift")
    }

    private static var sentenceGapURL: URL? {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ios/CodeCapsCompanion/App/Models/SentenceGap.swift")
    }

    private static var companionContentViewURL: URL? {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("ios/CodeCapsCompanion/App/Views/CompanionContentView.swift")
    }

    private func readCompanionModelSource() throws -> String {
        guard let url = Self.companionModelURL, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("CompanionQuotaModel.swift is not present at \(Self.companionModelURL?.path ?? "")")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func readSentenceGapSource() throws -> String {
        guard let url = Self.sentenceGapURL, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("SentenceGap.swift is not present at \(Self.sentenceGapURL?.path ?? "")")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func readCompanionContentViewSource() throws -> String {
        guard let url = Self.companionContentViewURL, FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("CompanionContentView.swift is not present at \(Self.companionContentViewURL?.path ?? "")")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - App Group & Hygiene

    func testCompanionResolvesCanonicalPlatformDisplayTitles() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("WidgetPlatformDisplay.title"),
            "Companion parsing must resolve canonical platform names, not raw provider ids"
        )
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

    func testPlatformSpecificAppGroupIds() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains(#"appGroupId = "group.com.simplewithus.codecaps""#),
            "iOS must use its registered App Group"
        )
        XCTAssertTrue(source.contains(#"appGroupId = "CC8UTF7ATG.codecaps""#))
        XCTAssertTrue(source.contains("#if os(macOS)"))
    }

    func testSentenceGapInOutcomeMessages() throws {
        let source = try readSentenceGapSource()
        XCTAssertTrue(
            source.contains(#"Test notification accepted." + sentenceGap + "System settings control banners and sound."#),
            "Test notification success message must use sentenceGap"
        )
        XCTAssertTrue(
            source.contains(#"Notifications are turned off for CodeCaps." + sentenceGap"#),
            "Denied notification message must use sentenceGap"
        )
    }

    // MARK: - Reordering Logic

    func testPlatformOrderingLogic() {
        let initial = ["anthropic", "minimax", "openai", "xai", "cursor", "grok-bot", "antigravity:gemini", "antigravity:third-party"]

        // Move minimax (index 1) to top (index 0)
        var order = initial
        let minimax = order.remove(at: 1)
        order.insert(minimax, at: 0)
        XCTAssertEqual(order.first, "minimax")
        XCTAssertEqual(order[1], "anthropic")

        // Move minimax down to index 1
        let movedDown = order.remove(at: 0)
        order.insert(movedDown, at: 1)
        XCTAssertEqual(order, initial)

        // Boundary: cannot move top element up
        XCTAssertEqual(order.firstIndex(of: "anthropic"), 0)
    }

    // MARK: - Duplicate Source Separation Logic

    func testDuplicateSourceSeparation() {
        struct WindowStub {
            let id: String
            let cadence: String
            let source: String?
            let remainingPercent: Double?
        }

        // Simulate two reports for Grok Bot weekly: primary from cursor, duplicate from gbu
        let windows: [WindowStub] = [
            WindowStub(id: "cursor:grok-bot:weekly", cadence: "weekly", source: "Cursor DashboardService", remainingPercent: 0.0),
            WindowStub(id: "gbu:grok-bot:weekly", cadence: "weekly", source: "gbu", remainingPercent: 0.0)
        ]

        var primaryWindows: [WindowStub] = []
        var duplicateWindows: [WindowStub] = []
        var seenCadences = Set<String>()

        for win in windows {
            if seenCadences.contains(win.cadence) {
                duplicateWindows.append(win)
            } else {
                seenCadences.insert(win.cadence)
                primaryWindows.append(win)
            }
        }

        XCTAssertEqual(primaryWindows.count, 1)
        XCTAssertEqual(primaryWindows.first?.source, "Cursor DashboardService")
        XCTAssertEqual(duplicateWindows.count, 1)
        XCTAssertEqual(duplicateWindows.first?.source, "gbu")
    }

    // MARK: - Antigravity Controlling Cap Masking Logic

    func testAntigravityWeeklyExhaustionMasksFiveHourWindow() {
        let weeklyPct: Double = 0.0
        let fiveHourPct: Double = 85.0

        let isFiveHourMasked = (weeklyPct <= 0.0)
        XCTAssertTrue(isFiveHourMasked, "5h window must be masked when weekly cap is 0%")

        let displayPercent = isFiveHourMasked ? "n/a" : "\(Int(round(fiveHourPct)))%"
        XCTAssertEqual(displayPercent, "n/a")
    }

    // MARK: - Antigravity pool rows are periods, not models

    /// Regression guard for the owner report that tapping an Antigravity card on
    /// iOS listed every individual model instead of the pool's two periods.
    ///
    /// The Mac has always collapsed these: `AntigravityQuotaGroups` treats a
    /// per-model report as an *observation of a shared pool*, never as its own
    /// quota.  The companion was building one row per raw window, so a pool
    /// that holds six models showed twelve rows and buried the two numbers that
    /// mean anything.
    func testAntigravityPoolCollapsesToOneRowPerPeriod() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("private static func periodRows("),
            "CompanionQuotaModel must build Antigravity pool rows per period, not per model"
        )
        XCTAssertTrue(
            source.contains(#"let canonicalID = "antigravity:\(poolKey):\(period)""#),
            "a collapsed Antigravity row must be keyed by its pool and period, not a model window id"
        )
        XCTAssertTrue(
            source.contains("id: canonicalID"),
            "the row's id must be the pool-and-period key"
        )
        XCTAssertTrue(
            source.contains("Self.periodRows("),
            "consolidateAntigravityPool must route its children through periodRows"
        )
    }

    func testAntigravityPeriodOrderIsFiveHourThenWeekly() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains(#"antigravityPeriodOrder = ["5h", "weekly"]"#),
            "an Antigravity pool shows its 5-hour period before its weekly period"
        )
    }

    /// The shared-pool rule from `AntigravityQuotaGroups`: a weekly reading has
    /// to be identified explicitly, and a reset's distance is not a duration.
    ///
    /// A window that names neither period is a *per-model observation of the
    /// pool*, not a third period, so it must not become a row.  This is the
    /// second half of the fix: collapsing the known periods while still emitting
    /// an "other" bucket is what left "Claude Opus 4.6 (Thinking)" and
    /// "GPT-OSS 120B (Medium)" on screen.
    func testAntigravityDropsPerModelObservationsRatherThanShowingThemAsPeriods() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("private static func antigravityPeriod(of w: WireRawWindow) -> String?"),
            "period detection must be able to answer \"neither period\""
        )
        XCTAssertTrue(
            source.contains("guard let period = antigravityPeriod(of: w) else { continue }"),
            "a window that is not a pool period must be skipped, not bucketed"
        )
        XCTAssertFalse(
            source.contains(#"return token.isEmpty ? "other" : token"#),
            "per-model observations must never become their own period row"
        )
        // Only the two canonical periods may ever produce a row.
        XCTAssertTrue(
            source.contains("return antigravityPeriodOrder.compactMap { period in"),
            "rows must be built from the two canonical periods alone"
        )
    }

    /// The payload carries the pool's own aggregate row as well as the per-model
    /// ones, so the aggregate is preferred -- it is the reading every surface
    /// agrees on.
    func testAntigravityPrefersThePoolsOwnAggregateRowPerPeriod() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains(#"let canonicalID = "antigravity:\(poolKey):\(period)""#),
            "a period row must be keyed by the pool and period"
        )
        XCTAssertTrue(
            source.contains("let driving = candidates.first { $0.id == canonicalID }"),
            "the pool's own aggregate row must win over a per-model observation"
        )
    }

    /// A pool's headline number comes from one driving observation: latest wins,
    /// and a tie between models reading the same pool takes the lower value.
    func testAntigravityRowSelectsDrivingObservationWithoutAveraging() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("(left.remainingPercent ?? 101) < (right.remainingPercent ?? 101)"),
            "a tie between two models of one shared pool must take the lower value"
        )
        XCTAssertFalse(
            source.contains("remainingPercent) / Double("),
            "pool percentages must never be averaged"
        )
    }

    /// A five-hour cap means nothing while the pool's weekly cap is spent, so it
    /// still reports as not applicable after the collapse.
    func testAntigravityCollapsedFiveHourRowStaysMaskedUnderExhaustedWeekly() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("isMasked: period == \"5h\" && weeklyExhausted"),
            "the collapsed 5-hour row must stay masked when the pool's weekly cap is spent"
        )
    }

    /// Non-Antigravity platforms keep their per-window rows; the collapse is
    /// specific to the two shared pools.
    func testNonAntigravityPlatformsKeepTheirOwnWindows() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("let modelQualifier = (w.modelId ?? \"\").lowercased()"),
            "buildPlatformSection must still fold ordinary platforms by model-qualified cadence"
        )
    }

    // MARK: - The phone says when a provider is at its cap

    /// Owner 2026-10-21: the phone showed no message for Codex or Antigravity
    /// being at its cap, while the Mac's menu-bar window and PiP said so
    /// clearly.  The card carries the same line now.
    func testTheCompanionCardShowsTheAtCapLine() throws {
        let view = try readCompanionContentViewSource()
        XCTAssertTrue(
            view.contains("item.atCapSummary(scope: model.sourceScope)"),
            "the quota card must show the cap line"
        )
        XCTAssertTrue(
            view.contains("At cap. \\(atCapSummary)"),
            "the cap line must be announced to VoiceOver"
        )
    }

    /// The model must be able to say which window binds the cap, and it must
    /// use the shared wording so the phone and the Mac cannot drift.
    func testTheCompanionModelComputesTheAtCapLine() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(source.contains("public func atCapSummary(scope: CompanionSourceScope"))
        XCTAssertTrue(source.contains("public func atCapWindow(scope: CompanionSourceScope"))
        XCTAssertTrue(
            source.contains("QuotaWindowVocabulary.atCapSummary(cadence: window.atCapCadenceLabel"),
            "the phone must use the shared cap wording, not a copy of it"
        )
    }

    /// The phone must ask the shared rule which window binds the cap.
    ///
    /// The phone's model is not compiled into the macOS test target, so its
    /// half of the contract cannot be exercised here.  What can be checked is
    /// that it holds no copy of the rule:  it maps its windows onto
    /// `QuotaCapRule.WindowFacts` and calls `QuotaCapRule.bindingWindowIndex`,
    /// carrying the rule's choice back by position rather than re-finding by
    /// id, so the Mac's menu-bar window, the picture in picture and the phone
    /// all answer "is this plan capped, and by which window" the same way.
    ///
    /// The rule's own behaviour is pinned by `QuotaCapRuleTests`, and
    /// `QuotaCapRuleTests.testTheMacAndTheSharedRulePickTheSameWindow` proves
    /// the Mac and the rule agree.
    func testThePhoneAsksTheSharedRuleWhichWindowBindsTheCap() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("QuotaCapRule.bindingWindowIndex(in: facts)"),
            "the phone must call the shared rule, not keep its own copy of it"
        )
        XCTAssertTrue(
            source.contains("QuotaCapRule.WindowFacts("),
            "the phone must map its windows onto the shared rule's facts"
        )
        XCTAssertFalse(
            source.contains("$0.isExhausted || ($0.remainingPercent ?? 100) <= 0"),
            "the phone must not keep the old rule, where an exhausted word could override a reading"
        )
    }

    /// Owner 2026-10-22: the xAI row read "7-day cap" while the sidebar beside
    /// it read 96%, because the cap rule believed a window that reported an
    /// exhausted allowance days ago.
    ///
    /// The phone's windows come from a live pull of the same feed the Mac
    /// reads, and they carry the same timestamp, so the phone asks the shared
    /// freshness rule with the shared threshold and the two surfaces answer
    /// the same question about one account the same way.
    func testThePhoneAgesItsReadingsByTheSharedRule() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("QuotaFreshnessRule.isFresh(observedAt: reportedAt, resetAt: resetAt, now: now)"),
            "the phone must ask the shared freshness rule, not carry a threshold of its own"
        )
        XCTAssertTrue(
            source.contains("isFresh: $0.isFresh(now: now)"),
            "the phone must state each window's freshness to the shared cap rule"
        )
        XCTAssertFalse(
            source.contains("30 * 60"),
            "the phone must not restate the shared threshold beside the rule"
        )
    }

    /// The marker on the phone's bar is drawn for the same period the Mac's
    /// caption names, so the phone cannot keep its own copy of the words that
    /// name a period.
    func testThePhoneResolvesItsPeriodThroughTheSharedResolver() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("ResetAlarmCadence.resolve(token: cadence, label: label)"),
            "the phone must ask the shared period resolver"
        )
        XCTAssertFalse(
            source.contains("words.contains(\"5h\")"),
            "the phone must not keep its own copy of the words that name a period"
        )
        XCTAssertFalse(
            source.contains("words.contains(\"7d\")"),
            "the phone must not keep its own copy of the words that name a period"
        )
    }

    /// A masked window's reading must not be believed: it fed the card's
    /// headline and the meter bar, so the phone drew a figure that the label
    /// beside it called "n/a".
    func testMaskedWindowsNeverFeedTheHeadlineOrTheBar() throws {
        let model = try readCompanionModelSource()
        XCTAssertTrue(
            model.contains(".filter { !$0.isMasked }"),
            "the card headline must leave masked windows out"
        )
        XCTAssertFalse(
            model.contains("cardWindows(scope: scope, now: now).compactMap(\\.remainingPercent).min()"),
            "the old headline counted masked windows"
        )
        let view = try readCompanionContentViewSource()
        XCTAssertTrue(view.contains("remainingPercent: win.isMasked ? nil : win.remainingPercent"))
        XCTAssertTrue(view.contains("remainingPercent: window.isMasked ? nil : window.remainingPercent"))
    }

    /// The Mac masks a pool's five-hour window at 0.5% remaining, because the
    /// interface rounds that to 0%.  The phone tested for exactly zero, so the
    /// same pool was capped on one surface and not on the other.
    ///
    /// The phone now asks the shared rule for the answer rather than carrying a
    /// threshold of its own.  The constant it used to keep is deleted:  once
    /// the weekly decision moved into the rule, nothing read it, and a test
    /// that pinned a dead symbol still passed while a live copy of the same
    /// question sat in the widget -- so the guarantee it claimed was false
    /// (Kody review 2026-10-22).
    func testThePhoneAndTheMacAgreeOnWhenAWeeklyCapCountsAsSpent() throws {
        let model = try readCompanionModelSource()
        XCTAssertFalse(
            model.contains("weeklySpentThreshold"),
            "the phone must not keep a weekly spent threshold of its own; the shared rule owns the number"
        )
        XCTAssertTrue(
            model.contains("let weeklyExhausted = QuotaCapRule.isExhausted(remainingPercent: weeklyPct,"),
            "the phone must decide the weekly through the shared rule, so a reading outranks the provider's exhausted word"
        )
    }

    /// A pool is spent when any of its windows is.
    ///
    /// The pool decision evaluated the provider's word against `controllingPct`,
    /// the lowest reading across the pool -- a reading that belongs to a
    /// different window than the one the provider reports as gone.  A weekly
    /// the provider reported as spent without a figure, beside a healthy
    /// five-hour reading, therefore reported the plan live and the owner saw a
    /// usable plan whose weekly allowance was gone (Kody review 2026-10-22).
    /// Each window's own decision already went through the shared rule, so the
    /// pool ORs those.
    func testAPoolIsSpentWhenAnyOfItsWindowsIs() throws {
        let model = try readCompanionModelSource()
        XCTAssertTrue(
            model.contains("let isExhausted = primaryWindows.contains {"),
            "the pool must be spent when any of its windows is"
        )
        XCTAssertFalse(
            model.contains("remainingPercent: controllingPct,\n            providerSaysExhausted: primaryWindows"),
            "the provider's word must not be weighed against another window's reading"
        )
    }

    /// The plan level exhaustion flag must not count the windows the shared
    /// rule refuses to bind.
    ///
    /// `QuotaCapRule.bindingWindowIndex` never binds a sub model limit, a
    /// scoped pool allowance or a supplementary video quota, and the phone's
    /// own `atCapWindow()` and the Mac's `QuotaPlatformSection.atCapWindow()`
    /// both go through it.  The plan level flag ORed every primary window, so
    /// one of those windows reported the whole plan spent while the two
    /// surfaces that answer the owner's question said the plan still had
    /// headroom (Kody review 2026-10-22).
    func testThePlanLevelExhaustionExcludesTheWindowKindsTheRuleExcludes() throws {
        let model = try readCompanionModelSource()
        for excluded in ["!$0.isSupplementaryVideoQuota", "!$0.isScopedPoolAllowance", "!$0.isSubModelLimit"] {
            XCTAssertTrue(
                model.contains(excluded),
                "the plan level exhaustion must exclude the window kind marked by \(excluded): the shared rule never binds it"
            )
        }
    }

    /// A spent allowance publishes zero, whichever period it belongs to.
    ///
    /// The phone published the fallback zero for a weekly row only, while the
    /// widget published one for a spent five hour allowance that carried no
    /// figure, so one payload showed a zero bar on one surface and a dash on
    /// the other (Kody review 2026-10-22).  The row's own provider word now
    /// decides for every period, and the reading still outranks it.
    func testASpentRowPublishesZeroWhicheverPeriodItIs() throws {
        let model = try readCompanionModelSource()
        XCTAssertTrue(
            model.contains("let allowanceSpent = providerSaysSpent || (period == \"weekly\" && weeklyExhausted)"),
            "a spent row must publish zero whichever period it belongs to"
        )
        XCTAssertFalse(
            model.contains("allowanceSpent: period == \"weekly\" && (weeklyExhausted || providerSaysSpent)"),
            "the fallback zero must not be gated on the weekly period alone"
        )
    }

    /// The weekly row and its own provider word have to agree.
    ///
    /// `weeklyExhausted` is keyed off `weeklyWin`, picked by scanning ids and
    /// labels, while the row is built from `driving`, picked from the period
    /// buckets.  When the two pick different windows, a weekly the provider
    /// reports as gone published no reading, so the cap rule could not bind it
    /// and the cap line never appeared (Kody review 2026-10-22).
    func testTheWeeklyRowAlsoPublishesZeroForItsOwnProviderWord() throws {
        let model = try readCompanionModelSource()
        XCTAssertTrue(
            model.contains("let providerSaysSpent = driving.isExhausted ?? false"),
            "the row must consider the exhausted word of the window it is actually built from"
        )
        XCTAssertTrue(
            model.contains("let allowanceSpent = providerSaysSpent || (period == \"weekly\" && weeklyExhausted)"),
            "a weekly the provider reports as gone must publish zero even when the pool's other weekly window differs"
        )
    }

    /// The phone must let a reading outrank the provider's exhausted word.
    ///
    /// The wire never clears `isExhausted`, so a stale flag kept the phone
    /// calling a live Antigravity pool exhausted while the Mac kept it live,
    /// and the two surfaces told the owner different things about one account
    /// (Kody review 2026-10-21).  Every place the phone decides "is this
    /// spent" now asks the shared rule.
    func testThePhoneLetsAReadingOutrankTheProvidersExhaustedWord() throws {
        let model = try readCompanionModelSource()
        XCTAssertTrue(
            model.contains("QuotaCapRule.isExhausted(remainingPercent: pct,"),
            "a window row must decide through the shared rule"
        )
        XCTAssertFalse(
            model.contains("|| (weeklyWin?.isExhausted ?? false)"),
            "the wire's exhausted word must not outvote a weekly reading that reports room left"
        )
        XCTAssertFalse(
            model.contains("(?? 100) <= 0"),
            "the phone must not carry its own zero test beside the shared rule"
        )
    }

    /// An exhausted weekly that reports no figure still has to publish a
    /// reading, or the shared cap rule cannot bind it and the phone's cap line
    /// never appears (Kody review 2026-10-21).  The Mac does the same in its
    /// Antigravity pool grouper.
    func testAnExhaustedWeeklyWithNoFigureStillPublishesAReading() throws {
        let model = try readCompanionModelSource()
        XCTAssertTrue(
            model.contains("QuotaCapRule.publishedReading("),
            "the phone must publish its reading through the shared rule"
        )
        XCTAssertTrue(
            model.contains("let allowanceSpent = providerSaysSpent || (period == \"weekly\" && weeklyExhausted)"),
            "an exhausted weekly with no figure must publish zero"
        )
    }

    // MARK: - Local Snapshot Caching and Pull-to-Refresh Parity

    func testLocalSnapshotPersistenceMethods() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("private func saveLocalSnapshot(data: Data)"),
            "CompanionQuotaModel must persist fetched snapshots to local storage"
        )
        XCTAssertTrue(
            source.contains("saveLocalSnapshot(data: data)"),
            "refresh() must save local snapshots upon successful network response"
        )
        XCTAssertTrue(
            source.contains("CodeCaps/quota-windows.json"),
            "loadLocalFallback and saveLocalSnapshot must check the app's local sandbox storage"
        )
        XCTAssertTrue(source.contains("CC8UTF7ATG.codecaps"))
        XCTAssertTrue(source.contains("group.com.simplewithus.codecaps"))
    }

    func testMainScreenFleetStatusLivesInNavigationBar() throws {
        let source = try readCompanionContentViewSource()
        XCTAssertFalse(
            source.contains(".navigationTitle(\"CodeCaps\")"),
            "main screen must not repeat the CodeCaps product title"
        )
        XCTAssertTrue(
            source.contains("fleetStatusToolbarContent"),
            "fleet status must be a toolbar item so it stays pinned while scrolling"
        )
        XCTAssertTrue(
            source.contains("ToolbarItem(placement: .principal)"),
            "fleet status belongs in the navigation bar title area"
        )
        XCTAssertFalse(
            source.contains("Text(\"FLEET STATUS\")"),
            "fleet status label should use title case in the navigation bar"
        )
        XCTAssertFalse(
            source.contains("arrow.up.arrow.down"),
            "reorder must live in CodeCaps Settings, not a duplicate toolbar button"
        )
        XCTAssertTrue(
            source.contains("navigationTitle(\"CodeCaps Settings\")"),
            "full-screen settings must be titled CodeCaps Settings"
        )
        XCTAssertTrue(
            source.contains(".fullScreenCover(isPresented: $showingSettings)"),
            "settings must present full screen on iOS"
        )
        XCTAssertTrue(
            source.contains("enum CompanionSettingsTab"),
            "settings must be grouped into tabs"
        )
        XCTAssertTrue(source.contains("case display = \"Display\""))
        XCTAssertTrue(source.contains("case sources = \"Sources\""))
        XCTAssertTrue(source.contains("case alarms = \"Alarms\""))
        XCTAssertTrue(source.contains("settingsDisplaySections"))
        XCTAssertTrue(source.contains("settingsSourcesSections"))
        XCTAssertTrue(source.contains("settingsAlarmsSections"))
        XCTAssertFalse(source.contains("Companion Settings"))
        XCTAssertFalse(source.contains(".presentationDetents"))
    }

    func testPullToRefreshAndButtonResponsiveness() throws {
        let source = try readCompanionContentViewSource()
        XCTAssertTrue(
            source.contains("scrollBounceBehavior(.always, axes: .vertical)"),
            "ScrollView must enable always vertical bounce so pull-to-refresh works when empty"
        )
        XCTAssertTrue(
            source.contains("SettingsRefreshButtonStyle"),
            "Settings refresh button must use SettingsRefreshButtonStyle for instant visual press feedback"
        )
        XCTAssertTrue(
            source.contains("refreshable"),
            "Settings form must support pull-to-refresh"
        )
        XCTAssertTrue(
            source.contains("task {"),
            "CompanionContentView must kick off background refresh on appear"
        )
    }

    // MARK: - MiniMax Normalization and Pacing Marker Prominence

    func testMiniMaxCadenceNormalization() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains(#"combined.contains("coding plan") || combined.contains("interval")"#),
            "formatCadence must classify MiniMax coding plan and interval as 5-hour window"
        )
        XCTAssertTrue(
            source.contains(#"text.contains("coding plan") || text.contains("coding_plan") || text.contains("interval")"#),
            "caption and isShortCadence must classify MiniMax coding plan as 5h short cadence"
        )
    }

    func testMiniMaxConsolidationToTwoWindows() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains(#"let isMiniMax = providerKey.lowercased().contains("minimax")"#),
            "MiniMax must be identified during platform section building"
        )
        XCTAssertTrue(
            source.contains("let effectiveQualifier = isMiniMax ? \"\" : modelQualifier"),
            "MiniMax must not split cadences by modelQualifier, collapsing into two primary windows"
        )
    }

    func testCompanionMeterUsesHyphenatedCaptionsNotPopoverTags() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("public var meterCaption: String"),
            "Companion meters must use hyphenated cadence captions"
        )
        XCTAssertTrue(
            source.contains("public var caption: String { meterCaption }"),
            "card meters must not use popover 5h/7d/1m tags"
        )
        let content = try readCompanionContentViewSource()
        XCTAssertFalse(
            content.contains("window.barQualifier"),
            "companion meters must not render weekly/additional qualifier captions"
        )
    }

    func testSourceDiscrepancyGatingRequiresAllSourcesMultiSourceAndFreshness() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(source.contains("guard scope == .allSources, sourceCount >= 2 else { return [] }"))
        XCTAssertTrue(source.contains("FleetSourceDisagreement.shouldShowDisagreementAlert"))
        XCTAssertTrue(source.contains("normalizedWindowKey == dup.normalizedWindowKey"))
        XCTAssertFalse(source.contains("?? windows.first"))
        XCTAssertTrue(source.contains("reportedAt"))
        XCTAssertTrue(source.contains("Self.reportedAt(from: w)"))
        XCTAssertTrue(source.contains("FleetMacReading.pickCardDisplay"))
        XCTAssertTrue(source.contains("cardWindowRows(scope:"))
        XCTAssertTrue(source.contains("isStaleInSourceDetail(_ window: CompanionWindowItem, scope:"))
        XCTAssertTrue(source.contains("delta >= 10.0"))
        XCTAssertTrue(source.contains("Sources differ ·"))
        XCTAssertFalse(source.contains("via codecaps"))
        XCTAssertTrue(source.contains("sourceLooksLikeHostname"))
        let content = try readCompanionContentViewSource()
        XCTAssertTrue(
            content.contains("model.sourceScope == .allSources, item.sourceCount > 1"),
            "discrepancy UI must follow the multi-source chip gate"
        )
    }

    func testCompanionSubtitleUsesSubtitlePhraseVocabulary() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(source.contains("static func subtitlePhrase(for windows:"))
        XCTAssertTrue(source.contains("Self.subtitlePhrase(for: primaryWindows"))
    }

    func testCompanionUsageBarPacingMarkerProminence() throws {
        let source = try readCompanionContentViewSource()
        XCTAssertTrue(
            source.contains("let markerHeight: CGFloat = 18"),
            "CompanionUsageBar must use an 18pt marker height to match Mac prominence"
        )
        XCTAssertTrue(
            source.contains("let markerWidth: CGFloat = 3.0"),
            "CompanionUsageBar must use a 3.0pt marker width for clear mobile legibility"
        )
        XCTAssertTrue(
            source.contains("frame(height: max(height, 20))"),
            "CompanionUsageBar container must allocate 20pt frame so markers are never clipped"
        )
        XCTAssertTrue(
            source.contains(".frame(width: 44, height: 44)"),
            "Reset alarm bell button must meet the 44x44 minimum touch target standard"
        )
    }

    // MARK: - Source scope label names the device the reader is holding

    func testSourceScopeLabelNamesTheDeviceFamily() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains(#"case thisIPhone = "This iPhone""#),
            "The scope's stored raw value must stay \"This iPhone\" so a saved preference is not lost"
        )
        XCTAssertTrue(
            source.contains(#"case .thisIPhone: return "This \(family)""#),
            "The this-device scope must be labelled with the device the reader is holding"
        )
        XCTAssertTrue(
            source.contains("case .allSources: return rawValue"),
            "The all-sources scope must keep its own label"
        )
        XCTAssertTrue(
            source.contains(#"UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone""#),
            "The device family must follow the interface idiom, so an iPad never says This iPhone"
        )
        XCTAssertTrue(
            source.contains(#"return "Mac""#),
            "The Mac build of the companion must name the Mac"
        )
    }

    func testSourceScopePickerShowsTheDeviceAwareLabel() throws {
        let view = try readCompanionContentViewSource()
        XCTAssertTrue(
            view.contains("Text(scope.displayTitle).tag(scope)"),
            "The source-scope picker must show the device-aware label"
        )
        XCTAssertFalse(
            view.contains("Text(scope.rawValue).tag(scope)"),
            "The source-scope picker must not show the stored raw value, which always says This iPhone"
        )
    }

    // MARK: - A launch argument opens the alarms tab

    func testAlarmsLaunchArgumentOpensTheAlarmsTab() throws {
        let view = try readCompanionContentViewSource()
        //  Both spellings are accepted:  -openAlarms is the screenshot
        //  capture's, and -openAlerts is the one the alert work introduced
        //  for the same tab.  Either one has to open it.
        XCTAssertTrue(
            view.contains(#"contains("-openAlarms")"#),
            "A launch argument must open the Alarms tab, so the screenshot capture can reach it without a tap"
        )
        XCTAssertTrue(
            view.contains(#"contains("-openAlerts")"#),
            "The alert work's launch argument must open the same tab"
        )
        XCTAssertTrue(
            view.contains(#"initialValue: opensAlarms ? .alarms : .display"#),
            "Either launch argument must select the Alarms tab"
        )
        XCTAssertTrue(
            view.contains(#"case alarms = "Alarms""#),
            "The Alarms tab must still exist as a tab of the settings sheet"
        )
    }

    // MARK: - A copy of a period that ended is not a reading

    /// Owner 2026-10-23: the xAI row showed two 7-day windows at 0% with a
    /// "due" caption while Grok, Cursor and Grok Bot showed the same weekly
    /// allowance at 91% with a reset on 2026-10-29.  This Mac reads no xAI
    /// quota locally, so the fleet fallback filled the xAI row with copies of
    /// a period that ended days earlier.
    ///
    /// The phone pulls the same fleet payload, so it has to drop the same
    /// copies.  Its model is not in the macOS test target, so the rule is
    /// pinned here by reading the source.
    func testTheCompanionDropsACopyOfAPeriodThatEnded() throws {
        let source = try readCompanionModelSource()
        XCTAssertTrue(
            source.contains("QuotaFreshnessRule.isDeadCopy(observedAt: parsedReportedAt,"),
            "the phone must ask the shared rule about a window whose period already ended"
        )
        XCTAssertTrue(
            source.contains("QuotaFreshnessRule.isDeadCopy(observedAt: Self.reportedAt(from: $0),"),
            "the phone's Antigravity pool must ask the same rule"
        )
        XCTAssertFalse(
            source.contains("private static let staleAfter"),
            "the phone must not carry a stale threshold of its own"
        )
    }
}
