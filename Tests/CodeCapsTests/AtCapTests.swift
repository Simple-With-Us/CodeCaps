import XCTest
@testable import CodeCaps
import QuotaCore

/// A plan at its cap used to draw a bar labelled 100%.
///
/// Owner 2026-10-11, with a screenshot of Claude reading 100% on its 5-hour
/// window while its weekly window sat at 0%: the row metered whichever window
/// still had headroom, so a plan that could not be used at all looked healthy.
/// Every surface now drops its bars for a capped plan and says "At Cap" with
/// the countdown to the reset that lifts it.
///
/// These tests pin the rule itself — which windows make a plan capped, and
/// which window's reset gets quoted — because a surface that asks the question
/// differently from its neighbour reintroduces exactly the disagreement this
/// removed.  SwiftUI view bodies are not exercised directly (plain XCTest, not
/// ViewInspector), so the predicates below are what the views branch on.
final class AtCapTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    // MARK: Helpers

    private func makeWindow(
        id: String,
        label: String,
        token: String? = nil,
        remaining: Double? = 50,
        resetIn: TimeInterval? = nil,
        observedIn: TimeInterval = 0,
        provider: String = "anthropic",
        model: String? = nil
    ) -> QuotaWindowSnapshot {
        let iso = ISO8601DateFormatter()
        return QuotaWindowSnapshot(window: QuotaWindow(
            id: id,
            provider: provider,
            providerKey: provider,
            providerLabel: provider,
            modelId: model,
            label: label,
            remainingPercent: remaining,
            remainingUnknown: remaining == nil,
            resetAt: resetIn.map { iso.string(from: now.addingTimeInterval($0)) },
            window: token,
            occurredAt: iso.string(from: now.addingTimeInterval(observedIn)),
            source: provider), now: now)
    }

    private func makeRow(_ windows: [QuotaWindowSnapshot], masked: Set<String> = []) -> DisplaySection {
        DisplaySection(
            id: "anthropic",
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
            resetAt: windows.compactMap(\.resetAt).min(),
            maskedWindowIds: masked)
    }

    /// The owner's screenshot: Claude's 5-hour window full, its weekly spent.
    private func cappedClaudeRow() -> DisplaySection {
        makeRow([
            makeWindow(id: "session", label: "5h window", token: "5h", remaining: 100, resetIn: 4 * hour + 56 * 60),
            makeWindow(id: "weekly", label: "7d window", token: "168h", remaining: 0, resetIn: day + 21 * hour),
        ])
    }

    // MARK: The window-level rule

    func testAWindowReportingZeroIsAtItsCap() {
        XCTAssertTrue(makeWindow(id: "w", label: "Weekly", remaining: 0).isAtCap)
    }

    func testAWindowWithHeadroomIsNotAtItsCap() {
        XCTAssertFalse(makeWindow(id: "w", label: "Weekly", remaining: 100).isAtCap)
        XCTAssertFalse(makeWindow(id: "w", label: "Weekly", remaining: 0.6).isAtCap)
    }

    /// A reading of 0.4% is drawn as 0%, so the rule has to call it spent:
    /// telling the owner a plan is not capped while its meter reads 0% is the
    /// drift the reviewer found between the pool's weekly test and this rule.
    func testAWindowThatRoundsToZeroIsAtItsCap() {
        XCTAssertTrue(makeWindow(id: "w", label: "Weekly", remaining: 0.4).isAtCap)
    }

    func testAnUnknownReadingIsNotACap() {
        // The absence of a number is not the number zero.  Treating it as a cap
        // would blank the bars of every plan CodeCaps simply cannot read.
        XCTAssertFalse(makeWindow(id: "w", label: "Weekly", remaining: nil).isAtCap)
    }

    func testAProviderCanSayExhaustedWithoutAPercentage() {
        let iso = ISO8601DateFormatter()
        let exhausted = QuotaWindowSnapshot(window: QuotaWindow(
            id: "w", provider: "anthropic", providerKey: "anthropic",
            providerLabel: "anthropic", label: "Weekly",
            remainingPercent: nil, remainingUnknown: true,
            isExhausted: true,
            resetAt: iso.string(from: now.addingTimeInterval(day)),
            occurredAt: iso.string(from: now)), now: now)
        XCTAssertTrue(exhausted.isAtCap, "an explicit exhausted flag is a cap even with no percentage")
    }

    // MARK: The plan-level rule

    func testOneSpentWindowCapsTheWholePlan() {
        // The owner's exact complaint: 5h at 100% beside a spent weekly.  The
        // plan is unusable, so the 100% must not be what the row leads with.
        let row = cappedClaudeRow()
        XCTAssertTrue(row.isAtCap)
        XCTAssertEqual(row.atCapWindow?.window.id, "weekly")
    }

    func testTheLatestResetIsTheOneQuoted() {
        // With two windows spent, the binding cap is the one that resets last.
        let row = makeRow([
            makeWindow(id: "a", label: "Weekly", token: "168h", remaining: 0, resetIn: 5 * day),
            makeWindow(id: "b", label: "5h window", token: "5h", remaining: 0, resetIn: 2 * hour),
        ])
        XCTAssertEqual(row.atCapWindow?.window.id, "a")
    }

    func testAPlanWithHeadroomEverywhereIsNotCapped() {
        let row = makeRow([
            makeWindow(id: "session", label: "5h window", token: "5h", remaining: 92, resetIn: 3 * hour),
            makeWindow(id: "weekly", label: "7d window", token: "168h", remaining: 11, resetIn: 4 * day),
        ])
        XCTAssertFalse(row.isAtCap)
        XCTAssertNil(row.atCapWindow)
    }

    /// Owner 2026-10-22, with a screenshot of the xAI row:  it read "7-day cap"
    /// while the sidebar beside it read 96%.
    ///
    /// The section carried a fresh 96% window beside two windows that reported
    /// an exhausted allowance days ago.  The sidebar's number filtered on
    /// freshness and the cap rule beside it did not, so one account read 96% in
    /// one place and "7-day cap" in the other.
    func testAStaleExhaustedWindowDoesNotCapTheRow() {
        let row = makeRow([
            makeWindow(id: "fresh", label: "7-day window", token: "weekly", remaining: 96, resetIn: 5 * day),
            makeWindow(id: "stale", label: "1w window", token: "1w", remaining: 0,
                       resetIn: -hour, observedIn: -5 * day),
        ])
        XCTAssertFalse(row.isAtCap, "a stale window must not cap the row")
        XCTAssertNil(row.atCapWindow)
        XCTAssertEqual(row.section.minimumRemainingPercent, 96,
                       "the sidebar's number reads the fresh window")
    }

    /// Owner 2026-10-25: Muse Code sat at 0% with a 5-hour countdown, but showed
    /// a 0% meter bar instead of the quota exhausted notice like Claude and AG.
    ///
    /// The collector had skipped polling because the weekly allowance was spent,
    /// so `occurredAt` was 24 hours old.  The reset was still in the future, so
    /// the allowance remained spent for the active cycle, but `isReadingRecent`
    /// called it stale and the cap rule refused to bind, leaving the row drawing
    /// meters instead of the cap notice.  An exhausted allowance whose cycle is
    /// unexpired binds the cap.
    func testAnUnexpiredExhaustedWindowObservedEarlierInCycleCapsTheRow() {
        let row = makeRow([
            makeWindow(id: "weekly", label: "7-day window", token: "weekly", remaining: 0,
                       resetIn: 5 * hour + 16 * 60, observedIn: -24 * hour, provider: "muse-code"),
        ])
        XCTAssertTrue(row.isAtCap, "an unexpired spent window must cap the row")
        XCTAssertEqual(row.atCapWindow?.window.id, "weekly")
        XCTAssertEqual(glanceAtCapSummary(try! XCTUnwrap(row.atCapWindow), now: now),
                       "7-day cap resets in 5h 16m")
    }

    func testAMaskedWindowIsNotEvidenceOfACap() {
        // An Antigravity 5-hour window under a spent weekly is masked: the
        // number is real and meaningless.  Only the unmasked weekly may cap.
        let row = makeRow([
            makeWindow(id: "session", label: "Gemini Models · 5-hour", token: "5h",
                       remaining: 0, resetIn: 2 * hour, provider: "google-antigravity"),
        ], masked: ["session"])
        XCTAssertFalse(row.isAtCap,
                       "a masked reading must not be believed in either direction")
    }

    func testASupplementaryVideoAllowanceDoesNotCapTheSubscription() {
        // MiniMax's video quota is a bonus on top of the coding plan; spending
        // it does not mean the plan is capped.
        let row = makeRow([
            makeWindow(id: "session", label: "5-hour window", token: "5h",
                       remaining: 64, resetIn: 3 * hour, provider: "minimax"),
            makeWindow(id: "video", label: "Video generation", token: "1d",
                       remaining: 0, resetIn: day, provider: "minimax", model: "video-hailuo"),
        ])
        XCTAssertFalse(row.isAtCap)
    }

    func testAWindowWithNoReadingNeverCapsThePlan() {
        let row = makeRow([
            makeWindow(id: "session", label: "5h window", token: "5h", remaining: nil, resetIn: 3 * hour),
            makeWindow(id: "weekly", label: "7d window", token: "168h", remaining: 40, resetIn: 4 * day),
        ])
        XCTAssertFalse(row.isAtCap)
    }

    func testAScopedCodexAllowanceDoesNotCapTheSubscription() {
        // A Codex response with only Code Review and additional pools has no
        // primary window.  These sit beside the subscription, so spending one
        // must not make the whole Codex row read "At Cap".
        let row = makeRow([
            makeWindow(id: "code-review:primary", label: "Code Review · 5-hour", token: "5h",
                       remaining: 0, resetIn: 3 * hour, provider: "openai"),
            makeWindow(id: "additional:spark", label: "Spark · 7-day", token: "168h",
                       remaining: 0, resetIn: 4 * day, provider: "openai"),
        ])
        XCTAssertFalse(row.isAtCap)
        XCTAssertNil(row.atCapWindow)
    }

    func testACodexSubscriptionWindowStillCapsBesideASpentScopedPool() {
        let row = makeRow([
            makeWindow(id: "primary", label: "5h window", token: "5h",
                       remaining: 0, resetIn: 3 * hour, provider: "openai"),
            makeWindow(id: "code-review:primary", label: "Code Review · 5-hour", token: "5h",
                       remaining: 0, resetIn: 2 * hour, provider: "openai"),
        ])
        XCTAssertTrue(row.isAtCap)
        XCTAssertEqual(row.atCapWindow?.window.id, "primary")
    }

    // MARK: What the row says

    func testTheCappedRowSpeaksTheCapNotTheMeters() {
        // VoiceOver must describe what the row shows.  It no longer shows
        // meters, so speaking "5h 100 percent remaining" would be describing a
        // number that is gone from the surface.
        let row = cappedClaudeRow()
        let atCap = row.atCapWindow!
        let spoken = GlanceAtCap(snapshot: atCap, now: now).spokenDescription
        XCTAssertTrue(spoken.contains("7-day cap"), "got \(spoken)")
        XCTAssertTrue(spoken.contains("1d 21h"), "the reset of the spent window is quoted: \(spoken)")
        XCTAssertFalse(spoken.contains("100"), "the headroom of the other window is not what this row is about: \(spoken)")
    }

    func testTheCappedRowWithNoResetStillSaysSo() {
        let atCap = makeWindow(id: "w", label: "Weekly", remaining: 0, resetIn: nil)
        let spoken = GlanceAtCap(snapshot: atCap, now: now).spokenDescription
        XCTAssertEqual(spoken, "7-day cap, quota exhausted")
    }

    func testAtCapSummaryUsesHyphenatedCadence() {
        let fiveHour = makeWindow(id: "session", label: "5h window", token: "5h", remaining: 0, resetIn: hour)
        XCTAssertEqual(glanceAtCapCadenceLabel(fiveHour), "5-hour")
        XCTAssertEqual(glanceAtCapSummary(fiveHour, now: now), "5-hour cap resets in 1h")

        let weekly = makeWindow(id: "weekly", label: "7d window", token: "168h", remaining: 0, resetIn: day)
        XCTAssertEqual(glanceAtCapCadenceLabel(weekly), "7-day")
        XCTAssertTrue(glanceAtCapSummary(weekly, now: now).hasPrefix("7-day cap resets in "))
    }
}