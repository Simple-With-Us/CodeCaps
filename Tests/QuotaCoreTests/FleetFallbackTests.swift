import Foundation
import XCTest
@testable import QuotaCore

/// Which fleet readings may join this Mac's local list, and which of this
/// Mac's own pushed readings they replace.
final class FleetFallbackTests: XCTestCase {

    private func window(
        _ id: String,
        provider: String = "muse-code",
        label: String = "7-day window",
        token: String? = "7d",
        percent: Double? = 50,
        occurredAt: String
    ) -> QuotaWindow {
        QuotaWindow(
            id: id, provider: provider, providerKey: provider,
            label: label, remainingPercent: percent,
            window: token, occurredAt: occurredAt)
    }

    /// A provider this Mac does not read locally is served by the fleet, and
    /// a fleet reading reported after this Mac's own push replaces the older
    /// copy of the same period.
    func testANewerFleetReadingReplacesTheOlderOwnPush() {
        let own = window("own", occurredAt: "2026-11-03T13:48:06Z")
        let fleet = window("fleet", label: "weekly", token: "weekly", occurredAt: "2026-11-04T17:39:07Z")
        let result = QuotaLocalScope.fleetFallback(
            fleet: [fleet], adopted: [own], localProviders: [])
        XCTAssertEqual(result.fallback.map(\.id), ["fleet"])
        XCTAssertEqual(result.superseded.map(\.id), ["own"])
    }

    /// The fleet's "7d" and this Mac's "weekly" are the same period, so the
    /// older copy goes with the newer one.
    func testTheSamePeriodIsRecognisedAcrossTokens() {
        let own = window("own", label: "Third-Party Models · 7-day", token: "7d",
                         occurredAt: "2026-11-03T13:48:06Z")
        let fleet = window("fleet", label: "Third-Party (weekly)", token: "weekly",
                           occurredAt: "2026-11-04T17:39:07Z")
        let result = QuotaLocalScope.fleetFallback(
            fleet: [fleet], adopted: [own], localProviders: [])
        XCTAssertEqual(result.superseded.map(\.id), ["own"])
    }

    /// A different period is a different meter, so the older copy stays.
    func testADifferentPeriodIsNotSuperseded() {
        let own = window("own", label: "Third-Party Models · 5-hour", token: "5h",
                         occurredAt: "2026-11-03T13:48:06Z")
        let fleet = window("fleet", label: "Third-Party (weekly)", token: "weekly",
                           occurredAt: "2026-11-04T17:39:07Z")
        let result = QuotaLocalScope.fleetFallback(
            fleet: [fleet], adopted: [own], localProviders: [])
        XCTAssertEqual(result.fallback.map(\.id), ["fleet"])
        XCTAssertTrue(result.superseded.isEmpty)
    }

    /// The comparison is per period, not per provider:  this Mac's fresh
    /// five-hour reading must not hold back a newer weekly fleet reading, and
    /// its stale weekly copy is superseded by that fleet weekly while the
    /// five-hour one stays.
    func testPeriodsAreComparedIndependently() {
        let ownShort = window("own-5h", label: "Third-Party Models · 5-hour", token: "5h",
                              occurredAt: "2026-11-06T13:48:06Z")
        let ownWeekly = window("own-weekly", label: "Third-Party Models · 7-day", token: "7d",
                               occurredAt: "2026-11-03T13:48:06Z")
        let fleetShort = window("fleet-5h", label: "Third-Party 5-hour", token: "5h",
                                occurredAt: "2026-11-05T13:48:06Z")
        let fleetWeekly = window("fleet-weekly", label: "Third-Party weekly", token: "weekly",
                                 occurredAt: "2026-11-04T17:39:07Z")
        let result = QuotaLocalScope.fleetFallback(
            fleet: [fleetShort, fleetWeekly], adopted: [ownShort, ownWeekly], localProviders: [])
        XCTAssertEqual(Set(result.fallback.map(\.id)), ["fleet-weekly"])
        XCTAssertEqual(result.superseded.map(\.id), ["own-weekly"])
    }

    /// Two windows whose periods do not resolve are not the same meter just
    /// because neither resolves:  the fleet window of another period is
    /// served and this Mac's own window of its period is not superseded.
    func testUnresolvablePeriodsDoNotCollide() {
        let own = window("own", label: "Odd period A", token: "19x",
                         occurredAt: "2026-11-03T13:48:06Z")
        let fleet = window("fleet", label: "Odd period B", token: "23x",
                           occurredAt: "2026-11-04T17:39:07Z")
        let result = QuotaLocalScope.fleetFallback(
            fleet: [fleet], adopted: [own], localProviders: [])
        XCTAssertEqual(result.fallback.map(\.id), ["fleet"])
        XCTAssertTrue(result.superseded.isEmpty)
    }

    /// This Mac's own push is the newer reading:  the fleet's copy is
    /// redundant and the rule does not change.
    func testTheNewerOwnPushKeepsTheRow() {
        let own = window("own", occurredAt: "2026-11-04T18:00:00Z")
        let fleet = window("fleet", occurredAt: "2026-11-04T17:39:07Z")
        let result = QuotaLocalScope.fleetFallback(
            fleet: [fleet], adopted: [own], localProviders: [])
        XCTAssertTrue(result.fallback.isEmpty)
        XCTAssertTrue(result.superseded.isEmpty)
    }

    /// A provider this Mac reads itself is never served by the fleet.
    func testAProviderThisMacReadsIsNeverServedByTheFleet() {
        let fleet = window("fleet", provider: "minimax", occurredAt: "2026-11-04T17:39:07Z")
        let result = QuotaLocalScope.fleetFallback(
            fleet: [fleet], adopted: [], localProviders: ["minimax"])
        XCTAssertTrue(result.fallback.isEmpty)
    }

    /// A key nothing expects must not sprout a row.
    func testAnUnexpectedProviderIsNotServed() {
        let fleet = window("fleet", provider: "some-other-tool", occurredAt: "2026-11-04T17:39:07Z")
        let result = QuotaLocalScope.fleetFallback(
            fleet: [fleet], adopted: [], localProviders: [])
        XCTAssertTrue(result.fallback.isEmpty)
    }

    /// A provider this Mac never published at all is served by the fleet.
    func testAProviderThisMacNeverPublishedIsServed() {
        let fleet = window("fleet", occurredAt: "2026-11-04T17:39:07Z")
        let result = QuotaLocalScope.fleetFallback(
            fleet: [fleet], adopted: [], localProviders: [])
        XCTAssertEqual(result.fallback.map(\.id), ["fleet"])
    }
}
