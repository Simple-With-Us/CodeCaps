import Foundation

/// Pure parser for the two places Claude Code stores its OAuth credential.
///
/// Claude Code writes the live token to
/// `~/.claude/.credentials.json` on disk, and macOS also stores an item under
/// `service = "Claude Code-credentials"` in the login Keychain.  Both shapes
/// look the same: a top-level dict that may carry the OAuth record directly,
/// or carry it nested under `claudeAiOauth`.  Either way, the record needs
/// `accessToken` (or `access_token`) and an `expiresAt` that is still in the
/// future — anything else is treated as "no usable credential", and the caller
/// decides whether to surface a re-authorisation prompt or a signed-out
/// message.
///
/// The parser is split out from `LocalQuotaReader` so the JSON shape can be
/// covered by unit tests without standing up a real Keychain or file on disk.
public enum ClaudeOAuthParser {
    /// Returns the OAuth record from `root` if it is present, well-formed,
    /// and unexpired; `nil` otherwise.  `now` is injectable so tests do not
    /// need to mock the clock.
    public static func validOAuth(in root: [String: Any], now: Date) -> [String: Any]? {
        let value = record(root["claudeAiOauth"])
        guard firstString(value, ["accessToken", "access_token"]) != nil else { return nil }
        if let expiry = firstTimestamp(value, ["expiresAt", "expires_at"]),
           let date = parseDate(expiry), date <= now { return nil }
        return value
    }

    /// Whether `root` holds a login that has expired but can still be renewed
    /// by Claude Code itself: an access token is present, its `expiresAt` has
    /// passed, and a non-empty refresh token exists whose own expiry (when
    /// recorded) is still ahead.  Claude Code only refreshes its 8-hour access
    /// token while a session runs, so an idle owner lands here.  Returns only a
    /// Bool — no token value ever leaves the parser.
    public static func isRenewable(in root: [String: Any], now: Date) -> Bool {
        let value = record(root["claudeAiOauth"])
        guard firstString(value, ["accessToken", "access_token"]) != nil,
              firstString(value, ["refreshToken", "refresh_token"]) != nil,
              let expiry = firstTimestamp(value, ["expiresAt", "expires_at"]),
              let expiryDate = parseDate(expiry), expiryDate <= now else { return false }
        if let refreshExpiry = firstTimestamp(value, ["refreshTokenExpiresAt", "refresh_token_expires_at"]),
           let refreshDate = parseDate(refreshExpiry), refreshDate <= now { return false }
        return true
    }

    /// Decodes the raw JSON bytes of a credentials file (or a Keychain
    /// payload) into a dictionary, returning `nil` for anything that is not
    /// valid JSON.  Caps the input size so a hostile file cannot make the
    /// parser allocate without bound.
    public static func parse(_ data: Data) -> [String: Any]? {
        guard data.count <= 1_048_576 else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Helpers (kept file-local; the parser is small enough that
    // duplicating them is cheaper than threading them through a shared file.)

    private static func record(_ value: Any?) -> [String: Any] {
        value as? [String: Any] ?? [:]
    }

    private static func firstString(_ root: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let string = root[key] as? String,
               !string.contains("\r"), !string.contains("\n"),
               !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return string.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    private static func firstTimestamp(_ root: [String: Any], _ keys: [String]) -> String? {
        for key in keys {
            if let string = root[key] as? String,
               !string.isEmpty { return string }
            if let number = root[key] as? NSNumber,
               CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
                return String(number.doubleValue)
            }
        }
        return nil
    }

    /// Parses the expiry timestamp the way Claude Code writes it.  ISO 8601
    /// first (with or without fractional seconds), then a bare Unix timestamp
    /// in seconds or milliseconds.  Anything above 1e10 is taken as ms and
    /// divided by 1000, matching the `LocalQuotaReader.validTimestamp` rule
    /// that distinguishes "year 2286 in seconds" (clearly invalid) from
    /// "year 2001 in milliseconds" (clearly a real timestamp).
    private static func parseDate(_ value: String) -> Date? {
        if let date = isoFormatter.date(from: value) { return date }
        if let date = isoFormatterWithFraction.date(from: value) { return date }
        if let seconds = Double(value), seconds.isFinite {
            if abs(seconds) > 10_000_000_000 { return Date(timeIntervalSince1970: seconds / 1000) }
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let isoFormatterWithFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
