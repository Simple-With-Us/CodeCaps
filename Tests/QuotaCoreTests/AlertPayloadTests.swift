import XCTest
@testable import QuotaCore

/// The alerts the Mac ships to the iOS companion.
///
/// Owner request 2026-10-08: "iOS should have info about heavy anomalies in
/// usage or runaway usage like the mac."  The Mac makes the call and the phone
/// announces it, because the rules need this Mac's burn-rate history — a
/// per-machine file of measured hourly intervals the phone cannot reproduce.
final class AlertPayloadTests: XCTestCase {
    private let window = QuotaWindow(
        id: "w1", provider: "anthropic", label: "5h", remainingPercent: 42,
        occurredAt: "2026-10-08T12:00:00Z")

    private func alert(id: String = "runaway|anthropic|w1|vsBaseline") -> LocalQuotaSnapshot.AlertPayload {
        .init(id: id, kind: "runaway", providerKey: "anthropic", providerTitle: "Claude",
              windowLabel: "5h", summary: "Spending fast vs 5h: 6.4x your average.",
              occurredAt: "2026-10-08T12:00:00Z")
    }

    /// An older Mac writes no `alerts` key at all; the phone must still read
    /// the file, because the fields it already uses are unchanged.
    func testAPayloadWithoutAlertsStillDecodes() throws {
        let json = """
        {"format":"usage-monitor-local-quotas","version":1,"generatedAt":"2026-10-08T12:00:00Z",
         "windows":[]}
        """
        let payload = try JSONDecoder().decode(LocalQuotaSnapshot.Payload.self, from: Data(json.utf8))
        XCTAssertNil(payload.alerts)
    }

    func testAlertsRoundTrip() throws {
        let payload = LocalQuotaSnapshot.Payload(
            format: "usage-monitor-local-quotas", version: 1,
            generatedAt: "2026-10-08T12:00:00Z", windows: [window], alerts: [alert()])
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(LocalQuotaSnapshot.Payload.self, from: data)
        XCTAssertEqual(decoded.alerts?.count, 1)
        XCTAssertEqual(decoded.alerts?.first?.providerTitle, "Claude")
        XCTAssertEqual(decoded.alerts?.first?.summary, "Spending fast vs 5h: 6.4x your average.")
    }

    /// The `id` is what stops a payload rewritten every refresh from alerting
    /// every poll, so it has to survive the round trip byte-for-byte.
    func testTheAlertIdSurvivesEncodingExactly() throws {
        let original = alert(id: "runaway|openai|local-mac:openai:primary|vsPeak")
        let payload = LocalQuotaSnapshot.Payload(
            format: "f", version: 1, generatedAt: "2026-10-08T12:00:00Z",
            windows: [], alerts: [original])
        let decoded = try JSONDecoder().decode(
            LocalQuotaSnapshot.Payload.self, from: try JSONEncoder().encode(payload))
        XCTAssertEqual(decoded.alerts?.first?.id, original.id)
    }

    /// An unknown `kind` must not break decoding: a newer Mac may ship a kind
    /// this older phone has never heard of, and losing every other window over
    /// that would be a bad trade.
    func testAnUnknownAlertKindStillDecodes() throws {
        let json = """
        {"format":"f","version":1,"generatedAt":"2026-10-08T12:00:00Z","windows":[],
         "alerts":[{"id":"x","kind":"someFutureKind","providerKey":"p","providerTitle":"P",
                     "windowLabel":"7d","summary":"s","occurredAt":"2026-10-08T12:00:00Z"}]}
        """
        let payload = try JSONDecoder().decode(LocalQuotaSnapshot.Payload.self, from: Data(json.utf8))
        XCTAssertEqual(payload.alerts?.first?.kind, "someFutureKind")
    }
}
