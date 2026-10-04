import XCTest
@testable import CodeCaps
import QuotaCore

/// Pins Glance popover layout helpers so future refactors of `GlanceRow` cannot
/// silently change the visible countdown format and trip an owner who has
/// learned what "5h 12m" or "12h 30m" means at a glance.
///
/// SwiftUI view bodies are not exercised directly (the codebase uses plain
/// XCTest, not ViewInspector).  The free helper that produces the trailing
/// column's countdown is the surface that actually drives the row's text and
/// that the popover depends on for every row, so it is the right thing to
/// lock down.
final class GlanceRowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let minute: TimeInterval = 60
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    private func countdown(_ interval: TimeInterval) -> String {
        glanceResetCountdown(now.addingTimeInterval(interval), now: now)
    }

    // MARK: Countdown: at most the two largest non-zero units

    func testCountdownReturnsEmptyStringForNilReset() {
        XCTAssertEqual(glanceResetCountdown(nil, now: now), "")
    }

    func testCountdownIsDueAtZeroAndInThePast() {
        XCTAssertEqual(countdown(0), "due")
        XCTAssertEqual(countdown(-60), "due")
        XCTAssertEqual(countdown(-3 * day), "due")
    }

    func testUnderAMinuteReadsLessThanOneMinute() {
        XCTAssertEqual(countdown(1), "<1m")
        XCTAssertEqual(countdown(30), "<1m")
        XCTAssertEqual(countdown(59), "<1m")
        XCTAssertEqual(countdown(60), "1m")
    }

    func testMinutesOnly() {
        XCTAssertEqual(countdown(45 * minute), "45m")
        XCTAssertEqual(countdown(59 * minute + 59), "59m", "whole minutes left, never rounded up into an hour")
    }

    func testHoursAndMinutes() {
        XCTAssertEqual(countdown(2 * hour + 42 * minute), "2h 42m")
        XCTAssertEqual(countdown(23 * hour + 59 * minute), "23h 59m")
        XCTAssertEqual(countdown(hour + minute), "1h 1m")
    }

    func testDaysAndHoursDropTheMinutes() {
        XCTAssertEqual(countdown(4 * day + 2 * hour + 42 * minute), "4d 2h")
        XCTAssertEqual(countdown(17 * day + 4 * hour + 57 * minute), "17d 4h")
        XCTAssertEqual(countdown(6 * day + 23 * hour + 59 * minute), "6d 23h")
        XCTAssertEqual(countdown(day + hour), "1d 1h")
    }

    func testAZeroUnitIsDroppedAndNeverShowsZeroHours() {
        XCTAssertEqual(countdown(hour), "1h", "not \"1h 0m\"")
        XCTAssertEqual(countdown(day), "1d", "not \"1d 0h\"")
        // "The two largest non-zero units": the zero hour is skipped, the
        // minutes are not lost.
        XCTAssertEqual(countdown(4 * day + 59 * minute), "4d 59m", "a zero hour is skipped, never shown as \"0h\"")
        XCTAssertEqual(countdown(day + minute), "1d 1m")
        XCTAssertEqual(countdown(2 * day + 30), "2d", "seconds are not a unit")
        XCTAssertEqual(countdown(day - 1), "23h 59m", "a second short of a day stays in hours")
        XCTAssertEqual(countdown(hour - 1), "59m", "a second short of an hour stays in minutes")
        for interval in stride(from: 0.0, through: 40 * day, by: 7 * minute + 13) {
            let text = countdown(interval)
            XCTAssertFalse(text.hasPrefix("0"), "'\(text)' leads with a zero unit")
            XCTAssertFalse(text.contains(" 0"), "'\(text)' carries a zero unit")
            XCTAssertLessThanOrEqual(text.split(separator: " ").count, 2, "'\(text)' has more than two units")
        }
    }

    func testTheTooltipCarriesTheFullValueAndTheResetTime() {
        let reset = now.addingTimeInterval(4 * day + 2 * hour + 42 * minute)
        XCTAssertEqual(glanceResetFullCountdown(reset, now: now), "4d 2h 42m")
        XCTAssertEqual(glanceResetFullCountdown(now.addingTimeInterval(2 * hour), now: now), "2h",
                       "zero units are skipped in the tooltip too")
        XCTAssertEqual(glanceResetFullCountdown(now.addingTimeInterval(4 * day + 5 * minute), now: now), "4d 5m")
        XCTAssertEqual(glanceResetFullCountdown(now.addingTimeInterval(45 * minute), now: now), "45m")
        XCTAssertEqual(glanceResetFullCountdown(now.addingTimeInterval(20), now: now), "less than a minute")
        let help = glanceResetHelp(reset, now: now)
        let when = reset.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        XCTAssertEqual(help, "Resets in 4d 2h 42m, on \(when)")
        XCTAssertNil(glanceResetHelp(nil, now: now))
        XCTAssertNotNil(glanceResetHelp(now.addingTimeInterval(-60), now: now))
    }

    func testTheTooltipNeverShowsAZeroUnit() {
        for interval in stride(from: 61.0, through: 40 * day, by: 5 * minute + 7) {
            let text = glanceResetFullCountdown(now.addingTimeInterval(interval), now: now)
            XCTAssertFalse(text.hasPrefix("0"), "'\(text)'")
            XCTAssertFalse(text.contains(" 0"), "'\(text)'")
        }
    }

    // MARK: Status text

    func testStatusTextNamesTheProblemInAFewWords() {
        XCTAssertEqual(glanceRowStatusText(issue: ClaudeLoginState.signedOut.issue, hasWindows: false), "not signed in")
        XCTAssertEqual(glanceRowStatusText(issue: ClaudeLoginState.needsPermission.issue, hasWindows: false),
                       "needs permission")
        XCTAssertEqual(glanceRowStatusText(issue: ClaudeLoginState.idle.issue, hasWindows: true), "login idle")
        XCTAssertEqual(glanceRowStatusText(issue: "Claude quota is temporarily unavailable.", hasWindows: true),
                       "unavailable")
        XCTAssertEqual(glanceRowStatusText(issue: nil, hasWindows: false), "no report")
    }
}

// MARK: - Expanded rows show only what the row does not

final class GlanceExpandedLineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let iso = ISO8601DateFormatter()

    private func window(_ id: String, provider: String = "minimax", label: String, token: String?,
                        remaining: Double = 50, resetIn: TimeInterval = 3_600, model: String? = nil) -> QuotaWindow {
        QuotaWindow(id: id, provider: provider, providerKey: provider, modelId: model, label: label,
                    remainingPercent: remaining,
                    resetAt: iso.string(from: now.addingTimeInterval(resetIn)),
                    window: token, occurredAt: iso.string(from: now))
    }

    private func row(_ windows: [QuotaWindow]) -> DisplaySection {
        let section = QuotaResponse(generatedAt: "", windows: windows).platformSections(now: now)
            .first { !$0.windows.isEmpty }!
        return DisplaySection.rows(for: section, now: now)[0]
    }

    /// MiniMax as it reports: a "general" 4h and weekly pair the row meters,
    /// and a "video" daily and weekly pair it does not.
    private var miniMax: DisplaySection {
        row([
            window("general:interval", label: "general (4h window)", token: "4h", remaining: 92,
                   resetIn: 3 * 3_600, model: "general"),
            window("general:weekly", label: "general (1w window)", token: "1w", remaining: 81,
                   resetIn: 6 * 86_400, model: "general"),
            window("video:interval", label: "video (1d window)", token: "1d", remaining: 100,
                   resetIn: 20 * 3_600, model: "video"),
            window("video:weekly", label: "video (1w window)", token: "1w", remaining: 97,
                   resetIn: 5 * 86_400, model: "video"),
        ])
    }

    func testMiniMaxNeverExpandsVideoLinesInGlance() {
        let pair = glanceMeterPair(for: miniMax, now: now)
        XCTAssertEqual(pair.short?.window.id, "general:interval")
        XCTAssertEqual(pair.long?.window.id, "general:weekly")

        let lines = glanceExpandedLines(for: miniMax, now: now)
        XCTAssertTrue(lines.isEmpty, "video allowances are quarantined from Glance and only appear in platform settings")
    }

    func testARowWithOnlyItsTwoMetersHasNothingToExpand() {
        let twoWindows = row([
            window("5h", provider: "anthropic", label: "5h window", token: "5h"),
            window("7d", provider: "anthropic", label: "7d window", token: "7d", resetIn: 3 * 86_400),
        ])
        XCTAssertTrue(glanceExpandedLines(for: twoWindows, now: now).isEmpty)
    }

    func testALoneWeeklyExtraSitsUnderTheRowsWeeklyMeter() {
        let claude = row([
            window("five_hour", provider: "anthropic", label: "5h window", token: "5h", remaining: 40),
            window("seven_day", provider: "anthropic", label: "7d window", token: "7d", remaining: 60,
                   resetIn: 3 * 86_400),
            window("seven_day_sonnet", provider: "anthropic", label: "7d window (Sonnet)", token: "7d",
                   remaining: 90, resetIn: 3 * 86_400, model: "sonnet"),
        ])
        let lines = glanceExpandedLines(for: claude, now: now)
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.label, "Sonnet")
        XCTAssertNil(lines.first?.short, "the first column stays empty")
        XCTAssertEqual(lines.first?.long?.window.id, "seven_day_sonnet")
    }

    func testLineLabelsSayWhatTheWindowMeasures() {
        func label(_ label: String, model: String? = nil) -> String {
            glanceLineLabel(QuotaWindowSnapshot(window: window("x", label: label, token: nil, model: model), now: now))
        }
        XCTAssertEqual(label("video (1d window)", model: "video"), "Video")
        XCTAssertEqual(label("video (1d window)"), "Video")
        XCTAssertEqual(label("7-day window (Sonnet)"), "Sonnet")
        XCTAssertEqual(label("5h window (gpt-5-codex)", model: "gpt-5-codex"), "gpt-5-codex")
        XCTAssertEqual(label("Kimi Code (5h)"), "Kimi Code")
        XCTAssertEqual(label("Third-Party Models · Weekly"), "Third-Party")
        XCTAssertEqual(label("7d window"), "Overall")
        XCTAssertEqual(label("Included plan"), "Included plan")
    }

    /// A Claude row whose own two meters are the healthiest-to-worst pair, plus
    /// one extra model's windows with the given tokens, all healthier than the
    /// row's so they never take a meter.
    private func claudeWithOpus(_ tokens: [String]) -> DisplaySection {
        let seconds: [String: TimeInterval] = ["1h": 3_600, "2h": 7_200, "3h": 10_800, "5h": 18_000,
                                               "1d": 86_400, "3d": 3 * 86_400, "7d": 7 * 86_400]
        var windows = [
            window("five_hour", provider: "anthropic", label: "5h window", token: "5h", remaining: 10),
            window("seven_day", provider: "anthropic", label: "7d window", token: "7d", remaining: 20,
                   resetIn: 3 * 86_400),
        ]
        for token in tokens {
            windows.append(window("opus:\(token)", provider: "anthropic", label: "opus (\(token) window)",
                                  token: token, remaining: 60, resetIn: seconds[token] ?? 3_600, model: "opus"))
        }
        return row(windows)
    }

    private func ids(_ line: GlanceMeterLine) -> [String?] {
        [line.short?.window.id, line.long?.window.id]
    }

    func testThreeExtraWindowsKeepEachCadenceInItsOwnColumn() {
        // 5h is short; 1d and 7d are long.  The weekly must not land in the
        // first column just because it is the third window.
        let lines = glanceExpandedLines(for: claudeWithOpus(["5h", "1d", "7d"]), now: now)
        XCTAssertEqual(lines.map(\.label), ["Opus", "Opus"])
        XCTAssertEqual(ids(lines[0]), ["opus:5h", "opus:1d"])
        XCTAssertEqual(ids(lines[1]), [nil, "opus:7d"], "the weekly sits under the weekly meter")
    }

    func testTwoExtraWindowsStillShareOneLine() {
        let lines = glanceExpandedLines(for: claudeWithOpus(["1d", "7d"]), now: now)
        XCTAssertEqual(lines.map(ids), [["opus:1d", "opus:7d"]], "MiniMax's video 1d and 1w read as a pair")
    }

    func testAGroupOfOneCadenceIsPairedInOrderAndALeftoverSitsInItsCadenceColumn() {
        let longs = glanceExpandedLines(for: claudeWithOpus(["1d", "3d", "7d"]), now: now)
        XCTAssertEqual(longs.map(ids), [["opus:1d", "opus:3d"], [nil, "opus:7d"]])
        let shorts = glanceExpandedLines(for: claudeWithOpus(["1h", "2h", "3h"]), now: now)
        XCTAssertEqual(shorts.map(ids), [["opus:1h", "opus:2h"], ["opus:3h", nil]])
    }

    func testASecondSourcesCopyOfAShownWindowIsNotAnExtraLine() {
        func claude(_ id: String, source: String, token: String, remaining: Double, resetIn: TimeInterval,
                    model: String? = nil, label: String) -> QuotaWindow {
            var w = window(id, provider: "anthropic", label: label, token: token, remaining: remaining,
                           resetIn: resetIn, model: model)
            w.source = source
            return w
        }
        let twoReaders = row([
            claude("a:5h", source: "claude-oauth", token: "5h", remaining: 40, resetIn: 3_600, label: "5h window"),
            claude("a:7d", source: "claude-oauth", token: "7d", remaining: 60, resetIn: 3 * 86_400,
                   label: "7d window"),
            claude("b:5h", source: "claude-cli", token: "5h", remaining: 42, resetIn: 3_600, label: "5h window"),
            claude("b:7d", source: "claude-cli", token: "7d", remaining: 61, resetIn: 3 * 86_400,
                   label: "7d window"),
        ])
        XCTAssertTrue(glanceExpandedLines(for: twoReaders, now: now).isEmpty,
                      "the second reader's 5h and weekly are the row's own numbers again")

        let withSonnet = row([
            claude("a:5h", source: "claude-oauth", token: "5h", remaining: 40, resetIn: 3_600, label: "5h window"),
            claude("a:7d", source: "claude-oauth", token: "7d", remaining: 60, resetIn: 3 * 86_400,
                   label: "7d window"),
            claude("b:5h", source: "claude-cli", token: "5h", remaining: 42, resetIn: 3_600, label: "5h window"),
            claude("b:sonnet", source: "claude-cli", token: "7d", remaining: 90, resetIn: 3 * 86_400,
                   model: "sonnet", label: "7d window (Sonnet)"),
        ])
        XCTAssertEqual(glanceExpandedLines(for: withSonnet, now: now).map(\.label), ["Sonnet"],
                       "a window the row does not show still gets its line")
    }

    func testTwoWindowsFromOneSourceWithTheSameNameAreBothKept() {
        let one = row([
            window("m:a", label: "general (4h window)", token: "4h", remaining: 10, resetIn: 3_600, model: "general"),
            window("m:b", label: "general (1w window)", token: "1w", remaining: 10, resetIn: 86_400, model: "general"),
            window("m:c", label: "fast (1d window)", token: "1d", remaining: 100, resetIn: 3_600, model: "fast"),
            window("m:d", label: "fast (1d window)", token: "1d", remaining: 90, resetIn: 7_200, model: "fast"),
        ])
        XCTAssertEqual(glanceExpandedLines(for: one, now: now).flatMap { [$0.short, $0.long].compactMap { $0 } }.count,
                       2, "windows that share a source are windows, not copies")
    }

    func testAnExpandedLineIsSpokenWithItsCaptionsAndResets() throws {
        let multiModel = row([
            window("m:a", label: "general (4h window)", token: "4h", remaining: 92, resetIn: 3 * 3_600, model: "general"),
            window("m:b", label: "general (1w window)", token: "1w", remaining: 81, resetIn: 6 * 86_400, model: "general"),
            window("m:c", label: "extra (1d window)", token: "1d", remaining: 100, resetIn: 20 * 3_600, model: "extra"),
            window("m:d", label: "extra (1w window)", token: "1w", remaining: 97, resetIn: 5 * 86_400, model: "extra"),
        ])
        let lines = glanceExpandedLines(for: multiModel, now: now)
        let line = try XCTUnwrap(lines.first)
        let speech = glanceMetersSpeech([line.short, line.long], now: now)
        XCTAssertTrue(speech.hasPrefix("1d 100 percent remaining"), speech)
        XCTAssertTrue(speech.contains("; 7d 97 percent remaining"), speech)
        XCTAssertTrue(speech.contains("resets in 20h"), speech)
        XCTAssertTrue(speech.contains("resets in 5d"), speech)
        XCTAssertEqual(glanceMetersSpeech([nil, nil], now: now), "")
    }

    func testAMaskedAntigravityWindowIsNeverAnExtraLine() {
        let windows = [
            QuotaWindowSnapshot(window: window("5h", provider: "anthropic", label: "Gemini · 5-hour", token: "5h",
                                               remaining: 80), now: now),
            QuotaWindowSnapshot(window: window("weekly", provider: "anthropic", label: "Gemini · Weekly",
                                               token: "weekly", remaining: 0, resetIn: 3 * 86_400), now: now),
        ]
        let masked = DisplaySection(
            id: "google-antigravity:gemini", providerKey: "google-antigravity", title: "Antigravity · Gemini",
            platformTitle: "Antigravity",
            section: QuotaPlatformSection(providerKey: "google-antigravity", providerLabel: "Antigravity",
                                          via: nil, expected: true, windows: windows),
            poolKey: "gemini", remainingPercent: 0, resetAt: nil, maskedWindowIds: ["5h"])
        XCTAssertTrue(glanceExpandedLines(for: masked, now: now).isEmpty)
    }
}

// MARK: - The two meters a compact row carries

/// Pins the 2026-09-29 widen: the popover shows the short (4-5hr) and the long
/// (weekly/monthly) quota for every platform on the row itself, so nothing has
/// to be expanded to see a second cadence.
///
/// The failure this guards against is specifically a row that quietly renders
/// ONE meter — a selector that returns the driving window twice looks correct
/// in a snapshot and is exactly the "half the truth" layout it replaced.
final class GlanceMeterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: Helpers

    private func makeWindow(
        id: String,
        label: String,
        token: String? = nil,
        remaining: Double? = 50,
        resetIn: TimeInterval? = nil,
        provider: String = "anthropic",
        source: String? = nil,
        model: String? = nil,
        accountKey: String? = nil
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
            occurredAt: iso.string(from: now),
            source: source,
            accountKey: accountKey), now: now)
    }

    /// A Claude-shaped 5h + weekly row: the exact pair the owner asked to see
    /// at once, with the five-hour window deliberately healthier than the
    /// weekly so a selector that just took "closest to cap" twice would fail.
    private func claudeRow() -> DisplaySection {
        makeRow([
            makeWindow(id: "session", label: "5h window", token: "5h", remaining: 92, resetIn: 3 * 3600),
            makeWindow(id: "weekly", label: "7d window", token: "168h", remaining: 11, resetIn: 4 * 86_400),
        ])
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

    // MARK: Layout

    func testTwoMeterRowFitsInsideThePopoverWidth() {
        // The whole point of the widen: two meters plus the title, the reset
        // countdown and the chevron, with the gutters, have to fit the frame
        // the popover actually opens at.  If a column grows past this, the
        // footer clips "Open CodeCaps ⌘1" the way the old 360pt width did.
        XCTAssertLessThanOrEqual(Metrics.glanceRowIntrinsicWidth, Metrics.glanceWidth,
            "the two-meter row is wider than the popover it renders in")
    }

    func testWidenedPopoverIsStillNarrowEnoughForAModestScreen() {
        // 1280pt was the narrowest display this app has been used on.  The
        // popover must not cover a useful share of it.
        XCTAssertLessThan(Metrics.glanceWidth, 1280 * 0.5)
    }

    func testMeterCaptionAlwaysFitsTheCaptionColumn() {
        // The caption column is 26pt at 9pt type, which is about five
        // characters.  A caption that outgrows it would push the two meters
        // out of alignment with each other.
        let tokens = ["5h", "5hr", "300m", "168h", "10080m", "weekly", "1w", "2w",
                      "43200m", "monthly", "24h", "daily", "3h", "session", "fast",
                      "plan", "", "1800s", "1.5h"]
        for token in tokens {
            let caption = glanceMeterCaption(makeWindow(id: token, label: "\(token) window", token: token))
            XCTAssertLessThanOrEqual(caption.count, 5,
                "caption '\(caption)' (token '\(token)') is too wide for the meter caption column")
        }
    }

    // MARK: Pair selection

    func testFiveHourAndWeeklyPairOntoOppositeMeters() {
        let pair = glanceMeterPair(for: claudeRow(), now: now)
        XCTAssertEqual(pair.short?.window.id, "session")
        XCTAssertEqual(pair.long?.window.id, "weekly")
    }

    func testPairNeverReturnsTheSameWindowTwice() {
        // The regression this exists for: a selector that resolves both slots
        // to the driving window renders one meter duplicated and the owner
        // still cannot see the weekly cap.
        for windows in [
            [makeWindow(id: "a", label: "5h window", token: "5h"), makeWindow(id: "b", label: "7d window", token: "weekly")],
            [makeWindow(id: "a", label: "3h window", token: "3h"), makeWindow(id: "b", label: "24h window", token: "24h")],
            // Two readings of one cadence from one source are two windows.
            [makeWindow(id: "a", label: "plan", remaining: 40), makeWindow(id: "b", label: "plan", remaining: 60)],
        ] {
            let pair = glanceMeterPair(for: makeRow(windows), now: now)
            XCTAssertNotNil(pair.long, "a two-window row must fill the second meter")
            if let long = pair.long {
                XCTAssertNotEqual(long.window.id, pair.short?.window.id,
                    "the same window cannot occupy both meters")
            }
        }
    }

    func testPairPicksByCadenceRatherThanByWhichWindowIsWorse() {
        // The weekly is at 11% and the five-hour at 92%.  A row that took the
        // lowest percentage twice would show the weekly in both slots and hide
        // the five-hour entirely.
        let pair = glanceMeterPair(for: claudeRow(), now: now)
        XCTAssertEqual(pair.short?.window.remainingPercent, 92)
        XCTAssertEqual(pair.long?.window.remainingPercent, 11)
    }

    func testPairSkipsAnAntigravityMaskedFiveHourWindow() {
        // Antigravity masks the 5h percentage when the weekly cap is spent,
        // because the 5h reading must not be believed.  A masked window in a
        // meter is worse than no meter.
        let row = makeRow([
            makeWindow(id: "5h", label: "Third-Party · 5-hour", token: "5h", remaining: 80),
            makeWindow(id: "weekly", label: "Third-Party · Weekly", token: "weekly", remaining: 0),
        ], masked: ["5h"])
        let pair = glanceMeterPair(for: row, now: now)
        XCTAssertEqual(pair.short?.window.id, "weekly")
    }

    func testPairFallsBackToTheDrivingWindowWhenEveryWindowIsMasked() {
        let row = makeRow([
            makeWindow(id: "5h", label: "Gemini · 5-hour", token: "5h", remaining: 80),
            makeWindow(id: "weekly", label: "Gemini · Weekly", token: "weekly", remaining: 0),
        ], masked: ["5h", "weekly"])
        let pair = glanceMeterPair(for: row, now: now)
        XCTAssertNotNil(pair.short, "a fully masked row must still render something")
    }

    func testSingleCadenceProviderFillsTheFirstMeterOnly() {
        // Grok Bot publishes one weekly meter.  It must land in the first slot
        // — never the second, and never both.
        let pair = glanceMeterPair(for: makeRow([
            makeWindow(id: "grokbot", label: "Grok Bot weekly", token: "weekly", remaining: 40)
        ]), now: now)
        XCTAssertEqual(pair.short?.window.id, "grokbot")
        XCTAssertNil(pair.long)
    }

    func testPairIsEmptyForARowWithNoWindows() {
        let pair = glanceMeterPair(for: makeRow([]), now: now)
        XCTAssertNil(pair.short)
        XCTAssertNil(pair.long)
    }

    func testSupplementaryVideoQuotaNeverOccupiesAMeter() {
        // MiniMax's video allowance is supplementary to the coding
        // subscription; showing it in a meter would displace a real cap.
        let video = QuotaWindowSnapshot(window: QuotaWindow(
            id: "video",
            provider: "MiniMax",
            providerKey: "minimax",
            label: "Video generation",
            remainingPercent: 30,
            remainingUnknown: false,
            window: "5h",
            occurredAt: ISO8601DateFormatter().string(from: now)), now: now)
        let pair = glanceMeterPair(for: makeRow([
            video,
            makeWindow(id: "code", label: "MiniMax Code (5h window)", token: "5h", remaining: 70),
        ]), now: now)
        XCTAssertEqual(pair.short?.window.id, "code")
    }

    // MARK: Grok Bot's stray extra bar (owner delta 2026-09-30)

    /// The windows the owner's Mac hands the Grok Bot row: DashboardService's
    /// reading and `gbu`'s reading of the same weekly allowance, and the
    /// placeholder `gbu` adds when it cannot read.
    private func dashboardWeekly(remaining: Double? = 80.633422) -> QuotaWindowSnapshot {
        makeWindow(id: "local-mac:grok-bot:weekly", label: "Grok Bot weekly", token: "weekly", remaining: remaining,
                   resetIn: 4 * 86_400 + 18 * 3_600, provider: "grok-bot", source: "Cursor DashboardService")
    }

    private func gbuWeekly(remaining: Double? = 80.63) -> QuotaWindowSnapshot {
        makeWindow(id: "local-mac:grok-bot:gbu-weekly", label: "Grok Bot weekly", token: "weekly", remaining: remaining,
                   resetIn: 4 * 86_400 + 18 * 3_600, provider: "grok-bot", source: "gbu")
    }

    private var gbuPlaceholder: QuotaWindowSnapshot {
        makeWindow(id: "local-mac:grok-bot:gbu-unknown", label: "Grok Bot weekly", token: nil, remaining: nil,
                   provider: "grok-bot", source: "gbu")
    }

    private func grokBotRow(_ windows: [QuotaWindowSnapshot]) -> DisplaySection {
        DisplaySection(
            id: "grok-bot", providerKey: "grok-bot", title: "Grok Bot", platformTitle: "Grok Bot",
            section: QuotaPlatformSection(providerKey: "grok-bot", providerLabel: "Grok Bot", via: "cursor",
                                          expected: true, windows: windows),
            poolKey: nil, remainingPercent: windows.compactMap(\.remainingPercent).min(),
            resetAt: windows.compactMap(\.resetAt).min(), maskedWindowIds: [])
    }

    func testAPlaceholderBesideAReadingIsNotDrawnAsAnEmptySecondBar() {
        // The root cause: the second slot took ANY other window of the row,
        // and `gbu`'s no-reading "Grok Bot weekly" captions "7d" like the
        // reading beside it, so it was drawn as an empty 7d bar with a dash.
        let pair = glanceMeterPair(for: grokBotRow([dashboardWeekly(), gbuPlaceholder]), now: now)
        XCTAssertEqual(pair.short?.window.id, "local-mac:grok-bot:weekly")
        XCTAssertNil(pair.long, "no second bar for a window with no reading")
    }

    func testAPlaceholderIsNeverDrawnWhenAnythingOnItsCadenceHasAReading() {
        // Whichever order the windows arrive in, and from whichever source.
        let orders: [[QuotaWindowSnapshot]] = [
            [gbuPlaceholder, dashboardWeekly()],
            [gbuPlaceholder, gbuWeekly()],
            [dashboardWeekly(), gbuPlaceholder, gbuWeekly()],
            [gbuPlaceholder, gbuWeekly(), dashboardWeekly()],
        ]
        for windows in orders {
            let pair = glanceMeterPair(for: grokBotRow(windows), now: now)
            for drawn in [pair.short, pair.long].compactMap({ $0 }) {
                XCTAssertNotNil(drawn.remainingPercent, "\(windows.map(\.window.id)): an empty bar was drawn")
            }
            XCTAssertNotNil(pair.short?.remainingPercent)
        }
    }

    func testTwoSourcesReadingTheSameWeeklyDrawOneWeeklyMeter() {
        // The live handoff right now: both readers report, to within a hundredth
        // of a percent, and the row drew the same "7d 81%" twice.
        let live = grokBotRow([dashboardWeekly(remaining: 80.585), gbuWeekly(remaining: 80.59)])
        let pair = glanceMeterPair(for: live, now: now)
        XCTAssertEqual(pair.short?.window.id, "local-mac:grok-bot:weekly", "the lower of the two, as the row always picks")
        XCTAssertNil(pair.long, "the other source's copy of the same meter is not a second meter")
        XCTAssertEqual(glanceMeterPair(for: grokBotRow([gbuWeekly(remaining: 80.59), dashboardWeekly(remaining: 80.585)]),
                                       now: now), pair, "whichever order they arrive in")
    }

    func testBothSourcesAndAPlaceholderStillDrawOneMeter() {
        let row = grokBotRow([dashboardWeekly(), gbuPlaceholder, gbuWeekly()])
        let pair = glanceMeterPair(for: row, now: now)
        XCTAssertNotNil(pair.short)
        XCTAssertNil(pair.long)
        XCTAssertTrue(glanceExpandedLines(for: row, now: now).isEmpty,
                      "neither the copy nor the placeholder is an extra line under the row")
        XCTAssertEqual(glanceMetersSpeech([pair.short, pair.long], now: now).components(separatedBy: ";").count, 1)
    }

    func testTheCopyDoesNotHideAWindowThatIsAnotherMeter() {
        // A second source's report of the SAME meter is a copy; a different
        // cadence from the same source is not.
        let fiveHour = makeWindow(id: "gbu-5h", label: "Grok Bot 5-hour", token: "5h", remaining: 70,
                                  resetIn: 3 * 3_600, provider: "grok-bot", source: "gbu")
        let pair = glanceMeterPair(for: grokBotRow([dashboardWeekly(), gbuWeekly(), fiveHour]), now: now)
        XCTAssertEqual(pair.short?.window.id, "gbu-5h")
        XCTAssertEqual(pair.long?.window.id, "local-mac:grok-bot:gbu-weekly", "the lower of the two weekly reports")
    }

    func testTwoWindowsOfOneSourceAndCadenceAreStillTwoMeters() {
        // A source that reports two windows with one label and one cadence has
        // two windows, not a window and its copy.
        let pair = glanceMeterPair(for: makeRow([
            makeWindow(id: "a", label: "Included plan", token: "weekly", remaining: 30, source: "one"),
            makeWindow(id: "b", label: "Included plan", token: "weekly", remaining: 60, source: "one"),
        ]), now: now)
        XCTAssertNotNil(pair.short)
        XCTAssertNotNil(pair.long)
    }

    func testAPlaceholderOnAnotherCadenceKeepsItsEmptyBar() {
        // Claude's weekly window is unknown while its 5h reads: that empty
        // 7d bar is true, and says the weekly cap is not known.
        let pair = glanceMeterPair(for: makeRow([
            makeWindow(id: "5h", label: "5h window", token: "5h", remaining: 80, resetIn: 3_600),
            makeWindow(id: "7d", label: "7d window", token: "168h", remaining: nil, resetIn: 86_400 * 3),
        ]), now: now)
        XCTAssertEqual(pair.short?.window.id, "5h")
        XCTAssertEqual(pair.long?.window.id, "7d")
        XCTAssertNil(pair.long?.remainingPercent)
    }

    func testOnlyPlaceholdersDrawAtMostOneEmptyBarPerCadence() {
        let one = glanceMeterPair(for: grokBotRow([
            gbuPlaceholder,
            makeWindow(id: "cursor-unknown", label: "Grok Bot weekly", token: nil, remaining: nil,
                       provider: "grok-bot", source: "Cursor DashboardService"),
        ]), now: now)
        XCTAssertNotNil(one.short)
        XCTAssertNil(one.long, "an empty bar is never drawn twice")
    }

    func testAWindowThatNamesNoCadenceGivesWayToAnyReading() {
        let pair = glanceMeterPair(for: makeRow([
            makeWindow(id: "5h", label: "5h window", token: "5h", remaining: 80, resetIn: 3_600),
            makeWindow(id: "q", label: "Something else", token: nil, remaining: nil),
        ]), now: now)
        XCTAssertEqual(pair.short?.window.id, "5h")
        XCTAssertNil(pair.long, "\"Quota\" with no reading says nothing next to a real 5h reading")
    }

    func testAModelWithNoWeeklyReadingStaysBesideAnotherModelsWeeklyReading() {
        // Cadence alone is not a meter's identity: Claude's Sonnet weekly with
        // no reading is a different meter from the overall weekly beside it.
        let fiveHour = makeWindow(id: "5h", label: "5h window", token: "5h", remaining: 70, resetIn: 3_600)
        let overall = makeWindow(id: "7d", label: "7-day window", token: "168h", remaining: 80, resetIn: 3 * 86_400)
        let sonnet = makeWindow(id: "7d-sonnet", label: "7-day window (Sonnet)", token: "168h", remaining: nil,
                                resetIn: 3 * 86_400)
        XCTAssertEqual(glanceDrawableWindows([overall, sonnet]).map(\.window.id), ["7d", "7d-sonnet"])
        let lines = glanceExpandedLines(for: makeRow([fiveHour, overall, sonnet]), now: now)
        XCTAssertEqual(lines.map(\.label), ["Sonnet"], "the unavailable model keeps its line under the row")
        XCTAssertEqual(lines.first?.long?.window.id, "7d-sonnet")
    }

    func testAMiniMaxModelThatReturnedNothingStaysBesideAModelThatDid() {
        // MiniMax's reader emits a tokenless "<model>:unknown" window for a
        // model with no fields; it is a different meter from the readable one.
        let general = makeWindow(id: "general:weekly", label: "general (1w window)", token: "1w", remaining: 81,
                                 provider: "minimax", model: "general")
        let speech = makeWindow(id: "speech:unknown", label: "speech", token: nil, remaining: nil,
                                provider: "minimax", model: "speech")
        XCTAssertEqual(glanceDrawableWindows([general, speech]).map(\.window.id),
                       ["general:weekly", "speech:unknown"])
    }

    func testTwoAccountsReadByTwoSourcesAreTwoMeters() {
        // Cursor's DashboardService is signed into one Grok Bot account and
        // `gbu` reads another: the same label and cadence, but not the same
        // allowance, so neither is a copy of the other.
        let dashboard = dashboardWeekly(remaining: 80.6)
        let other = makeWindow(id: "local-mac:grok-bot:gbu-weekly:b", label: "Grok Bot weekly", token: "weekly",
                               remaining: 31, resetIn: 2 * 86_400, provider: "grok-bot", source: "gbu", accountKey: "b")
        let pair = glanceMeterPair(for: grokBotRow([dashboard, other]), now: now)
        XCTAssertEqual(pair.short?.window.id, other.window.id, "the one closer to its cap")
        XCTAssertEqual(pair.long?.window.id, dashboard.window.id)
    }

    func testTwoAccountKeysAreTwoMeters() {
        let first = makeWindow(id: "a", label: "Grok Bot weekly", token: "weekly", remaining: 80.6,
                               resetIn: 4 * 86_400, provider: "grok-bot", source: "gbu", accountKey: "a")
        let second = makeWindow(id: "b", label: "Grok Bot weekly", token: "weekly", remaining: 80.6,
                                resetIn: 4 * 86_400, provider: "grok-bot", source: "Cursor DashboardService", accountKey: "b")
        let pair = glanceMeterPair(for: grokBotRow([first, second]), now: now)
        XCTAssertNotNil(pair.short)
        XCTAssertNotNil(pair.long, "different accounts, even when their numbers happen to agree")
    }

    func testTwoReadingsWithDifferentResetsAreTwoMeters() {
        let first = makeWindow(id: "a", label: "Grok Bot weekly", token: "weekly", remaining: 80.6,
                               resetIn: 4 * 86_400, provider: "grok-bot", source: "gbu")
        let second = makeWindow(id: "b", label: "Grok Bot weekly", token: "weekly", remaining: 80.6,
                                resetIn: 2 * 86_400, provider: "grok-bot", source: "Cursor DashboardService")
        let pair = glanceMeterPair(for: grokBotRow([first, second]), now: now)
        XCTAssertNotNil(pair.long, "one allowance has one reset")
    }

    func testDrawableWindowsKeepEveryReadingInOrder() {
        let windows = [gbuWeekly(), gbuPlaceholder, dashboardWeekly(),
                       makeWindow(id: "x", label: "5h window", token: "5h", remaining: nil, provider: "grok-bot")]
        let drawable = glanceDrawableWindows(windows)
        XCTAssertEqual(drawable.map(\.window.id),
                       ["local-mac:grok-bot:gbu-weekly", "local-mac:grok-bot:weekly", "x"])
    }

    // MARK: Captions

    func testWeeklyTokensCaptionAsSevenDays() {
        // Antigravity's pool labels are long ("Third-Party · Weekly"), so the
        // caption has to come from the cadence token, and a weekly window has
        // to read the same way next to a 5h one.
        for token in ["weekly", "1w", "168h", "10080m"] {
            XCTAssertEqual(glanceMeterCaption(makeWindow(id: token, label: "Third-Party · Weekly", token: token)), "7d",
                "token '\(token)' should caption as 7d")
        }
    }

    func testFiveHourTokensCaptionAsFiveHours() {
        for token in ["5h", "5hr", "300m"] {
            XCTAssertEqual(glanceMeterCaption(makeWindow(id: token, label: "Gemini · 5-hour", token: token)), "5h",
                "token '\(token)' should caption as 5h")
        }
    }

    func testMonthlyTokensCaptionAsOneMonth() {
        // Owner ruling 2026-09-30: a month reads "1m" on every row, never
        // "30d" and never "Plan".
        for token in ["monthly", "30d", "31d", "28d", "43200m", "month", "billing-cycle"] {
            XCTAssertEqual(glanceMeterCaption(makeWindow(id: token, label: "Plan", token: token)), "1m",
                "token '\(token)' should caption as 1m")
        }
    }

    func testCursorIncludedPlanCaptionsAsOneMonth() {
        // Cursor's plan resets with its monthly billing cycle.  Its reader tags
        // the window "billing-cycle"; the unknown-reading fallback has no token
        // at all, and both used to caption as "Plan".
        XCTAssertEqual(glanceMeterCaption(makeWindow(id: "c", label: "Included plan", token: "billing-cycle",
                                                     provider: "cursor")), "1m")
        XCTAssertEqual(glanceMeterCaption(makeWindow(id: "c", label: "Included plan", token: nil,
                                                     provider: "cursor")), "1m")
    }

    func testTokenlessWindowCaptionsFromItsLabelThenAsPlan() {
        // Kimi's plan quota arrives with no cadence token and no known period,
        // so it still says "Plan" rather than guessing a month.
        XCTAssertEqual(glanceMeterCaption(makeWindow(id: "k", label: "Plan quota", token: nil)), "Plan")
        XCTAssertEqual(glanceMeterCaption(makeWindow(id: "m", label: "Monthly allowance", token: nil)), "1m")
        XCTAssertEqual(glanceMeterCaption(makeWindow(id: "u", label: "Something else", token: nil)), "Quota")
    }

    func testCompactConsoleNameSaysOneMonthForMonthlyWindows() {
        XCTAssertEqual(compactWindowName("Included plan"), "1m")
        XCTAssertEqual(compactWindowName("Monthly window"), "1m")
        XCTAssertEqual(compactWindowName("Billing cycle"), "1m")
        XCTAssertEqual(compactWindowName("5-hour window"), "5h")
    }

    func testCaptionFallsBackToTheLabelWhenTheTokenIsNotADuration() {
        XCTAssertEqual(glanceMeterCaption(makeWindow(id: "x", label: "Third-Party Models · Weekly", token: "shared")), "7d")
        XCTAssertEqual(glanceMeterCaption(makeWindow(id: "y", label: "Gemini Models · 5-hour", token: "shared")), "5h")
    }

    // MARK: Cadence

    func testCadenceReadsTheWindowTokenWhenPresent() {
        XCTAssertEqual(glanceCadence(makeWindow(id: "a", label: "l", token: "5h"), now: now), .short)
        XCTAssertEqual(glanceCadence(makeWindow(id: "b", label: "l", token: "24h"), now: now), .long)
        XCTAssertEqual(glanceCadence(makeWindow(id: "c", label: "l", token: "weekly"), now: now), .long)
        XCTAssertEqual(glanceCadence(makeWindow(id: "d", label: "l", token: "session"), now: now), .short)
    }

    func testCadenceFallsBackToHowLongUntilReset() {
        // A window with no cadence token is still classifiable by how far off
        // its reset is, which is the only signal a plan meter gives.
        let soon = makeWindow(id: "s", label: "l", token: nil, resetIn: 3 * 3600)
        let later = makeWindow(id: "l", label: "l", token: nil, resetIn: 5 * 86_400)
        XCTAssertEqual(glanceCadence(soon, now: now), .short)
        XCTAssertEqual(glanceCadence(later, now: now), .long)
    }

    func testCadenceTreatsATokenlessWindowWithNoResetAsLong() {
        // A subscription-wide allowance with neither a cadence nor a reset is
        // the long side of the pair far more often than the short one.
        XCTAssertEqual(glanceCadence(makeWindow(id: "u", label: "Included plan", token: nil), now: now), .long)
    }

    // MARK: Pacing Marker

    func testElapsedFractionForFiveHourWindow() {
        // 5-hour window with 2.5 hours remaining -> 50% elapsed
        let window5hHalf = makeWindow(id: "5h", label: "5h window", token: "5h", resetIn: 2.5 * 3_600)
        let fractionHalf = window5hHalf.elapsedFraction(now: now)
        XCTAssertNotNil(fractionHalf)
        if let fractionHalf {
            XCTAssertEqual(fractionHalf, 0.5, accuracy: 0.01)
        }

        // 5-hour window with 5 hours remaining -> 0% elapsed
        let window5hFull = makeWindow(id: "5h", label: "5h window", token: "5h", resetIn: 5.0 * 3_600)
        let fractionFull = window5hFull.elapsedFraction(now: now)
        XCTAssertNotNil(fractionFull)
        if let fractionFull {
            XCTAssertEqual(fractionFull, 0.0, accuracy: 0.01)
        }

        // 5-hour window with 0 hours remaining -> 100% elapsed
        let window5hZero = makeWindow(id: "5h", label: "5h window", token: "5h", resetIn: 0)
        let fractionZero = window5hZero.elapsedFraction(now: now)
        XCTAssertNotNil(fractionZero)
        if let fractionZero {
            XCTAssertEqual(fractionZero, 1.0, accuracy: 0.01)
        }
    }

    func testElapsedFractionForWeeklyWindow() {
        // 7-day window with 3.5 days remaining -> 50% elapsed
        let window7dHalf = makeWindow(id: "7d", label: "Weekly window", token: "weekly", resetIn: 3.5 * 86_400)
        let fractionHalf = window7dHalf.elapsedFraction(now: now)
        XCTAssertNotNil(fractionHalf)
        if let fractionHalf {
            XCTAssertEqual(fractionHalf, 0.5, accuracy: 0.01)
        }
    }

    func testElapsedFractionNilWhenResetOrDurationUnknown() {
        let windowNoReset = makeWindow(id: "x", label: "No reset", token: "5h", resetIn: nil)
        XCTAssertNil(windowNoReset.elapsedFraction(now: now))

        let windowNoDuration = makeWindow(id: "y", label: "Unknown", token: nil, resetIn: 3_600)
        XCTAssertNil(windowNoDuration.elapsedFraction(now: now))
    }

    // MARK: Fleet weekly gap

    func testFleetAntigravityNamesAMissingWeeklyReading() {
        let row = antigravityRow([
            makeWindow(id: "5h", label: "Gemini · 5-hour", token: "5h", remaining: 100,
                       resetIn: 4 * 3_600, provider: "google-antigravity"),
        ])
        XCTAssertEqual(fleetWeeklyGap(for: row, origin: .fleet, now: now), "no weekly reading reported")
        XCTAssertNil(fleetWeeklyGap(for: row, origin: .local, now: now),
                     "a local row keeps the blank second column")
    }

    func testFleetAntigravityWithBothCadencesHasNoGap() {
        let row = antigravityRow([
            makeWindow(id: "5h", label: "Gemini · 5-hour", token: "5h", remaining: 100,
                       resetIn: 4 * 3_600, provider: "google-antigravity"),
            makeWindow(id: "weekly", label: "Gemini · Weekly", token: "weekly", remaining: 40,
                       resetIn: 3 * 86_400, provider: "google-antigravity"),
        ])
        XCTAssertNil(fleetWeeklyGap(for: row, origin: .fleet, now: now))
    }

    func testFleetAntigravityWeeklyAloneHasNoGap() {
        // The one weekly meter sits in the first column.  That is the reading,
        // not a missing one.
        let row = antigravityRow([
            makeWindow(id: "weekly", label: "Gemini · Weekly", token: "weekly", remaining: 40,
                       resetIn: 3 * 86_400, provider: "google-antigravity"),
        ])
        XCTAssertNil(fleetWeeklyGap(for: row, origin: .fleet, now: now))
    }

    func testFleetAntigravityNamesAMaskedWeekly() {
        let row = antigravityRow([
            makeWindow(id: "5h", label: "Gemini · 5-hour", token: "5h", remaining: 100,
                       resetIn: 4 * 3_600, provider: "google-antigravity"),
            makeWindow(id: "weekly", label: "Gemini · Weekly", token: "weekly", remaining: 0,
                       resetIn: 3 * 86_400, provider: "google-antigravity"),
        ], masked: ["weekly"])
        XCTAssertEqual(fleetWeeklyGap(for: row, origin: .fleet, now: now), AntigravityDisplay.maskedCaption)
    }

    func testASingleMeterProviderDoesNotClaimAMissingWeekly() {
        let row = makeRow([
            makeWindow(id: "grokbot", label: "Grok Bot weekly", token: "weekly", remaining: 40),
        ])
        XCTAssertNil(fleetWeeklyGap(for: row, origin: .fleet, now: now))
    }

    private func antigravityRow(_ windows: [QuotaWindowSnapshot], masked: Set<String> = []) -> DisplaySection {
        DisplaySection(
            id: "google-antigravity:gemini",
            providerKey: "google-antigravity",
            title: "Antigravity · Gemini",
            platformTitle: "Antigravity",
            section: QuotaPlatformSection(
                providerKey: "google-antigravity",
                providerLabel: "Antigravity",
                via: nil,
                expected: true,
                windows: windows),
            poolKey: "gemini",
            remainingPercent: windows.compactMap(\.remainingPercent).min(),
            resetAt: nil,
            maskedWindowIds: masked)
    }
}
