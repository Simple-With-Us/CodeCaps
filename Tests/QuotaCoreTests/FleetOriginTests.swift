import XCTest
@testable import QuotaCore

/// Legacy responses and explicit machine provenance must both remain readable.
final class FleetOriginTests: XCTestCase {
    func testIdentityPrefersSourceAndFallsBackInOrder() {
        XCTAssertEqual(FleetOrigin.identity(of: window(source: "antigravity-usage", sourceApp: "antigravity-cli")),
                       "antigravity-usage")
        XCTAssertEqual(FleetOrigin.identity(of: window(source: "  ", sourceApp: "antigravity-cli")),
                       "antigravity-cli")
        XCTAssertEqual(FleetOrigin.identity(of: window(source: nil, sourceApp: nil)), "fleet")
    }

    func testOwnPushIsRecognisedByProducerIdOrHostName() {
        XCTAssertFalse(FleetOrigin.isOwnPush(window(source: "codecaps", sourceApp: "codecaps"), host: "Studio"))
        XCTAssertTrue(FleetOrigin.isOwnPush(window(source: "Studio", sourceApp: nil), host: "Studio"))
        XCTAssertTrue(FleetOrigin.isOwnPush(window(source: "studio", sourceApp: nil), host: "Studio.local"))
        XCTAssertFalse(FleetOrigin.isOwnPush(window(source: "antigravity-usage", sourceApp: "antigravity-cli"),
                                             host: "Studio"))
        XCTAssertEqual(QuotaPublisher.producerId, "codecaps")
    }

    /// A shared legacy producer name cannot identify one machine.
    func testLegacyProducerAloneDoesNotProveOwnPush() {
        XCTAssertFalse(FleetOrigin.isOwnPush(window(source: "agent-bar", sourceApp: "agent-bar"), host: "Studio"))
        XCTAssertTrue(QuotaPublisher.legacyProducerAliases.contains("agent-bar"))
    }

    func testEveryWindowSurvivesTheSplitAndIsGroupedByOrigin() {
        // The shape of the live payload: this Mac's push echoed back, plus a
        // second producer's own reading of the same provider.
        let windows = [
            window(id: "anthropic-five_hour", source: "codecaps", sourceApp: "codecaps"),
            window(id: "gemini-weekly", source: "codecaps", sourceApp: "codecaps"),
            window(id: "claude-sonnet-4-6", source: "antigravity-usage", sourceApp: "antigravity-cli"),
            window(id: "gemini-3-flash", source: "antigravity-usage", sourceApp: "antigravity-cli"),
            window(id: "grok-bot-weekly", source: "other-mac", sourceApp: "codecaps"),
        ]
        let split = FleetOrigin.split(windows, host: "Studio")
        XCTAssertTrue(split.ownPush.isEmpty)
        XCTAssertEqual(split.groups.map(\.id), ["antigravity-usage", "codecaps", "other-mac"])
        XCTAssertEqual(split.groups.map(\.title), ["Antigravity Usage", "Unidentified Mac", "Other Mac"])
        XCTAssertEqual(split.groups.map { $0.windows.count }, [2, 2, 1])
        // Nothing is dropped: the old supplemental filter discarded every
        // pulled window whose provider this Mac also reads locally.
        XCTAssertEqual(split.ownPush.count + split.groups.reduce(0) { $0 + $1.windows.count }, windows.count)
    }

    func testTitleReadsAsAName() {
        XCTAssertEqual(FleetOrigin.title(for: "antigravity-usage"), "Antigravity Usage")
        XCTAssertEqual(FleetOrigin.title(for: "codecaps"), "Codecaps")
        XCTAssertEqual(FleetOrigin.title(for: "Studio"), "Studio")
        XCTAssertEqual(FleetOrigin.title(for: "fleet"), "Fleet")
    }

    func testExplicitInstancesOverrideSharedProducerAndDisplayName() {
        var own = window(id: "a", source: "codecaps", sourceApp: "codecaps")
        own.producerInstanceId = "own-id"
        own.machine = "Studio"
        var other = own
        other.id = "b"
        other.producerInstanceId = "other-id"
        let split = FleetOrigin.split([own, other], host: "own-id")
        XCTAssertEqual(split.ownPush.map(\.id), ["a"])
        XCTAssertEqual(split.groups.map(\.id), ["other-id"])
        XCTAssertEqual(split.groups.map(\.title), ["Studio"])
        own.machine = "Renamed Mac"
        XCTAssertTrue(FleetOrigin.isOwnPush(own, host: "own-id"))
        XCTAssertFalse(FleetOrigin.isOwnPush(other, host: "own-id"))
    }

    func testMachineFieldsSurviveWireAndNormalization() throws {
        let json = #"{"generatedAt":"2026-10-03T20:00:00Z","windows":[{"id":"a","provider":"anthropic","remainingPercent":50,"producerInstanceId":"stable-id","machine":"My Mac","source":"codecaps","occurredAt":"2026-10-03T20:00:00Z"}]}"#
        let response = try JSONDecoder().decode(QuotaResponse.self, from: Data(json.utf8))
        let roundTrip = try JSONDecoder().decode(QuotaResponse.self, from: JSONEncoder().encode(response))
        XCTAssertEqual(roundTrip.windows.first?.producerInstanceId, "stable-id")
        XCTAssertEqual(FleetOrigin.split(roundTrip.windows, host: "another-id").groups.first?.title, "My Mac")
    }

    func testLocalWindowsTimestampMatchingProvesOwnPush() {
        let local = window(id: "local-mac:anthropic:5h", source: "codecaps", sourceApp: "local-mac")
        var echoed = window(id: "local-mac:anthropic:5h", source: "codecaps", sourceApp: "codecaps")
        echoed.producerInstanceId = nil
        echoed.machine = nil

        let split = FleetOrigin.split([echoed], host: "unknown-host", localWindows: [local])
        XCTAssertEqual(split.ownPush.count, 1)
        XCTAssertEqual(split.ownPush.first?.id, "local-mac:anthropic:5h")
        XCTAssertTrue(split.groups.isEmpty)
    }

    func testLocalMacPrefixAndSourceAppIdentifiesOwnPush() {
        let prefixed = window(id: "local-mac:anthropic:five_hour", source: "Claude Code", sourceApp: nil)
        XCTAssertTrue(FleetOrigin.isOwnPush(prefixed, host: "unrelated-host"))

        let appSourced = window(id: "some-window", source: "Claude Code", sourceApp: "local-mac")
        XCTAssertTrue(FleetOrigin.isOwnPush(appSourced, host: "unrelated-host"))
    }

    func testTwoAgentBarMacsSplitByStableInstallationId() {
        var macA = window(id: "a", source: "agent-bar", sourceApp: "agent-bar")
        macA.producerInstanceId = "11111111-1111-1111-1111-111111111111"
        macA.machine = "Mac mini"
        var macB = window(id: "b", source: "agent-bar", sourceApp: "agent-bar")
        macB.producerInstanceId = "22222222-2222-2222-2222-222222222222"
        macB.machine = "Mac mini"
        let split = FleetOrigin.split([macA, macB], host: "studio-host")
        XCTAssertEqual(split.groups.count, 2)
        XCTAssertEqual(Set(split.groups.map(\.id)), Set([
            "11111111-1111-1111-1111-111111111111",
            "22222222-2222-2222-2222-222222222222",
        ]))
        XCTAssertEqual(split.groups.map(\.title), ["Mac mini", "Mac mini"])
    }

    func testQuotaResponseBatchInstanceStampsWindows() throws {
        let json = #"{"generatedAt":"2026-10-15T00:00:00Z","producerInstanceId":"batch-id","machine":"Kitchen Mac","windows":[{"id":"w","provider":"anthropic","source":"agent-bar","occurredAt":"2026-10-15T00:00:00Z"}]}"#
        let response = try JSONDecoder().decode(QuotaResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.windows.first?.producerInstanceId, "batch-id")
        XCTAssertEqual(response.windows.first?.machine, "Kitchen Mac")
        XCTAssertEqual(FleetOrigin.split(response.windows, host: "other").groups.map(\.id), ["batch-id"])
    }

    func testMachineNormalizationRecognizesDottedHostAndLocalizedNames() {
        var win = window(id: "remote-pull-1", source: "codecaps", sourceApp: "codecaps")
        win.machine = "Mac.Jays.Services"
        XCTAssertTrue(FleetOrigin.isOwnPush(win, host: "macjaysservices.local"))

        win.machine = "macjaysservices"
        XCTAssertTrue(FleetOrigin.isOwnPush(win, host: "Mac.Jays.Services"))
    }

    /// A local window that carries no reading is not a local reading.  The
    /// plan-details window of a provider this Mac cannot read must not count
    /// as one, or the fleet's live reading for that provider never reaches its
    /// row and the row reads no allowance at all.
    func testALocalWindowWithoutAReadingIsNotALocalReading() {
        let planDetails = QuotaWindow(
            id: "local-mac:xai:plan-metadata",
            provider: "xAI",
            providerKey: "xai",
            label: "Plan Details",
            remainingUnknown: true,
            occurredAt: "2026-10-23T22:54:46Z",
            source: "CodeCaps Settings"
        )
        XCTAssertTrue(QuotaLocalScope.providers(withReadings: [planDetails]).isEmpty,
                      "a plan-details window carries no reading, so it is not a local reading")

        let grok = QuotaWindow(
            id: "local-mac:grok:subscription",
            provider: "Grok",
            providerKey: "grok",
            label: "Weekly window",
            remainingPercent: 89,
            occurredAt: "2026-10-23T22:54:46Z",
            source: "Grok"
        )
        XCTAssertEqual(QuotaLocalScope.providers(withReadings: [planDetails, grok]), ["grok"],
                       "only the provider this Mac has a reading for counts")
    }

    /// This Mac's own push of a period that ended is a copy like any other
    /// when this Mac has no local reading to grey that period out.  There is
    /// nothing left to show for it, so it must not stand in for a reading.
    func testOwnPushOfAnEndedPeriodIsDroppedWhenThisMacHasNoLocalReading() {
        let ended = xaiWindow(id: "xai:subscription", percent: 0, resetIn: -86_400, observedAgo: 6 * 86_400)
        let split = FleetOrigin.split([ended], host: "this-mac", localWindows: [], now: Date())
        XCTAssertTrue(split.ownPush.isEmpty,
                      "a copy of a period that ended is not a reading, so it never reaches a row")
    }

    /// The exemption stays for a provider this Mac reads locally:  the local
    /// window is what greys the ended period out, so the copy of it coming
    /// back from the fleet is redundant.
    func testOwnPushOfAnEndedPeriodIsKeptWhenThisMacReadsThatProviderLocally() {
        let now = Date()
        let ended = xaiWindow(id: "local-mac:xai:subscription", percent: 89, resetIn: -86_400, observedAgo: 6 * 86_400)
        let local = QuotaWindow(
            id: "local-mac:xai:subscription",
            provider: "xAI",
            providerKey: "xai",
            label: "7-day window",
            remainingPercent: 89,
            resetAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-86_400)),
            window: "weekly",
            occurredAt: ISO8601DateFormatter().string(from: now.addingTimeInterval(-6 * 86_400))
        )
        let split = FleetOrigin.split([ended], host: "this-mac", localWindows: [local], now: now)
        XCTAssertEqual(split.ownPush.count, 1,
                       "the local window greys the ended period out, so the copy is redundant")
    }

    /// The xAI row end to end at the rule level.  This Mac reads no xAI quota
    /// locally, the fleet carries this Mac's own live SuperGrok Heavy reading
    /// under the xAI key, and the row must show that reading rather than the
    /// copies of two periods that ended.
    func testTheFleetLiveReadingReachesAProviderThisMacDoesNotReadLocally() {
        let live = xaiWindow(id: "grok:subscription", percent: 89, resetIn: 6 * 86_400, observedAgo: 60)
        let endedOne = xaiWindow(id: "xai-subscription", percent: 0, resetIn: -86_400, observedAgo: 6 * 86_400)
        let endedTwo = xaiWindow(id: "xai:subscription", percent: 0, resetIn: -86_400, observedAgo: 5 * 86_400)

        let split = FleetOrigin.split([live, endedOne, endedTwo], host: "this-mac", localWindows: [], now: Date())
        XCTAssertEqual(split.ownPush.map(\.id), ["grok:subscription"],
                       "the live reading survives and the copies of ended periods do not")
    }

    private func xaiWindow(id: String, percent: Double, resetIn: TimeInterval, observedAgo: TimeInterval) -> QuotaWindow {
        let iso = ISO8601DateFormatter()
        let clock = Date()
        return QuotaWindow(
            id: id,
            provider: "xAI",
            providerKey: "xai",
            label: "7-day window",
            remainingPercent: percent,
            resetAt: iso.string(from: clock.addingTimeInterval(resetIn)),
            window: "weekly",
            occurredAt: iso.string(from: clock.addingTimeInterval(-observedAgo)),
            source: "codecaps",
            producerInstanceId: "this-mac"
        )
    }

    private func window(id: String = "w", source: String?, sourceApp: String?) -> QuotaWindow {
        QuotaWindow(id: id, provider: "anthropic", providerKey: "anthropic", sourceApp: sourceApp,
                    label: "5h window", remainingPercent: 50,
                    occurredAt: "2026-09-17T03:37:53.456Z", source: source)
    }
}
