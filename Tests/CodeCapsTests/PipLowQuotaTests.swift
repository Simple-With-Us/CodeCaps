import XCTest
@testable import CodeCaps
import QuotaCore

final class PipLowQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func window(id: String, remaining: Double?) -> QuotaWindowSnapshot {
        QuotaWindowSnapshot(window: QuotaWindow(
            id: id,
            provider: "anthropic",
            providerKey: "anthropic",
            label: "5h window",
            remainingPercent: remaining,
            remainingUnknown: remaining == nil,
            window: "5h",
            occurredAt: "2026-09-14T19:00:00Z"
        ), now: now)
    }

    private func row(id: String, windows: [QuotaWindowSnapshot]) -> DisplaySection {
        DisplaySection(
            id: id,
            providerKey: "anthropic",
            title: "Claude",
            platformTitle: "Claude",
            section: QuotaPlatformSection(
                providerKey: "anthropic",
                providerLabel: "Claude",
                via: nil,
                expected: true,
                windows: windows),
            poolKey: nil,
            remainingPercent: windows.compactMap(\.remainingPercent).min(),
            resetAt: nil,
            maskedWindowIds: [])
    }

    func testCrossingDownAutoAddsAndOpens() {
        var session = PipLowQuotaSession()
        let rows = [row(id: "anthropic", windows: [window(id: "w", remaining: 12)])]
        XCTAssertFalse(PipLowQuota.evaluate(rows: rows, thresholdPercent: 15, enabled: true,
                                            session: &session))
        XCTAssertTrue(session.seeded)

        let shouldOpen = PipLowQuota.evaluate(rows: rows, thresholdPercent: 15, enabled: true,
                                              session: &session)
        XCTAssertTrue(shouldOpen)
        XCTAssertEqual(session.autoAddedRowIds, ["anthropic"])
    }

    func testRecoveryRemovesAutoAddedRow() {
        var session = PipLowQuotaSession()
        let low = [row(id: "anthropic", windows: [window(id: "w", remaining: 5)])]
        _ = PipLowQuota.evaluate(rows: low, thresholdPercent: 15, enabled: true, session: &session)
        _ = PipLowQuota.evaluate(rows: low, thresholdPercent: 15, enabled: true, session: &session)
        XCTAssertEqual(session.autoAddedRowIds, ["anthropic"])

        let recovered = [row(id: "anthropic", windows: [window(id: "w", remaining: 40)])]
        _ = PipLowQuota.evaluate(rows: recovered, thresholdPercent: 15, enabled: true,
                                 session: &session)
        XCTAssertTrue(session.autoAddedRowIds.isEmpty,
                      "auto-added rows drop after recovery; pinned rows stay via pins alone")
    }

    func testUserCloseSuppressesReopenUntilNextCross() {
        var session = PipLowQuotaSession()
        let low = [row(id: "anthropic", windows: [window(id: "w", remaining: 5)])]
        _ = PipLowQuota.evaluate(rows: low, thresholdPercent: 15, enabled: true, session: &session)
        XCTAssertTrue(PipLowQuota.evaluate(rows: low, thresholdPercent: 15, enabled: true,
                                           session: &session))

        PipLowQuota.noteUserClosedPip(session: &session)
        XCTAssertFalse(PipLowQuota.evaluate(rows: low, thresholdPercent: 15, enabled: true,
                                            session: &session))

        let other = [
            row(id: "anthropic", windows: [window(id: "w", remaining: 5)]),
            row(id: "openai", windows: [window(id: "o", remaining: 4)]),
        ]
        XCTAssertTrue(PipLowQuota.evaluate(rows: other, thresholdPercent: 15, enabled: true,
                                          session: &session))
    }

    func testResetAndCrossAgainOpensAfterSuppress() {
        var session = PipLowQuotaSession()
        let low = [row(id: "anthropic", windows: [window(id: "w", remaining: 5)])]
        _ = PipLowQuota.evaluate(rows: low, thresholdPercent: 15, enabled: true, session: &session)
        _ = PipLowQuota.evaluate(rows: low, thresholdPercent: 15, enabled: true, session: &session)
        PipLowQuota.noteUserClosedPip(session: &session)
        _ = PipLowQuota.evaluate(rows: low, thresholdPercent: 15, enabled: true, session: &session)

        let recovered = [row(id: "anthropic", windows: [window(id: "w", remaining: 80)])]
        _ = PipLowQuota.evaluate(rows: recovered, thresholdPercent: 15, enabled: true, session: &session)
        XCTAssertTrue(PipLowQuota.evaluate(rows: low, thresholdPercent: 15, enabled: true, session: &session))
    }

    @MainActor
    func testDefaultThresholdAndPersistenceKeys() {
        let suite = "pip-low-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "pipOpenWhenLow")
        defaults.set(20, forKey: "pipLowThresholdPercent")
        let model = MonitorModel(defaults: defaults)
        XCTAssertTrue(model.pipOpenWhenLow)
        XCTAssertEqual(model.pipLowThresholdPercent, 20)
    }
}
