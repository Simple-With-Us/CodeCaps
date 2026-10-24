import Foundation

/// Best-effort parser for the grok.com billing gRPC-web fallback
/// (`grok_api_v2.GrokBuildBilling/GetGrokCreditsConfig`), per the wire
/// contract documented by CodexBar (steipete/CodexBar, docs/grok.md,
/// descriptor checked 2026-09-21):
///
/// - Request body is one gRPC-web frame carrying
///   `GetGrokCreditsConfigRequest { exclude_legacy_monthly_usage: false }`:
///   bytes `00 00 00 00 02 08 00`.  An empty frame is rejected with gRPC
///   status 13, so the explicit false matters.
/// - The response config is field 1 of the reply (or the reply itself in
///   the raw form some successful requests return).  Inside it, a top-level
///   fixed32 float is the credit usage percent, repeated field 7 entries
///   are per-product shares `{1: product id, 2: float percent}`, and the
///   current period is a submessage of two protobuf Timestamps.
/// - grok.com now expects a browser-held Web Key Exchange keypair, so a
///   bearer-only probe can fail with gRPC status 16 (`no-credentials`).
///   This parser is therefore strictly a fallback: it only ever fills a
///   percentage the CLI-proxy answer did not publish, and a malformed or
///   partial reply yields nil rather than a guessed number.
public enum GrokGrpcCredits {
    public struct Reading: Equatable, Sendable {
        /// Percent of the subscription credit pool already used.
        public var usedPercent: Double
        /// Current period bounds, when a complete active period was present.
        public var periodStart: Date?
        public var periodEnd: Date?
    }

    /// The exact request frame bytes for the fallback call.
    public static let requestFrame = Data([0x00, 0x00, 0x00, 0x00, 0x02, 0x08, 0x00])

    /// Field 6 of the config is the current period, a `{start, end}` pair of
    /// Timestamps.  Period decoding is pinned to this number rather than to
    /// "any length-delimited field that happens to hold two Timestamps", so
    /// an unrelated submessage can never invent bounds for the window.
    static let currentPeriodField = 6

    /// Parse a gRPC-web (framed) or raw protobuf reply.  `now` bounds the
    /// implicit-zero rule: a complete active period with no percentage field
    /// anywhere on the wire reads as zero usage, matching grok.com's own web
    /// client, whose descriptor declares the percent an implicit-presence
    /// float.
    public static func parse(_ data: Data, now: Date) -> Reading? {
        guard let message = unwrapFrames(data) else { return nil }
        // Reply form: field 1 is the config.  Raw form: the reply IS the
        // config.  Prefer the wrapped form when field 1 decodes as bytes.
        let config: Data
        if let fields = try? ProtobufScanner.fields(message),
           let wrapped = fields.first(where: { $0.number == 1 && $0.wire == .bytes }) {
            config = wrapped.bytes
        } else {
            config = message
        }
        guard let fields = try? ProtobufScanner.fields(config) else { return nil }

        var percent: Double?
        var sawPercentField = false
        var periodStart: Date?
        var periodEnd: Date?
        for field in fields {
            switch field.wire {
            case .fixed32:
                // The only top-level floats in the config are usage
                // percentages; product shares nest inside field 7 entries.
                guard let value = field.floatValue else { continue }
                // Presence is tracked apart from the accepted value.  A
                // published percentage that is out of range or non-finite is
                // still a published percentage, and must not reach the
                // implicit-zero rule below as if nothing had been published.
                sawPercentField = true
                if percent == nil, value.isFinite, (0...100).contains(value) {
                    percent = value
                }
            case .bytes:
                // First match wins: a later field-6 submessage is not allowed
                // to overwrite bounds an earlier one already supplied.
                guard field.number == Self.currentPeriodField, periodStart == nil,
                      let period = timestampPair(field.bytes),
                      Self.isRecognizedPeriod(period.start, period.end) else { continue }
                periodStart = period.start
                periodEnd = period.end
            case .varint, .fixed64:
                continue
            }
        }

        if let percent {
            return Reading(usedPercent: percent, periodStart: periodStart, periodEnd: periodEnd)
        }
        // Implicit zero: complete active period, and no percentage field on
        // the wire at all.  A rejected percentage is not an absent one.
        if !sawPercentField, let start = periodStart, let end = periodEnd,
           start <= now, now <= end {
            return Reading(usedPercent: 0, periodStart: start, periodEnd: end)
        }
        return nil
    }

    /// The credits pool is billed weekly or monthly.  A Timestamp pair of any
    /// other length is not this field's subscription period, whatever its
    /// shape, and is left uncaptured rather than used as a reset bound.
    private static func isRecognizedPeriod(_ start: Date, _ end: Date) -> Bool {
        let days = end.timeIntervalSince(start) / 86_400
        return (6.5...8).contains(days) || (27...32).contains(days)
    }

    /// Whether the reply's gRPC-web trailer frame reports status 16
    /// (`UNAUTHENTICATED`).  grok.com answers a probe it will not serve with
    /// a framed 200 and a `grpc-status: 16` trailer, so an HTTP status check
    /// alone cannot see it.  Only the trailer carries the status, which is why
    /// this lives beside the frame parser.  Status 16 is the documented answer
    /// to a bearer-only probe with no Web Key Exchange keypair (see above), so
    /// the reader treats it as a fallback miss, not as a refused credential.
    /// Both trailer spellings count: `grpc-status:16` and the header-style
    /// `grpc-status: 16`.
    public static func isUnauthenticated(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        var offset = 0
        var trailer = [UInt8]()
        while offset + 5 <= bytes.count {
            let flag = bytes[offset]
            guard flag == 0x00 || flag == 0x80 else { break }
            let length = Int(bytes[offset + 1]) << 24 | Int(bytes[offset + 2]) << 16
                | Int(bytes[offset + 3]) << 8 | Int(bytes[offset + 4])
            guard offset + 5 + length <= bytes.count else { break }
            if flag == 0x80 { trailer.append(contentsOf: bytes[(offset + 5)..<(offset + 5 + length)]) }
            offset += 5 + length
        }
        guard !trailer.isEmpty else { return false }
        let text = String(decoding: trailer, as: UTF8.self).lowercased()
        guard let marker = text.range(of: "grpc-status:") else { return false }
        let value = text[marker.upperBound...].drop { $0 == " " || $0 == "\t" }
        return value.prefix(while: \.isNumber) == "16"
    }

    /// A `{start: Timestamp, end: Timestamp}` submessage, when the bytes
    /// decode as exactly two Timestamp-shaped fields in order.
    private static func timestampPair(_ data: Data) -> (start: Date, end: Date)? {
        guard let fields = try? ProtobufScanner.fields(data), fields.count == 2,
              fields.allSatisfy({ $0.wire == .bytes }) else { return nil }
        guard let start = timestamp(fields[0].bytes), let end = timestamp(fields[1].bytes),
              start < end else { return nil }
        return (start, end)
    }

    /// A protobuf Timestamp: field 1 varint seconds, optional field 2 nanos.
    private static func timestamp(_ data: Data) -> Date? {
        guard let fields = try? ProtobufScanner.fields(data),
              let secondsField = fields.first(where: { $0.number == 1 && $0.wire == .varint }),
              let seconds = secondsField.varintValue,
              (1_500_000_000...2_000_000_000).contains(seconds) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// Strip gRPC-web framing: `[flag][4-byte big-endian length][payload]`
    /// repeated, where flag 0x80 marks a trailer frame.  Data that is not
    /// framed is returned as-is (the raw protobuf form).
    private static func unwrapFrames(_ data: Data) -> Data? {
        guard data.count >= 5 else { return data.isEmpty ? nil : data }
        var offset = 0
        var payload = Data()
        var framed = false
        let bytes = [UInt8](data)
        while offset + 5 <= bytes.count {
            let flag = bytes[offset]
            guard flag == 0x00 || flag == 0x80 else { break }
            let length = Int(bytes[offset + 1]) << 24 | Int(bytes[offset + 2]) << 16
                | Int(bytes[offset + 3]) << 8 | Int(bytes[offset + 4])
            guard offset + 5 + length <= bytes.count else { break }
            framed = true
            if flag == 0x00 { payload.append(contentsOf: bytes[(offset + 5)..<(offset + 5 + length)]) }
            offset += 5 + length
        }
        return framed && offset == bytes.count ? payload : data
    }
}

/// Minimal protobuf wire scanner: enough to walk a message's top level
/// without a generated model.  Malformed input throws; callers treat that
/// as "no reading", never as a partial one.  Varints stop after ten bytes
/// and reject overflow, and length-delimited reads cannot exceed the
/// enclosing message — the same bounds CodexBar's reader documents.
enum ProtobufScanner {
    enum Wire {
        case varint, fixed64, bytes, fixed32
    }

    struct Field {
        var number: Int
        var wire: Wire
        var varintValue: UInt64?
        var floatValue: Double?
        var bytes: Data
    }

    enum ScanError: Error { case malformed }

    static func fields(_ data: Data) throws -> [Field] {
        var reader = Reader(bytes: [UInt8](data))
        var fields: [Field] = []
        while !reader.atEnd {
            let tag = try reader.varint()
            let number = Int(tag >> 3)
            guard number > 0 else { throw ScanError.malformed }
            switch tag & 0x07 {
            case 0:
                let value = try reader.varint()
                fields.append(Field(number: number, wire: .varint, varintValue: value, bytes: Data()))
            case 1:
                let raw = try reader.take(8)
                fields.append(Field(number: number, wire: .fixed64, bytes: Data(raw)))
            case 2:
                let length = try reader.varint()
                guard length <= UInt64(reader.remaining) else { throw ScanError.malformed }
                let raw = try reader.take(Int(length))
                fields.append(Field(number: number, wire: .bytes, bytes: Data(raw)))
            case 5:
                let raw = try reader.take(4)
                let bits = UInt32(raw[0]) | UInt32(raw[1]) << 8 | UInt32(raw[2]) << 16 | UInt32(raw[3]) << 24
                fields.append(Field(number: number, wire: .fixed32,
                                    floatValue: Double(Float(bitPattern: bits)), bytes: Data(raw)))
            default:
                throw ScanError.malformed
            }
        }
        return fields
    }

    private struct Reader {
        var bytes: [UInt8]
        var offset = 0
        var atEnd: Bool { offset >= bytes.count }
        var remaining: Int { bytes.count - offset }

        mutating func varint() throws -> UInt64 {
            var result: UInt64 = 0
            var shift: UInt64 = 0
            for _ in 0..<10 {
                guard offset < bytes.count else { throw ScanError.malformed }
                let byte = bytes[offset]
                offset += 1
                if shift == 63 {
                    // Tenth byte may only contribute bit 63.
                    guard byte <= 1 else { throw ScanError.malformed }
                }
                result |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return result }
                shift += 7
            }
            throw ScanError.malformed
        }

        mutating func take(_ count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= bytes.count else { throw ScanError.malformed }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }
    }
}
