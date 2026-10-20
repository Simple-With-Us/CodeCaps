import Foundation
import CoreFoundation

/// Supplemental account and balance information, separate from quota windows.
/// Kept local so account email never enters the public quota handoff or publisher.
public struct ProviderUsageDetails: Equatable, Sendable {
    public var accountEmail: String?
    public var creditBalance: Double?
    public var extraUsageEnabled: Bool?

    public init(accountEmail: String? = nil, creditBalance: Double? = nil,
                extraUsageEnabled: Bool? = nil) {
        self.accountEmail = Self.email(accountEmail)
        self.creditBalance = creditBalance.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.extraUsageEnabled = extraUsageEnabled
    }

    static func claude(payload: [String: Any], profile: [String: Any]) -> Self {
        let account = profile["account"] as? [String: Any] ?? [:]
        let extra = payload["extra_usage"] as? [String: Any] ?? [:]
        return Self(accountEmail: account["email"] as? String,
                    extraUsageEnabled: extra["is_enabled"] as? Bool)
    }

    static func codex(payload: [String: Any], tokens: [String: Any]) -> Self {
        let credits = payload["credits"] as? [String: Any] ?? [:]
        let balance: Double? = {
            if let value = credits["balance"] as? NSNumber,
               CFGetTypeID(value) != CFBooleanGetTypeID() { return value.doubleValue }
            if let value = credits["balance"] as? String { return Double(value) }
            return nil
        }()
        // The usage response is authoritative; JWT payloads are display-only
        // fallbacks and never authorize requests or change account routing.
        let access = claims(tokens["access_token"] as? String)
        let identity = claims(tokens["id_token"] as? String)
        let accessProfile = access["https://api.openai.com/profile"] as? [String: Any] ?? [:]
        let identityProfile = identity["https://api.openai.com/profile"] as? [String: Any] ?? [:]
        let candidates = [payload["email"], accessProfile["email"], access["email"],
                          identityProfile["email"], identity["email"]]
        return Self(accountEmail: candidates.compactMap { email($0 as? String) }.first,
                    creditBalance: balance)
    }

    private static func email(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.utf8.count <= 320, value.contains("@"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return value
    }

    private static func claims(_ token: String?) -> [String: Any] {
        guard let token, token.utf8.count <= 65_536 else { return [:] }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return [:] }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        else { return [:] }
        return object
    }
}
