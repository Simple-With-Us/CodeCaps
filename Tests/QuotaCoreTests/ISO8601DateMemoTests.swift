import Foundation
import XCTest
@testable import QuotaCore

/// The main-thread freeze behind the "App hanging for at least 2000 ms"
/// reports was ISO-8601 parsing.  Every window is parsed four times per
/// `platformSections` call — twice for the snapshot and twice more in
/// `normalizedForExport` — and `displaySections` is a computed property, so
/// each of its readers recomputed the whole set.  ICU rebuilt its calendar
/// and reloaded its date-format symbol tables on every one of those parses,
/// which is what the hang captures show as `loadAllSymbols` under
/// `udat_parseCalendar`.
///
/// The same instants are parsed over and over, so they are memoized.  These
/// tests assert the memo is doing that, rather than trusting the comment.
final class ISO8601DateMemoTests: XCTestCase {
    func testTheSameInstantIsParsedOnlyOnce() {
        let memo = ISO8601DateMemo.shared
        memo.removeAll()
        let before = memo.parseCount

        let first = memo.date(from: "2026-10-24T05:09:47.250Z")
        let afterFirst = memo.parseCount
        let second = memo.date(from: "2026-10-24T05:09:47.250Z")
        let third = memo.date(from: "2026-10-24T05:09:47.250Z")
        let afterRepeated = memo.parseCount

        XCTAssertNotNil(first)
        XCTAssertEqual(first, second)
        XCTAssertEqual(second, third)
        XCTAssertEqual(afterFirst - before, 1, "a cold instant must be parsed exactly once")
        XCTAssertEqual(afterRepeated - afterFirst, 0, "a warm instant must not be parsed again")
    }

    func testAnInstantWithFractionalSecondsStillReadsBackTheRightMoment() {
        let memo = ISO8601DateMemo.shared
        memo.removeAll()
        let parsed = memo.date(from: "2026-10-24T05:09:47.250Z")
        XCTAssertEqual(parsed?.timeIntervalSince1970 ?? 0, 1_792_818_587.25, accuracy: 0.001)
    }

    func testAnEmptyInstantIsNeitherParsedNorCached() {
        let memo = ISO8601DateMemo.shared
        memo.removeAll()
        let before = memo.parseCount
        XCTAssertNil(memo.date(from: ""))
        XCTAssertEqual(memo.parseCount, before, "an empty instant is not a parse")
    }

    /// The cost the freeze actually came from: a realistic window set, read
    /// the way every surface reads it, must not re-parse on the second pass.
    func testReadingTheSectionsTwiceDoesNotParseTwice() {
        let memo = ISO8601DateMemo.shared
        memo.removeAll()
        let now = Date(timeIntervalSince1970: 1_792_818_587)
        let windows = (0..<40).map { index in
            QuotaWindow(
                id: "window-\(index)",
                provider: "anthropic",
                label: "Claude",
                remainingPercent: 42,
                resetAt: "2026-10-25T05:09:47Z",
                occurredAt: "2026-10-24T05:09:47Z",
                periodStart: "2026-10-23T05:09:47Z"
            )
        }
        let response = QuotaResponse(generatedAt: "2026-10-24T05:09:47Z", windows: windows)

        let first = response.platformSections(now: now)
        let afterFirst = memo.parseCount
        XCTAssertGreaterThan(afterFirst, 0, "the first pass must really parse")
        XCTAssertFalse(first.isEmpty)

        let second = response.platformSections(now: now)
        XCTAssertEqual(memo.parseCount, afterFirst, "the second pass must reuse the memoized instants")
        XCTAssertEqual(first.count, second.count)
    }
}
