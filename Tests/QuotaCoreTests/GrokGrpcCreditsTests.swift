import Foundation
import XCTest
@testable import QuotaCore

/// Fixtures for the grok.com gRPC-web fallback parser, built byte-by-byte
/// from the documented wire contract (CodexBar docs/grok.md): config is
/// field 1 of the reply, a top-level fixed32 is the used percent, the
/// current period is a `{start, end}` Timestamp pair, and product shares
/// nest inside repeated field 7 entries so they must not be mistaken for
/// the headline percent.
final class GrokGrpcCreditsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_761_000_000)

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
        let end: UInt64 = 1_761_408_000
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
        let config = periodField(6, start: 1_760_400_000, end: 1_761_408_000)
        let reading = GrokGrpcCredits.parse(Data(lenField(1, Array(config))), now: now)
        XCTAssertEqual(reading?.usedPercent, 0)
    }

    func testNoPercentAndNoActivePeriodIsNil() {
        let config = periodField(6, start: 1_700_000_000, end: 1_701_000_000)
        XCTAssertNil(GrokGrpcCredits.parse(Data(lenField(1, Array(config))), now: now))
        XCTAssertNil(GrokGrpcCredits.parse(Data([0xFF, 0xFF, 0xFF]), now: now))
        XCTAssertNil(GrokGrpcCredits.parse(Data(), now: now))
    }

    func testRequestFrameMatchesDocumentedBytes() {
        XCTAssertEqual(GrokGrpcCredits.requestFrame, Data([0x00, 0x00, 0x00, 0x00, 0x02, 0x08, 0x00]))
    }
}
