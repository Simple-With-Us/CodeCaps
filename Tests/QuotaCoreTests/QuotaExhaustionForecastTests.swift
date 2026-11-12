import Foundation
import XCTest
@testable import QuotaCore

/// The owner asked (2026-10-10) to be told when a platform is heading for its
/// limit: "ideally I'd like to know when there are like idk 5-15min left but I
/// know you can't possibly know that exactly."
///
/// These pin the honest version of that: a rate measured from observed samples,
/// reported as minutes of headroom, never as a precise countdown.
final class QuotaExhaustionForecastTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(_ minutesAgo: Double, _ remaining: Double) -> AnomalyDetector.Sample {
        AnomalyDetector.Sample(
            providerKey: "google-antigravity",
            windowId: "antigravity:gemini:5h",
            observedAt: now.addingTimeInterval(-minutesAgo * 60),
            remainingPercent: remaining)
    }

    /// 5% consumed over 5 minutes is 1 point/minute, so 8% left is 8 minutes.
    func testASteadyBurnProjectsToMinutesRemaining() {
        let f = QuotaExhaustionForecast.measure(
            samples: [sample(5, 13), sample(0, 8)], now: now, cadenceToken: "5h")
        XCTAssertEqual(f.percentPerMinute, 1.0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(f.minutesRemaining), 8.0, accuracy: 0.001)
        XCTAssertNil(f.unavailable)
        XCTAssertTrue(f.warrantsWarning, "8 minutes is well inside the 60 minute horizon")
    }

    /// The owner's exact ask: a window burning fast enough to run out inside the
    /// hour must warn even though its level is only mid-range.
    func testAFastBurnWarnsBeforeTheWindowLooksNearItsCap() {
        // 30 points over 20 minutes is 1.5/min; 20 left is about 13 minutes.
        let f = QuotaExhaustionForecast.measure(
            samples: [sample(20, 50), sample(0, 20)], now: now, cadenceToken: "5h")
        XCTAssertEqual(try XCTUnwrap(f.minutesRemaining), 13.3, accuracy: 0.1)
        XCTAssertFalse(f.isNearCap, "the level it started at is nowhere near the cap")
        XCTAssertTrue(f.warrantsWarning, "…but it runs out in ~13 minutes, which is the whole point")
    }

    /// A slow drip is not a warning: 0.5 points/minute with 80% left is hours
    /// of headroom, and crying wolf gets an alert muted.
    func testASlowDripDoesNotWarn() {
        let f = QuotaExhaustionForecast.measure(
            samples: [sample(60, 80), sample(0, 79.5)], now: now, cadenceToken: "5h")
        XCTAssertFalse(f.warrantsWarning)
    }

    /// The level-only case the owner raised: "IF we are unable to really watch
    /// close enough to see it move".  A window sitting at 2% with no history can
    /// still be called near-cap even though nothing can be projected.
    func testANearCapWindowIsFlaggedEvenWithNoUsableHistory() {
        let f = QuotaExhaustionForecast.measure(samples: [sample(0, 2)], now: now, cadenceToken: "5h")
        XCTAssertTrue(f.isNearCap, "2% remaining is near the cap regardless of rate")
        XCTAssertEqual(f.unavailable, .tooFewSamples)
        XCTAssertNil(f.minutesRemaining)
        XCTAssertFalse(f.warrantsWarning, "…but with no rate we cannot claim it is about to run out")
    }

    func testAFreshInstallSaysNoHistoryRatherThanGuessing() {
        let f = QuotaExhaustionForecast.measure(samples: [], now: now, cadenceToken: "5h")
        XCTAssertEqual(f.unavailable, .noReading)
        XCTAssertFalse(f.warrantsWarning)
    }

    /// A gap means the app was not watching.  A slope across it is an average of
    /// behaviour nobody observed, so it must not be projected.
    func testAGapLongerThanTheLimitMakesTheForecastUnavailable() {
        let f = QuotaExhaustionForecast.measure(
            samples: [sample(120, 40), sample(0, 5)], now: now, cadenceToken: "5h")
        XCTAssertEqual(f.unavailable, .tooFewSamples)
        XCTAssertNil(f.minutesRemaining, "a two-hour gap is not a rate")
    }

    /// A top-up mid-period shows remaining going UP.  That is not a negative burn
    /// rate to project; it is no signal at all.
    func testATopUpIsNotTreatedAsNegativeConsumption() {
        let f = QuotaExhaustionForecast.measure(
            samples: [sample(10, 20), sample(0, 90)], now: now, cadenceToken: "5h")
        XCTAssertEqual(f.unavailable, .notConsuming)
        XCTAssertNil(f.minutesRemaining)
        XCTAssertFalse(f.warrantsWarning)
    }

    /// An idle window is idle, not "about to run out" at an infinite rate.
    func testAnUnmovingWindowIsNotConsuming() {
        let f = QuotaExhaustionForecast.measure(
            samples: [sample(15, 50), sample(0, 50)], now: now, cadenceToken: "5h")
        XCTAssertEqual(f.unavailable, .notConsuming)
        XCTAssertFalse(f.warrantsWarning)
    }

    /// The owner named 97-100% on a 5-hour window and 99-100% on a weekly.  A
    /// week is a longer commitment, so the same fraction away matters more.
    func testTheNearCapLevelIsStricterForAWeeklyWindow() {
        XCTAssertEqual(QuotaExhaustionForecast.nearCapPercent(forCadence: "5h"), 97)
        XCTAssertEqual(QuotaExhaustionForecast.nearCapPercent(forCadence: "1w"), 99)
        XCTAssertEqual(QuotaExhaustionForecast.nearCapPercent(forCadence: "7d"), 99)
        XCTAssertEqual(QuotaExhaustionForecast.nearCapPercent(forCadence: "Weekly window"), 99)
    }

    /// The same level means different things on a 5-hour and a weekly window:
    /// 96% left is fine for the week and nearly spent for the hour.
    func testNearCapUsesTheWindowType() {
        // 3% remaining is 97% USED — exactly the owner's 5-hour threshold, and
        // four points short of the 99% he named for a weekly.
        let hourly = QuotaExhaustionForecast.measure(samples: [sample(0, 3)], now: now, cadenceToken: "5h")
        XCTAssertTrue(hourly.isNearCap, "97% used on a 5-hour window meets the owner's threshold")
        let weekly = QuotaExhaustionForecast.measure(samples: [sample(0, 3)], now: now, cadenceToken: "1w")
        XCTAssertFalse(weekly.isNearCap, "97% used on a weekly has not reached the stricter 99%")
        // And a plainly healthy window is near neither.
        let healthy = QuotaExhaustionForecast.measure(samples: [sample(0, 96)], now: now, cadenceToken: "5h")
        XCTAssertFalse(healthy.isNearCap, "4% used is nowhere near spent, on either cadence")
    }

    /// The output must never claim a precision the input does not have.
    func testTheHeadroomIsStatedInWordsNotToTheSecond() {
        let f = QuotaExhaustionForecast.measure(
            samples: [sample(5, 13), sample(0, 8)], now: now, cadenceToken: "5h")
        XCTAssertEqual(f.humanizedHeadroom, "about 8 min")
        // 10 points over 20 minutes is 0.5/min; 30 left is an hour, and the
        // gap must stay inside maxSampleGap for the rate to be usable at all.
        let long = QuotaExhaustionForecast.measure(
            samples: [sample(20, 40), sample(0, 30)], now: now, cadenceToken: "5h")
        XCTAssertEqual(long.humanizedHeadroom, "about 1 hour")
        // The [10, 12) hour band: truncating the ratio turned this into
        // "about 0 hours", which is a forecast of imminent doom for a window
        // with ten hours left.
        // 2 points over 25 minutes is 0.08/min; 50 left is 625 minutes, 10.4
        // hours — inside the [10, 12) band that used to render "about 0 hours".
        let band = QuotaExhaustionForecast.measure(
            samples: [sample(25, 52), sample(0, 50)], now: now, cadenceToken: "1w")
        XCTAssertEqual(try XCTUnwrap(band.minutesRemaining) / 60, 10.4, accuracy: 0.1)
        XCTAssertEqual(band.humanizedHeadroom, "about 12 hours")
    }
}