import XCTest
@testable import QuotaCore

final class UnifiedSubscriptionPoolTests: XCTestCase {
    private let iso = ISO8601DateFormatter()
    private let now = Date()

    private func makeWindow(providerKey: String, id: String, rem: Double?, resetIn: TimeInterval = 86400 * 6, observedAgo: TimeInterval = 60) -> QuotaWindow {
        QuotaWindow(
            id: id,
            provider: QuotaProviders.label(for: providerKey),
            providerKey: providerKey,
            providerLabel: QuotaProviders.label(for: providerKey),
            sourceApp: id.hasPrefix("local-mac:") ? "local-mac" : nil,
            label: "Subscription window",
            remainingPercent: rem,
            resetAt: iso.string(from: now.addingTimeInterval(resetIn)),
            window: "weekly",
            occurredAt: iso.string(from: now.addingTimeInterval(-observedAgo)),
            source: QuotaProviders.label(for: providerKey)
        )
    }

    func testCursorReadingPopulatesXaiGrokAndGrokBot() {
        let cursor = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 31.5)
        let windows = [cursor]

        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now, targetKeys: UnifiedSubscriptionPool.participantKeys)
        let byProvider = Dictionary(grouping: shared, by: \.canonicalProviderKey)

        XCTAssertNotNil(byProvider["xai"]?.first, "xAI must receive an adapted pool window")
        XCTAssertEqual(byProvider["xai"]?.first?.remainingPercent, 31.5)
        XCTAssertEqual(byProvider["xai"]?.first?.id, "local-mac:xai:subscription")

        XCTAssertNotNil(byProvider["grok"]?.first, "Grok must receive an adapted pool window")
        XCTAssertEqual(byProvider["grok"]?.first?.remainingPercent, 31.5)

        XCTAssertNotNil(byProvider["grok-bot"]?.first, "Grok Bot must receive an adapted pool window")
        XCTAssertEqual(byProvider["grok-bot"]?.first?.remainingPercent, 31.5)

        XCTAssertEqual(byProvider["cursor"]?.first?.remainingPercent, 31.5)
    }

    func testGrokReadingPopulatesCursorXaiAndGrokBot() {
        let grok = makeWindow(providerKey: "grok", id: "local-mac:grok:subscription", rem: 50.0)
        let windows = [grok]

        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now, targetKeys: UnifiedSubscriptionPool.participantKeys)
        let byProvider = Dictionary(grouping: shared, by: \.canonicalProviderKey)

        XCTAssertEqual(byProvider["cursor"]?.first?.remainingPercent, 50.0)
        XCTAssertEqual(byProvider["xai"]?.first?.remainingPercent, 50.0)
        XCTAssertEqual(byProvider["grok-bot"]?.first?.remainingPercent, 50.0)
        XCTAssertEqual(byProvider["grok"]?.first?.remainingPercent, 50.0)
    }

    func testGrokBotReadingPopulatesCursorXaiAndGrok() {
        let grokBot = makeWindow(providerKey: "grok-bot", id: "local-mac:grok-bot:weekly", rem: 42.0)
        let windows = [grokBot]

        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now, targetKeys: UnifiedSubscriptionPool.participantKeys)
        let byProvider = Dictionary(grouping: shared, by: \.canonicalProviderKey)

        XCTAssertEqual(byProvider["cursor"]?.first?.remainingPercent, 42.0)
        XCTAssertEqual(byProvider["xai"]?.first?.remainingPercent, 42.0)
        XCTAssertEqual(byProvider["grok"]?.first?.remainingPercent, 42.0)
    }

    func testXaiReadingPopulatesCursorGrokAndGrokBot() {
        let xai = makeWindow(providerKey: "xai", id: "xai:subscription", rem: 88.0)
        let windows = [xai]

        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now, targetKeys: UnifiedSubscriptionPool.participantKeys)
        let byProvider = Dictionary(grouping: shared, by: \.canonicalProviderKey)

        XCTAssertEqual(byProvider["cursor"]?.first?.remainingPercent, 88.0)
        XCTAssertEqual(byProvider["grok"]?.first?.remainingPercent, 88.0)
        XCTAssertEqual(byProvider["grok-bot"]?.first?.remainingPercent, 88.0)
    }

    func testFreshestReadingWinsAmongMultipleParticipants() {
        let olderCursor = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 60.0, observedAgo: 3600)
        let newerGrok = makeWindow(providerKey: "grok", id: "local-mac:grok:subscription", rem: 55.0, observedAgo: 60)
        let windows = [olderCursor, newerGrok]

        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now, targetKeys: UnifiedSubscriptionPool.participantKeys)
        let byProvider = Dictionary(grouping: shared, by: \.canonicalProviderKey)

        // The 55.0% reading is fresher (60s ago vs 3600s ago)
        XCTAssertEqual(byProvider["cursor"]?.first?.remainingPercent, 55.0)
        XCTAssertEqual(byProvider["xai"]?.first?.remainingPercent, 55.0)
        XCTAssertEqual(byProvider["grok"]?.first?.remainingPercent, 55.0)
        XCTAssertEqual(byProvider["grok-bot"]?.first?.remainingPercent, 55.0)
    }

    func testStaleReadingIsOverwrittenByFreshReading() {
        let staleXai = makeWindow(providerKey: "xai", id: "xai:subscription", rem: 10.0, observedAgo: 86400 * 2)
        let freshCursor = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 75.0, observedAgo: 120)
        let windows = [staleXai, freshCursor]

        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now)
        let byProvider = Dictionary(grouping: shared, by: \.canonicalProviderKey)

        XCTAssertEqual(byProvider["xai"]?.first?.remainingPercent, 75.0, "xAI stale reading must be updated by fresh Cursor reading")
        XCTAssertEqual(byProvider["cursor"]?.first?.remainingPercent, 75.0)
    }

    func testApiCreditsAreNotPartOfTheSubscriptionPool() {
        let apiWindow = QuotaWindow(
            id: "xai:api-monthly",
            provider: "xAI",
            providerKey: "xai",
            providerLabel: "xAI",
            label: "API credits",
            remainingPercent: 12.0,
            occurredAt: iso.string(from: now)
        )
        let cursor = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 80.0)
        let windows = [apiWindow, cursor]

        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now)
        let apiResult = shared.first { $0.id == "xai:api-monthly" }

        XCTAssertEqual(apiResult?.remainingPercent, 12.0, "API credits window must remain untouched")
        XCTAssertEqual(apiResult?.label, "API credits")
    }

    func testBillingCycleAndCurrencyWindowsAreExcludedFromPool() {
        var billingWindow = makeWindow(providerKey: "cursor", id: "cursor:billing-cycle", rem: 5.0)
        billingWindow.label = "Billing cycle spend"
        billingWindow.quotaUnit = "USD"
        let cursorPlan = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 90.0)
        let windows = [billingWindow, cursorPlan]

        XCTAssertFalse(UnifiedSubscriptionPool.isPoolWindow(billingWindow), "Billing cycle window must not be considered a pool window")
        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now)
        let preservedBilling = shared.first { $0.id == "cursor:billing-cycle" }
        XCTAssertEqual(preservedBilling?.remainingPercent, 5.0, "Billing cycle window must remain untouched")
    }

    func testMultiAccountWindowsAreExcludedFromPool() {
        var accountWindow = makeWindow(providerKey: "grok-bot", id: "gbu-weekly:account-123", rem: 15.0)
        accountWindow.label = "Account allowance"
        let cursorPlan = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 88.0)
        let windows = [accountWindow, cursorPlan]

        XCTAssertFalse(UnifiedSubscriptionPool.isPoolWindow(accountWindow), "Multi-account window must not be considered a pool window")
        let shared = UnifiedSubscriptionPool.share(windows: windows, now: now)
        let preservedAccount = shared.first { $0.id == "gbu-weekly:account-123" }
        XCTAssertEqual(preservedAccount?.remainingPercent, 15.0, "Multi-account window must remain untouched")
    }
    func testAbsoluteOnlyDonorDoesNotErasePercentage() {
        var absoluteOnly = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: nil, observedAgo: 1)
        absoluteOnly.absoluteRemaining = 100
        let xai = makeWindow(providerKey: "xai", id: "xai:subscription", rem: 60, observedAgo: 60)
        let shared = UnifiedSubscriptionPool.share(windows: [absoluteOnly, xai], now: now)
        XCTAssertEqual(shared.first { $0.canonicalProviderKey == "xai" }?.remainingPercent, 60)
        XCTAssertEqual(UnifiedSubscriptionPool.freshestReading(in: [absoluteOnly, xai], now: now)?.id, xai.id)
    }

    func testRemoteAdaptationPreservesOrigin() {
        var remote = makeWindow(providerKey: "cursor", id: "studio:cursor:plan", rem: 55)
        remote.sourceApp = "codecaps"
        remote.source = "studio"
        let adapted = UnifiedSubscriptionPool.adapt(remote, for: "xai")
        XCTAssertNotEqual(adapted.id, remote.id)
        XCTAssertFalse(adapted.id.hasPrefix("local-mac:"))
        XCTAssertTrue(adapted.id.hasSuffix(":xai:subscription"))
        XCTAssertEqual(adapted.sourceApp, remote.sourceApp)
        XCTAssertEqual(adapted.source, remote.source)
        XCTAssertEqual(adapted.canonicalProviderKey, "xai")
    }

    func testRemoteLocalStyleIDIsNotRelabeledAsThisMac() {
        var remote = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 55)
        remote.sourceApp = "codecaps"
        remote.machine = "Studio"
        let adapted = UnifiedSubscriptionPool.adapt(remote, for: "xai")
        XCTAssertNotEqual(adapted.id, remote.id)
        XCTAssertFalse(adapted.id.hasPrefix("local-mac:"))
        XCTAssertTrue(adapted.id.hasSuffix(":xai:subscription"))
        XCTAssertEqual(adapted.machine, remote.machine)
        XCTAssertEqual(adapted.sourceApp, remote.sourceApp)
    }

    func testRemoteIDsUseURLSafeNonemptyProvenance() {
        // The id ends up in cache keys, file names, URLs and alert keys, so
        // the encoding has to be safe in all of them.
        var remote = makeWindow(providerKey: "cursor", id: "studio:cursor:plan", rem: 55)
        remote.producerInstanceId = "studio/instance+1="
        remote.sourceApp = "codecaps"
        let adapted = UnifiedSubscriptionPool.adapt(remote, for: "xai")
        let key = adapted.id.replacingOccurrences(of: "shared-pool:", with: "")
        let encoded = key.components(separatedBy: ":").dropLast().joined(separator: ":")
        XCTAssertFalse(encoded.contains("/"))
        XCTAssertFalse(encoded.contains("+"))
        XCTAssertFalse(encoded.contains("="))

        // An empty provenance field is not an identity, so two donors that
        // both leave it blank must not collapse onto one id.
        var first = makeWindow(providerKey: "cursor", id: "studio:cursor:plan", rem: 55)
        first.producerInstanceId = ""
        first.machine = ""
        first.source = ""
        first.sourceApp = "codecaps"
        var second = makeWindow(providerKey: "cursor", id: "other:cursor:plan", rem: 55)
        second.producerInstanceId = ""
        second.machine = ""
        second.source = ""
        second.sourceApp = "codecaps"
        let firstID = UnifiedSubscriptionPool.adapt(first, for: "xai").id
        let secondID = UnifiedSubscriptionPool.adapt(second, for: "xai").id
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertFalse(firstID.contains("shared-pool::"))
        XCTAssertFalse(secondID.contains("shared-pool::"))
        XCTAssertTrue(firstID.hasPrefix("shared-pool:"))
    }

    func testRemoteSharedParticipantsHaveUniqueTargetIDsAndPreserveProvenance() {
        var remote = makeWindow(providerKey: "cursor", id: "studio:cursor:plan", rem: 55)
        remote.producerInstanceId = "studio-instance"
        remote.machine = "Studio"
        remote.source = "studio"
        remote.sourceApp = "codecaps"
        let shared = UnifiedSubscriptionPool.share(windows: [remote], now: now,
                                                   targetKeys: UnifiedSubscriptionPool.participantKeys)
        XCTAssertEqual(Set(shared.map(\.id)).count, 4)
        for window in shared where window.canonicalProviderKey != "cursor" {
            XCTAssertFalse(window.id.hasPrefix("local-mac:"))
            XCTAssertFalse(window.id.contains(":cursor:"))
            XCTAssertTrue(window.id.contains(":\(window.canonicalProviderKey):"))
            XCTAssertEqual(window.producerInstanceId, remote.producerInstanceId)
            XCTAssertEqual(window.machine, remote.machine)
            XCTAssertEqual(window.source, remote.source)
            XCTAssertEqual(window.sourceApp, remote.sourceApp)
            XCTAssertEqual(window.remainingPercent, 55)
        }
    }

    func testMissingSourceAppIsNotInventedDuringAdaptation() {
        let remote = makeWindow(providerKey: "grok", id: "server:grok:subscription", rem: 55)
        XCTAssertNil(UnifiedSubscriptionPool.adapt(remote, for: "cursor").sourceApp)
    }

    // MARK: - The origin does not flap between rounds

    func testTheOriginDoesNotFlapWhenAFilledInRowIsElectedAsTheDonor() {
        // A remote producer fills the pool in.  On the next round the row it
        // filled in is the freshest reading left, and the origin that row
        // hands on must still name the producer rather than the row's own
        // collector.
        var localXai = makeWindow(providerKey: "xai", id: "local-mac:xai:subscription",
                                  rem: 20, observedAgo: 600)
        localXai.producerInstanceId = "local-instance"
        var remote = makeWindow(providerKey: "cursor", id: "studio:cursor:plan", rem: 55, observedAgo: 60)
        remote.producerInstanceId = "studio-instance"
        remote.machine = "Studio"
        remote.source = "studio"
        remote.sourceApp = "codecaps"

        let first = UnifiedSubscriptionPool.share(windows: [localXai, remote], now: now,
                                                  targetKeys: UnifiedSubscriptionPool.participantKeys)
        let filledXai = first.first { $0.canonicalProviderKey == "xai" }
        XCTAssertEqual(filledXai?.sharedPoolOrigin, "studio-instance")
        XCTAssertEqual(filledXai?.producerInstanceId, "local-instance")

        // The producer has gone quiet, so the row it filled in is the
        // freshest reading the pool has.
        let second = UnifiedSubscriptionPool.share(
            windows: first.filter { $0.canonicalProviderKey == "xai" },
            now: now.addingTimeInterval(1),
            targetKeys: UnifiedSubscriptionPool.participantKeys
        )
        let injectedGrokBot = second.first { $0.canonicalProviderKey == "grok-bot" }
        XCTAssertEqual(injectedGrokBot?.sharedPoolOrigin, "studio-instance")
        XCTAssertNotEqual(injectedGrokBot?.sharedPoolOrigin, "local-instance")
        // The row that was filled in and the row the pool injected now name
        // the same producer.
        XCTAssertEqual(injectedGrokBot?.sharedPoolOrigin, filledXai?.sharedPoolOrigin)
    }

    func testTheOriginOfAFilledInRowNamesTheProducerAndNotItsOwnCollector() {
        // A row the pool filled in hands on the producer's name, so a row the
        // pool builds from it names the same producer.
        var localXai = makeWindow(providerKey: "xai", id: "local-mac:xai:subscription",
                                  rem: 20, observedAgo: 600)
        localXai.producerInstanceId = "local-instance"
        var remote = makeWindow(providerKey: "cursor", id: "studio:cursor:plan", rem: 55, observedAgo: 60)
        remote.producerInstanceId = "studio-instance"
        remote.sourceApp = "codecaps"

        let first = UnifiedSubscriptionPool.share(windows: [localXai, remote], now: now,
                                                  targetKeys: UnifiedSubscriptionPool.participantKeys)
        let filledXai = first.first { $0.canonicalProviderKey == "xai" }
        XCTAssertEqual(UnifiedSubscriptionPool.poolOrigin(of: filledXai!), "studio-instance")
        XCTAssertNotEqual(UnifiedSubscriptionPool.poolOrigin(of: filledXai!), "local-instance")
        // The row the pool builds from it names the same producer.
        let injected = UnifiedSubscriptionPool.adapt(filledXai!, for: "grok-bot")
        XCTAssertEqual(injected.sharedPoolOrigin, "studio-instance")
        XCTAssertEqual(injected.sharedPoolOrigin, filledXai?.sharedPoolOrigin)
    }

    func testAnOriginThatIsOnlyBlankIsNotAnIdentity() {
        // A row the pool filled in can carry a blank origin, and a blank
        // field is not an identity.
        var filled = makeWindow(providerKey: "xai", id: "local-mac:xai:subscription", rem: 20)
        filled.producerInstanceId = "local-instance"
        filled.sharedPoolOrigin = "   "
        XCTAssertEqual(UnifiedSubscriptionPool.poolOrigin(of: filled), "local-instance")
    }

    // MARK: - The pool window is named by its id, in full

    /// The pool window is identified by an exact id, never by a substring of
    /// one.
    ///
    /// The old rule tested the id for words like "api" and "account", so an id
    /// that merely started with a pool token joined the pool, and a window
    /// nobody could name stood in for the pool reading.
    func testAnIdThatOnlyStartsWithAPoolTokenIsNotAPoolWindow() {
        let lookalike = makeWindow(providerKey: "grok", id: "local-mac:grok:subscription-extra", rem: 12)
        XCTAssertFalse(UnifiedSubscriptionPool.isPoolWindow(lookalike),
                       "an id that only starts with a pool token is not the pool window")
    }

    /// Cursor's plan spend meter carries the pool's own window id and the
    /// pool's own label.  The billing cycle is what tells the two apart.
    func testABillingCycleWindowIsNotAPoolWindowEvenWithoutACurrencyUnit() {
        var billing = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 12)
        billing.label = "Included plan"
        billing.window = "billing-cycle"
        XCTAssertFalse(UnifiedSubscriptionPool.isPoolWindow(billing),
                       "a billing cycle is not the included pool")
    }

    /// A per-account allowance is a separate quota, and it must never be
    /// overwritten by the pool's reading.
    func testAPerAccountAllowanceStaysOutOfThePool() {
        var account = makeWindow(providerKey: "grok-bot", id: "local-mac:grok-bot:gbu-weekly:alice", rem: 12)
        account.label = "Grok Bot weekly (alice)"
        XCTAssertFalse(UnifiedSubscriptionPool.isPoolWindow(account),
                       "a per-account allowance is not the pool window")
    }

    /// The plan details window carries no reading at all.
    func testThePlanDetailsWindowStaysOutOfThePool() {
        let details = QuotaWindow(
            id: "local-mac:xai:plan-metadata",
            provider: "xAI",
            providerKey: "xai",
            providerLabel: "xAI",
            label: "Plan Details",
            remainingUnknown: true,
            occurredAt: iso.string(from: now),
            source: "CodeCaps Settings"
        )
        XCTAssertFalse(UnifiedSubscriptionPool.isPoolWindow(details))
    }

    /// The pool's own windows are still in the pool.
    func testTheCanonicalPoolWindowsArePoolWindows() {
        XCTAssertTrue(UnifiedSubscriptionPool.isPoolWindow(makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 40)))
        XCTAssertTrue(UnifiedSubscriptionPool.isPoolWindow(makeWindow(providerKey: "grok", id: "local-mac:grok:subscription", rem: 40)))
        XCTAssertTrue(UnifiedSubscriptionPool.isPoolWindow(makeWindow(providerKey: "xai", id: "xai:subscription", rem: 40)))
        XCTAssertTrue(UnifiedSubscriptionPool.isPoolWindow(makeWindow(providerKey: "grok-bot", id: "local-mac:grok-bot:weekly", rem: 40)))
        XCTAssertTrue(UnifiedSubscriptionPool.isPoolWindow(makeWindow(providerKey: "grok-bot", id: "local-mac:grok-bot:gbu-weekly", rem: 40)))
    }

    // MARK: - One name for the pool

    /// Every participant is named with the same token, because that is the
    /// token the rest of the app reads the pool by.
    ///
    /// `UsageMonitorPushMetadata.bucketId` files an xAI window under the
    /// `xai:subscription` bucket only when the id's suffix is exactly
    /// `subscription`, and `QuotaResponse.dedupedGrokSubscription` pairs a
    /// Grok row with an xAI row only when both ids end in `:subscription`.
    func testEveryParticipantIsNamedWithTheSubscriptionToken() {
        XCTAssertEqual(UnifiedSubscriptionPool.canonicalWindowId(for: "cursor"), "local-mac:cursor:subscription")
        XCTAssertEqual(UnifiedSubscriptionPool.canonicalWindowId(for: "xai"), "local-mac:xai:subscription")
        XCTAssertEqual(UnifiedSubscriptionPool.canonicalWindowId(for: "grok"), "local-mac:grok:subscription")
        XCTAssertEqual(UnifiedSubscriptionPool.canonicalWindowId(for: "grok-bot"), "local-mac:grok-bot:subscription")
    }

    /// The xAI participant row lands in the Usage Monitor bucket the fleet's
    /// xAI collector writes, so the pool is one bucket and not two.
    func testTheXaiParticipantRowLandsInTheXaiSubscriptionBucket() throws {
        let cursor = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 31.5)
        let shared = UnifiedSubscriptionPool.share(windows: [cursor], now: now,
                                                   targetKeys: UnifiedSubscriptionPool.participantKeys)
        let xai = try XCTUnwrap(shared.first { $0.canonicalProviderKey == "xai" })
        XCTAssertEqual(UsageMonitorPushMetadata.bucketId(for: xai), "xai:subscription")
    }

    // MARK: - The pool's own rows are not duplicates of each other

    /// The Grok row and the xAI row of one shared pool must both survive the
    /// Grok/xAI dedupe.
    ///
    /// The pool stamps the donor's time on every participant, so the two rows
    /// tie, and the tie used to drop one of them from the dashboard with the
    /// live reading on it.
    func testBothPoolParticipantsSurviveTheGrokXaiDedupe() {
        let grok = makeWindow(providerKey: "grok", id: "local-mac:grok:subscription", rem: 40, observedAgo: 3600)
        let xai = makeWindow(providerKey: "xai", id: "xai:subscription", rem: 70, observedAgo: 60)
        let shared = UnifiedSubscriptionPool.share(windows: [grok, xai], now: now)

        let deduped = QuotaResponse.dedupedGrokSubscription(shared)
        XCTAssertEqual(deduped.count, 2, "the pool's own rows must not be deduped against each other")
        XCTAssertEqual(Set(deduped.map(\.canonicalProviderKey)), ["grok", "xai"])
    }

    /// Two collectors reporting the same pool are still deduped: the dedupe
    /// exists so the two rows cannot disagree about one pool.
    func testTwoCollectorsReportingOnePoolAreStillDeduped() {
        let grok = makeWindow(providerKey: "grok", id: "local-mac:grok:subscription", rem: 40, observedAgo: 3600)
        let xai = makeWindow(providerKey: "xai", id: "xai:subscription", rem: 70, observedAgo: 60)
        let deduped = QuotaResponse.dedupedGrokSubscription([grok, xai])
        XCTAssertEqual(deduped.count, 1, "two reports of one pool are still one row")
    }

    // MARK: - A donor without a value erases nothing

    /// A donor that cannot report an amount must not erase the target's own.
    ///
    /// `freshestReading` only accepts a donor with a bounded percentage, so
    /// the percentage is always there, but the absolute amounts and the unit
    /// are not, and a target that knows its own limit kept it.
    func testADonorWithoutAbsoluteValuesDoesNotEraseTheTargetsOwn() {
        var donor = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 40, observedAgo: 30)
        donor.absoluteRemaining = nil
        donor.absoluteLimit = nil
        donor.quotaUnit = nil
        var target = makeWindow(providerKey: "xai", id: "xai:subscription", rem: 10, observedAgo: 3600)
        target.absoluteRemaining = 250
        target.absoluteLimit = 500
        target.quotaUnit = "credits"

        let shared = UnifiedSubscriptionPool.share(windows: [donor, target], now: now)
        let xai = shared.first { $0.canonicalProviderKey == "xai" }
        XCTAssertEqual(xai?.remainingPercent, 40, "the pool's percentage reaches the row")
        XCTAssertEqual(xai?.absoluteRemaining, 250, "the target keeps its own remaining amount")
        XCTAssertEqual(xai?.absoluteLimit, 500, "the target keeps its own limit")
        XCTAssertEqual(xai?.quotaUnit, "credits", "the target keeps its own unit")
    }

    /// A donor that does report an amount replaces the target's.
    func testADonorWithAbsoluteValuesReplacesTheTargetsOwn() {
        var donor = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 40, observedAgo: 30)
        donor.absoluteRemaining = 40
        donor.absoluteLimit = 100
        donor.quotaUnit = "credits"
        var target = makeWindow(providerKey: "xai", id: "xai:subscription", rem: 10, observedAgo: 3600)
        target.absoluteRemaining = 250
        target.absoluteLimit = 500
        target.quotaUnit = "credits"

        let shared = UnifiedSubscriptionPool.share(windows: [donor, target], now: now)
        let xai = shared.first { $0.canonicalProviderKey == "xai" }
        XCTAssertEqual(xai?.absoluteRemaining, 40)
        XCTAssertEqual(xai?.absoluteLimit, 100)
    }

    // MARK: - Each row keeps its own collector

    /// The shared reading keeps the row's own collector name.
    ///
    /// A row that wore the donor's name was hidden from every other row when
    /// that collector was switched off in Settings, because the rows are
    /// filtered by `source`.
    func testASharedRowKeepsItsOwnCollectorName() {
        var donor = makeWindow(providerKey: "grok-bot", id: "local-mac:grok-bot:weekly", rem: 44, observedAgo: 30)
        donor.source = "gbu"
        var target = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 10, observedAgo: 3600)
        target.source = "Cursor"
        target.sourceApp = "local-mac"

        let shared = UnifiedSubscriptionPool.share(windows: [donor, target], now: now)
        let cursor = shared.first { $0.canonicalProviderKey == "cursor" }
        XCTAssertEqual(cursor?.source, "Cursor", "the row keeps the collector it names")
        XCTAssertEqual(cursor?.sourceApp, "local-mac", "the row keeps the app it was read by")
        XCTAssertEqual(cursor?.sharedPoolOrigin, "gbu", "the producer of the number is kept as provenance")
    }

    /// The producer identity of a remote donor is kept as provenance, and the
    /// installation identity of the row is left alone.
    func testASharedRowKeepsTheDonorsProducerIdentityAsProvenance() {
        var donor = makeWindow(providerKey: "grok", id: "studio:grok:subscription", rem: 44, observedAgo: 30)
        donor.sourceApp = "codecaps"
        donor.producerInstanceId = "studio-instance"
        var target = makeWindow(providerKey: "cursor", id: "local-mac:cursor:plan", rem: 10, observedAgo: 3600)
        target.source = "Cursor"

        let shared = UnifiedSubscriptionPool.share(windows: [donor, target], now: now)
        let cursor = shared.first { $0.canonicalProviderKey == "cursor" }
        XCTAssertEqual(cursor?.sharedPoolOrigin, "studio-instance")
        XCTAssertEqual(cursor?.source, "Cursor")
        XCTAssertNil(cursor?.producerInstanceId,
                     "the row keeps the installation identity the fleet rules read")
    }
}
