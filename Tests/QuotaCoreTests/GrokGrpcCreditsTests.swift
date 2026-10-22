import Foundation
import XCTest
@testable import QuotaCore

/// Fixtures for the grok.com gRPC-web fallback parser, built byte-by-byte
/// from the documented wire contract (CodexBar docs/grok.md): config is
/// field 1 of the reply, a top-level fixed32 is the used percent, field 6
/// is the current period as a `{start, end}` Timestamp pair on a weekly or
/// monthly cadence, and product shares nest inside repeated field 7 entries
/// so they must not be mistaken for the headline percent.
final class GrokGrpcCreditsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_761_000_000)
    /// Seven days.  The credits pool is billed weekly or monthly, so a
    /// recognized period is one of those two spans and nothing else.
    private let week: UInt64 = 604_800

    private func varint(_ value: UInt64) -> [UInt8] {
        var value = value
        var bytes: [UInt8] = []
        repeat {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value > 0 { byte |= 0x80 }
            bytes.append(byte)
        } while value > 0
        return bytes
    }

    private func field(_ number: Int, wire: Int, payload: [UInt8]) -> [UInt8] {
        varint(UInt64(number << 3 | wire)) + payload
    }

    private func lenField(_ number: Int, _ payload: [UInt8]) -> [UInt8] {
        field(number, wire: 2, payload: varint(UInt64(payload.count)) + payload)
    }

    private func fixed32Field(_ number: Int, _ value: Float) -> [UInt8] {
        var bits = value.bitPattern
        return field(number, wire: 5, payload: withUnsafeBytes(of: &bits) { Array($0) })
    }

    private func timestampField(_ number: Int, seconds: UInt64) -> [UInt8] {
        lenField(number, field(1, wire: 0, payload: varint(seconds)))
    }

    private func periodField(_ number: Int, start: UInt64, end: UInt64) -> [UInt8] {
        lenField(number, timestampField(1, seconds: start) + timestampField(2, seconds: end))
    }

    private func framed(_ payload: [UInt8], trailer: Bool = false) -> Data {
        var bytes: [UInt8] = [0x00, 0, 0, 0, UInt8(payload.count)]
        bytes += payload
        if trailer {
            let trailer = Array("grpc-status: 0\r\n".utf8)
            bytes += [0x80, 0, 0, 0, UInt8(trailer.count)] + trailer
        }
        return Data(bytes)
    }

    func testWrappedFramedReplyYieldsPercentAndPeriod() {
        let start: UInt64 = 1_760_400_000
        let end = start + week
        let config = fixed32Field(4, 37.5) + periodField(6, start: start, end: end)
        let reply = lenField(1, config)
        let reading = GrokGrpcCredits.parse(framed(Array(reply), trailer: true), now: now)
        XCTAssertEqual(reading?.usedPercent, 37.5)
        XCTAssertEqual(reading?.periodStart, Date(timeIntervalSince1970: TimeInterval(start)))
        XCTAssertEqual(reading?.periodEnd, Date(timeIntervalSince1970: TimeInterval(end)))
    }

    func testRawUnframedConfigIsAccepted() {
        let config = fixed32Field(4, 12.25)
        let reading = GrokGrpcCredits.parse(Data(config), now: now)
        XCTAssertEqual(reading?.usedPercent ?? -1, 12.25, accuracy: 0.001)
    }

    func testProductSharesAreNotTheHeadlinePercent() {
        // Field 7 entry: {1: product 2, 2: fixed32 55%} before the real 5%.
        let share = field(1, wire: 0, payload: varint(2)) + fixed32Field(2, 55)
        let config = lenField(7, Array(share)) + fixed32Field(4, 5)
        let reading = GrokGrpcCredits.parse(Data(lenField(1, Array(config))), now: now)
        XCTAssertEqual(reading?.usedPercent, 5)
    }

    func testImplicitZeroForActivePeriodWithoutPercent() {
        let start: UInt64 = 1_760_400_000
        let config = periodField(6, start: start, end: start + week)
        let reading = GrokGrpcCredits.parse(Data(lenField(1, Array(config))), now: now)
        XCTAssertEqual(reading?.usedPercent, 0)
    }

    func testNoPercentAndNoActivePeriodIsNil() {
        let start: UInt64 = 1_700_000_000
        XCTAssertNil(GrokGrpcCredits.parse(Data(lenField(1, Array(periodField(6, start: start, end: start + week)))), now: now))
        XCTAssertNil(GrokGrpcCredits.parse(Data([0xFF, 0xFF, 0xFF]), now: now))
        XCTAssertNil(GrokGrpcCredits.parse(Data(), now: now))
    }

    // MARK: - Only the documented field may set the period

    /// An unrelated length-delimited field that happens to hold two Timestamps
    /// must not be read as the subscription period: a previous-period or
    /// trial-window submessage would otherwise invent the window's bounds.
    func testAnUnrelatedBytesFieldCannotInventPeriodBounds() {
        let start: UInt64 = 1_760_400_000
        // Field 9 is not the current period, but it decodes as a valid pair.
        let decoy = periodField(9, start: start, end: start + week)
        let config = decoy + fixed32Field(4, 42)
        let reading = GrokGrpcCredits.parse(Data(lenField(1, Array(config))), now: now)
        XCTAssertEqual(reading?.usedPercent, 42)
        XCTAssertNil(reading?.periodStart, "a non-period field must not supply bounds")
        XCTAssertNil(reading?.periodEnd)
    }

    /// A decoy must not be able to open the implicit-zero branch either.
    func testAnUnrelatedBytesFieldCannotOpenTheImplicitZeroBranch() {
        let start: UInt64 = 1_760_400_000
        let decoy = periodField(9, start: start, end: start + week)
        XCTAssertNil(GrokGrpcCredits.parse(Data(lenField(1, Array(decoy))), now: now))
    }

    /// When the current-period field repeats, the first entry is the period;
    /// a later one must not overwrite bounds already captured.
    func testTheFirstPeriodFieldWins() {
        let first: UInt64 = 1_760_400_000
        let second: UInt64 = 1_760_800_000
        let config = periodField(6, start: first, end: first + week)
            + periodField(6, start: second, end: second + week)
        let reading = GrokGrpcCredits.parse(Data(lenField(1, Array(config))), now: now)
        XCTAssertEqual(reading?.usedPercent, 0)
        XCTAssertEqual(reading?.periodStart, Date(timeIntervalSince1970: TimeInterval(first)))
    }

    /// A Timestamp pair on no billing cadence is not this field's period.
    func testAnUnrecognizedPeriodLengthIsNotCaptured() {
        let start: UInt64 = 1_760_400_000
        let config = periodField(6, start: start, end: start + 1_008_000) // ~11.7 days
        let reading = GrokGrpcCredits.parse(Data(lenField(1, Array(config))), now: now)
        XCTAssertNil(reading, "a span that is neither weekly nor monthly is not the credits period")
    }

    // MARK: - A rejected percentage is still a published percentage

    /// A percentage that arrived but could not be accepted must not fall
    /// through to the implicit-zero rule, which would report the pool as
    /// untouched when the wire said otherwise.
    func testOutOfRangePercentIsNotReadAsZeroUsage() {
        let start: UInt64 = 1_760_400_000
        let config = fixed32Field(4, 150) + periodField(6, start: start, end: start + week)
        let reading = GrokGrpcCredits.parse(Data(lenField(1, Array(config))), now: now)
        XCTAssertNil(reading, "150% is not a reading, and not a licence to infer 0% used")
    }

    /// The same holds when the published value is not finite.
    func testNonFinitePercentIsNotReadAsZeroUsage() {
        let start: UInt64 = 1_760_400_000
        let nanBits = Float.nan.bitPattern
        let config = field(4, wire: 5, payload: withUnsafeBytes(of: &nanBits) { Array($0) })
            + periodField(6, start: start, end: start + week)
        let reading = GrokGrpcCredits.parse(Data(lenField(1, Array(config))), now: now)
        XCTAssertNil(reading)
    }

    func testRequestFrameMatchesDocumentedBytes() {
        XCTAssertEqual(GrokGrpcCredits.requestFrame, Data([0x00, 0x00, 0x00, 0x00, 0x02, 0x08, 0x00]))
    }
}
