import XCTest
@testable import CodeCaps
import QuotaCore

final class PipLowQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func row(remaining: Double?, seconds: Double = 0, stale: Bool = false,
                     unknown: Bool = false, masked: Bool = false, skip: Bool = false) -> DisplaySection {
        let observedAt = now.addingTimeInterval(seconds - (stale ? 3_600 : 0))
        let snapshot = QuotaWindowSnapshot(window: QuotaWindow(
            id: "w", provider: "anthropic", providerKey: "anthropic", label: "5h window",
            remainingPercent: remaining, remainingUnknown: unknown || remaining == nil,
            window: "5h", skip: skip, occurredAt: ISO8601DateFormatter().string(from: observedAt),
            source: "local-test"), now: now.addingTimeInterval(seconds))
        return DisplaySection(id: "anthropic", providerKey: "anthropic", title: "Claude",
            platformTitle: "Claude",
            section: QuotaPlatformSection(providerKey: "anthropic", providerLabel: "Claude",
                                          via: nil, expected: true, windows: [snapshot]),
            poolKey: nil, remainingPercent: remaining, resetAt: nil,
            maskedWindowIds: masked ? ["w"] : [])
    }

    private func evaluate(_ row: DisplaySection?, session: inout PipLowQuotaSession,
                          issues: [String: String] = [:], disabled: Set<String> = []) -> Bool {
        PipLowQuota.evaluate(rows: row.map { [$0] } ?? [], thresholdPercent: 15, enabled: true,
                             issues: issues, disabledSources: disabled, session: &session)
    }

    func testInitialLowSnapshotSeedsWithoutOpeningOnRepeatedChecks() {
        var session = PipLowQuotaSession()
        XCTAssertFalse(evaluate(row(remaining: 5), session: &session))
        XCTAssertFalse(evaluate(row(remaining: 5, seconds: 1), session: &session))
        XCTAssertEqual(session.rowsBelowThreshold, ["anthropic"])
        XCTAssertTrue(session.autoAddedRowIds.isEmpty)
    }

    func testExplicitNonzeroSkipCannotTriggerOrRecoverButZeroStillCrosses() {
        var session = PipLowQuotaSession()
        _ = evaluate(row(remaining: 50), session: &session)
        let skippedLow = row(remaining: 5, seconds: 1, skip: true)
        XCTAssertFalse(PipLowQuota.rowIsLow(skippedLow, thresholdPercent: 15))
        XCTAssertFalse(evaluate(skippedLow, session: &session))
        XCTAssertTrue(evaluate(row(remaining: 0, seconds: 2, skip: true), session: &session))
        XCTAssertFalse(evaluate(row(remaining: 50, seconds: 3, skip: true), session: &session))
        XCTAssertEqual(session.rowsBelowThreshold, ["anthropic"])
    }

    func testHealthyThenLowCrossingOpensAndRecoveryRemoves() {
        var session = PipLowQuotaSession()
        XCTAssertFalse(evaluate(row(remaining: 50), session: &session))
        XCTAssertTrue(evaluate(row(remaining: 5, seconds: 1), session: &session))
        XCTAssertEqual(session.autoAddedRowIds, ["anthropic"])
        XCTAssertFalse(evaluate(row(remaining: 40, seconds: 2), session: &session))
        XCTAssertTrue(session.autoAddedRowIds.isEmpty)
    }

    func testExhaustedRoutingSkipStillCountsAsFreshLowQuota() {
        var session = PipLowQuotaSession()
        XCTAssertFalse(evaluate(row(remaining: 50), session: &session))
        let exhausted = row(remaining: 0, seconds: 1)
        XCTAssertTrue(exhausted.section.windows[0].window.skip)
        XCTAssertTrue(PipLowQuota.rowIsLow(exhausted, thresholdPercent: 15))
        XCTAssertTrue(evaluate(exhausted, session: &session))
    }

    func testUnavailableAndMissingReadingsCannotRearmClosedLowRow() {
        var session = PipLowQuotaSession()
        _ = evaluate(row(remaining: 50), session: &session)
        XCTAssertTrue(evaluate(row(remaining: 5, seconds: 1), session: &session))
        PipLowQuota.noteUserClosedPip(session: &session)
        XCTAssertFalse(evaluate(nil, session: &session))
        XCTAssertFalse(evaluate(row(remaining: 50, seconds: 2), session: &session,
                                issues: ["anthropic": "Unavailable"]))
        XCTAssertFalse(evaluate(row(remaining: 50, seconds: 3), session: &session,
                                disabled: ["local-test"]))
        XCTAssertFalse(evaluate(row(remaining: 50, seconds: 4, stale: true), session: &session))
        XCTAssertFalse(evaluate(row(remaining: 50, seconds: 5, unknown: true), session: &session))
        XCTAssertFalse(evaluate(row(remaining: 5, seconds: 6), session: &session))
        XCTAssertTrue(session.autoOpenSuppressed)
        XCTAssertEqual(session.rowsBelowThreshold, ["anthropic"])
        _ = evaluate(row(remaining: 50, seconds: 7), session: &session)
        XCTAssertTrue(evaluate(row(remaining: 5, seconds: 8), session: &session))
        XCTAssertFalse(session.autoOpenSuppressed)
    }

    func testOlderOrEqualHealthySnapshotCannotRearmLowRow() {
        var session = PipLowQuotaSession()
        _ = evaluate(row(remaining: 5, seconds: 10), session: &session)
        _ = evaluate(row(remaining: 80, seconds: 9), session: &session)
        _ = evaluate(row(remaining: 80, seconds: 10), session: &session)
        XCTAssertFalse(evaluate(row(remaining: 5, seconds: 11), session: &session))
        XCTAssertEqual(session.rowsBelowThreshold, ["anthropic"])
    }

    func testStaleUnknownAndMaskedQuotaCannotSeedOrTrigger() {
        var session = PipLowQuotaSession()
        for invalid in [row(remaining: 0, stale: true), row(remaining: 0, unknown: true),
                        row(remaining: 0, masked: true), row(remaining: nil)] {
            XCTAssertFalse(evaluate(invalid, session: &session))
            XCTAssertFalse(PipLowQuota.rowIsLow(invalid, thresholdPercent: 15))
        }
        XCTAssertTrue(session.lastObservedAtByRow.isEmpty)
        XCTAssertFalse(evaluate(row(remaining: 0, seconds: 1), session: &session))
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

    func testDecisiveWindowRecoversDespiteUnknownAndOlderSibling() {
        var session = PipLowQuotaSession()
        func combined(_ remaining: Double, seconds: Double, omitPrimary: Bool = false) -> DisplaySection {
            var windows = omitPrimary ? [] : row(remaining: remaining, seconds: seconds).section.windows
            var sibling = row(remaining: 50).section.windows[0].window
            sibling.id = "older-sibling"
            windows.append(QuotaWindowSnapshot(window: sibling, now: now.addingTimeInterval(seconds)))
            var placeholder = sibling
            placeholder.id = "unknown-placeholder"
            placeholder.remainingPercent = nil
            placeholder.remainingUnknown = true
            windows.append(QuotaWindowSnapshot(window: placeholder, now: now.addingTimeInterval(seconds)))
            return DisplaySection(id: "anthropic", providerKey: "anthropic", title: "Claude",
                platformTitle: "Claude", section: QuotaPlatformSection(providerKey: "anthropic",
                    providerLabel: "Claude", expected: true, windows: windows),
                poolKey: nil, remainingPercent: remaining, resetAt: nil, maskedWindowIds: [])
        }
        XCTAssertFalse(evaluate(combined(50, seconds: 0), session: &session))
        XCTAssertTrue(evaluate(combined(5, seconds: 10), session: &session))
        XCTAssertFalse(evaluate(combined(50, seconds: 11, omitPrimary: true), session: &session))
        XCTAssertEqual(session.rowsBelowThreshold, ["anthropic"], "missing decisive evidence cannot rearm")
        XCTAssertFalse(evaluate(combined(50, seconds: 12), session: &session))
        XCTAssertTrue(session.rowsBelowThreshold.isEmpty)
        XCTAssertTrue(session.autoAddedRowIds.isEmpty)
        XCTAssertTrue(evaluate(combined(5, seconds: 13), session: &session))
    }
}
