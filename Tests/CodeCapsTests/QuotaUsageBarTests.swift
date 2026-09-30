import XCTest
@testable import CodeCaps
import QuotaCore

/// Pins the glue between a quota window and the bar it draws: the marker
/// fraction Glance asks for, the words VoiceOver says, and when a bar dims.
/// The period and geometry math itself is tested in QuotaCore
/// (`QuotaBarMetricsTests`); SwiftUI bodies are not exercised directly, and the
/// picture is covered by `QuotaBarRenderTests`.
final class QuotaUsageBarTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let iso = ISO8601DateFormatter()

    private func makeWindow(
        label: String,
        token: String?,
        remaining: Double? = 85,
        resetIn: TimeInterval?,
        observedAgo: TimeInterval = 0
    ) -> QuotaWindowSnapshot {
        QuotaWindowSnapshot(window: QuotaWindow(
            id: label,
            provider: "Cursor",
            providerKey: "cursor",
            label: label,
            remainingPercent: remaining,
            remainingUnknown: remaining == nil,
            resetAt: resetIn.map { iso.string(from: now.addingTimeInterval($0)) },
            window: token,
            occurredAt: iso.string(from: now.addingTimeInterval(-observedAgo))), now: now)
    }

    // MARK: Marker

    func testGlanceAsksForAMarkerOnCursorsMonthlyPlan() throws {
        // The Plan window has no cadence token a duration parser recognises, only
        // "billing-cycle", and used to draw no marker at all.
        let plan = makeWindow(label: "Included plan", token: "billing-cycle", remaining: 15, resetIn: 15 * 86_400)
        let fraction = try XCTUnwrap(plan.elapsedFraction(now: now))
        // Roughly half a 30-day cycle is gone; the exact figure depends on the
        // length of the month the reset falls in.
        XCTAssertEqual(fraction, 0.5, accuracy: 0.05)
    }

    func testGlanceDrawsNoMarkerForAWindowWithNoDerivablePeriod() {
        let plan = makeWindow(label: "Included plan", token: "plan", resetIn: 15 * 86_400)
        XCTAssertNil(plan.elapsedFraction(now: now))
    }

    func testGlanceReadsTokensTheOldParserMisread() throws {
        // "31d" used to parse as one day, which pinned the marker at the right
        // edge for a Grok subscription that spans thirty-one days.
        let grok = makeWindow(label: "31d window", token: "31d", resetIn: 15.5 * 86_400)
        XCTAssertEqual(try XCTUnwrap(grok.elapsedFraction(now: now)), 0.5, accuracy: 0.001)
    }

    // MARK: Spoken value

    func testMeterSpeechNamesCaptionUsedRemainingAndElapsed() {
        let fiveHour = makeWindow(label: "5h window", token: "5h", remaining: 85, resetIn: 3 * 3_600)
        XCTAssertEqual(glanceMeterSpeech(fiveHour, now: now),
                       "5h 85 percent remaining, 15 percent used, 40 percent of period elapsed")
    }

    func testMeterSpeechForAWindowWithNoMarkerOmitsElapsed() {
        let plan = makeWindow(label: "Included plan", token: "plan", remaining: 85, resetIn: 15 * 86_400)
        XCTAssertEqual(glanceMeterSpeech(plan, now: now), "1m 85 percent remaining, 15 percent used")
    }

    func testMeterSpeechForAnUnknownReading() {
        let unknown = makeWindow(label: "5h window", token: "5h", remaining: nil, resetIn: 3_600)
        XCTAssertTrue(glanceMeterSpeech(unknown, now: now).hasPrefix("5h no reading"))
    }

    // MARK: Dimming

    func testAFreshReadingIsNotDimmed() {
        let fresh = makeWindow(label: "5h window", token: "5h", resetIn: 3_600)
        XCTAssertFalse(quotaBarIsDimmed(for: fresh, sourceFailed: false))
    }

    func testAStaleReadingOrAFailedSourceIsDimmed() {
        let stale = makeWindow(label: "5h window", token: "5h", resetIn: 3_600, observedAgo: 3 * 3_600)
        XCTAssertTrue(quotaBarIsDimmed(for: stale, sourceFailed: false))
        let fresh = makeWindow(label: "5h window", token: "5h", resetIn: 3_600)
        XCTAssertTrue(quotaBarIsDimmed(for: fresh, sourceFailed: true))
    }

    // MARK: The bar view

    func testTheBarMarkerKeepsItsSize() {
        // The owner asked for the marker to be the same size it was: two points
        // wide, standing two points proud of the bar above and below.
        XCTAssertEqual(QuotaUsageBar.markerWidth, 2)
        XCTAssertEqual(QuotaUsageBar.markerOverhang, 2)
    }
}
