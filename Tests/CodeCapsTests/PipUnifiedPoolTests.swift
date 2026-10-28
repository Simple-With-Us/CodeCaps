import XCTest
@testable import CodeCaps
import QuotaCore

@MainActor
final class PipUnifiedPoolTests: XCTestCase {
    private let iso = ISO8601DateFormatter()
    private let now = Date()

    private func makeDisplaySection(providerKey: String, windowId: String, rem: Double?, resetIn: TimeInterval = 86400 * 5, observedAgo: TimeInterval = 60) -> DisplaySection {
        let label = quotaProviderLabel(providerKey)
        let window = QuotaWindow(
            id: windowId,
            provider: label,
            providerKey: providerKey,
            providerLabel: label,
            label: "Subscription window",
            remainingPercent: rem,
            resetAt: iso.string(from: now.addingTimeInterval(resetIn)),
            window: "weekly",
            occurredAt: iso.string(from: now.addingTimeInterval(-observedAgo)),
            source: label
        )
        let snapshot = QuotaWindowSnapshot(window: window, now: now)
        let section = QuotaPlatformSection(
            providerKey: providerKey,
            providerLabel: label,
            expected: true,
            windows: rem != nil ? [snapshot] : []
        )
        return DisplaySection(
            id: providerKey,
            providerKey: providerKey,
            title: label,
            platformTitle: label,
            section: section,
            poolKey: nil,
            remainingPercent: rem,
            resetAt: now.addingTimeInterval(resetIn),
            maskedWindowIds: []
        )
    }

    func testPipWidgetXaiGetsReadingFromCursorPeer() {
        let cursorRow = makeDisplaySection(providerKey: "cursor", windowId: "local-mac:cursor:plan", rem: 31.5, observedAgo: 60)
        // xAI has a stale reading (observed 2 days ago)
        let xaiStaleRow = makeDisplaySection(providerKey: "xai", windowId: "local-mac:xai:subscription", rem: 10.0, observedAgo: 86400 * 2)

        let peerRows = [cursorRow, xaiStaleRow]

        let status = PipWidgetController.readingStatus(for: xaiStaleRow, now: now, peerRows: peerRows)
        XCTAssertNil(status, "xAI status must be nil (reading available), not 'stale reading' or 'unavailable'")

        let windows = PipWidgetController.currentWindows(for: xaiStaleRow, now: now, peerRows: peerRows)
        XCTAssertFalse(windows.isEmpty, "xAI must have current windows via peer reading sharing")
        XCTAssertEqual(windows.first?.remainingPercent, 31.5, "xAI must receive Cursor's fresh reading")
        XCTAssertTrue(windows.first?.isFresh ?? false)
    }

    func testPipWidgetCursorGetsReadingFromGrokPeer() {
        let grokRow = makeDisplaySection(providerKey: "grok", windowId: "local-mac:grok:subscription", rem: 52.0, observedAgo: 30)
        // Cursor row has no reading
        let cursorEmptyRow = makeDisplaySection(providerKey: "cursor", windowId: "local-mac:cursor:plan", rem: nil)

        let peerRows = [grokRow, cursorEmptyRow]

        let status = PipWidgetController.readingStatus(for: cursorEmptyRow, now: now, peerRows: peerRows)
        XCTAssertNil(status, "Cursor status must be nil when Grok peer has a fresh reading")

        let windows = PipWidgetController.currentWindows(for: cursorEmptyRow, now: now, peerRows: peerRows)
        XCTAssertEqual(windows.first?.remainingPercent, 52.0, "Cursor must receive Grok's fresh reading")
    }

    func testPipWidgetGrokGetsReadingFromGrokBotPeer() {
        let grokBotRow = makeDisplaySection(providerKey: "grok-bot", windowId: "local-mac:grok-bot:weekly", rem: 44.0, observedAgo: 45)
        let grokEmptyRow = makeDisplaySection(providerKey: "grok", windowId: "local-mac:grok:subscription", rem: nil)

        let peerRows = [grokBotRow, grokEmptyRow]

        let status = PipWidgetController.readingStatus(for: grokEmptyRow, now: now, peerRows: peerRows)
        XCTAssertNil(status, "Grok status must be nil when Grok Bot peer has a fresh reading")

        let windows = PipWidgetController.currentWindows(for: grokEmptyRow, now: now, peerRows: peerRows)
        XCTAssertEqual(windows.first?.remainingPercent, 44.0, "Grok must receive Grok Bot's fresh reading")
    }
    func testPeerFallbackRejectsBillingAndAccountMeters() {
        let billing = makeDisplaySection(providerKey: "cursor", windowId: "cursor:billing-cycle", rem: 9, observedAgo: 1)
        let account = makeDisplaySection(providerKey: "grok-bot", windowId: "gbu-weekly:account-123", rem: 12, observedAgo: 2)
        let target = makeDisplaySection(providerKey: "xai", windowId: "xai:subscription", rem: nil)
        XCTAssertTrue(PipWidgetController.currentWindows(for: target, now: now, peerRows: [billing, account]).isEmpty)
    }

    func testPeerFallbackUsesFreshestEligibleReadingAcrossRows() {
        let older = makeDisplaySection(providerKey: "cursor", windowId: "local-mac:cursor:plan", rem: 70, observedAgo: 120)
        let newer = makeDisplaySection(providerKey: "grok", windowId: "local-mac:grok:subscription", rem: 40, observedAgo: 10)
        let target = makeDisplaySection(providerKey: "xai", windowId: "xai:subscription", rem: nil)
        let windows = PipWidgetController.currentWindows(for: target, now: now, peerRows: [older, newer])
        XCTAssertEqual(windows.first?.remainingPercent, 40)
    }

}
