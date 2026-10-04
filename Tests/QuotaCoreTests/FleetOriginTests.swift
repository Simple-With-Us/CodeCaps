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

    private func window(id: String = "w", source: String?, sourceApp: String?) -> QuotaWindow {
        QuotaWindow(id: id, provider: "anthropic", providerKey: "anthropic", sourceApp: sourceApp,
                    label: "5h window", remainingPercent: 50,
                    occurredAt: "2026-09-17T03:37:53.456Z", source: source)
    }
}
