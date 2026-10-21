import Foundation

/// Share only provider plan facts and the owner's explicit per-provider fields.
/// Authentication, account emails and unrelated application settings stay local.
public struct PlanMetadata: Codable, Equatable, Sendable {
    public var detectedPlanName: String?
    public var userPlanName: String?
    public var userCostUsd: String?
    public var userRenewalDateText: String?
    public var userSubtitle: String?
    public var showCostAndRenewal: Bool?
    public var hasMismatch: Bool
    public var userUpdatedAt: Double?

    public init(detectedPlanName: String?, customInfo: PlatformCustomInfo?, providerKey: String) {
        self.detectedPlanName = Self.clean(detectedPlanName, limit: 256)
        userPlanName = Self.clean(customInfo?.planName, limit: 256)
        userCostUsd = Self.clean(customInfo?.costUsd, limit: 128)
        userRenewalDateText = Self.clean(customInfo?.renewalDateText, limit: 512)
        userSubtitle = Self.clean(customInfo?.customSubtitle, limit: 1_024)
        userUpdatedAt = customInfo?.updatedAt?.timeIntervalSince1970
        showCostAndRenewal = customInfo?.showCostAndRenewal
        hasMismatch = PlanComparison.disagrees(detected: self.detectedPlanName,
                                               entered: userPlanName, providerKey: providerKey)
    }

    private enum CodingKeys: String, CodingKey {
        case detectedPlanName, userPlanName, userCostUsd, userRenewalDateText, userSubtitle
        case showCostAndRenewal, hasMismatch, userUpdatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        detectedPlanName = Self.clean(try? values.decode(String.self, forKey: .detectedPlanName), limit: 256)
        userPlanName = Self.clean(try? values.decode(String.self, forKey: .userPlanName), limit: 256)
        userCostUsd = Self.clean(try? values.decode(String.self, forKey: .userCostUsd), limit: 128)
        userRenewalDateText = Self.clean(try? values.decode(String.self, forKey: .userRenewalDateText), limit: 512)
        userSubtitle = Self.clean(try? values.decode(String.self, forKey: .userSubtitle), limit: 1024)
        showCostAndRenewal = try? values.decode(Bool.self, forKey: .showCostAndRenewal)
        hasMismatch = (try? values.decode(Bool.self, forKey: .hasMismatch)) ?? false
        let revision = try? values.decode(Double.self, forKey: .userUpdatedAt)
        userUpdatedAt = revision.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }

    private static func clean(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let text = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init).joined().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        var bounded = ""
        var bytes = 0
        for scalar in text.unicodeScalars {
            let part = String(scalar)
            guard bytes + part.utf8.count <= limit else { break }
            bounded += part
            bytes += part.utf8.count
        }
        return bounded.isEmpty ? nil : bounded
    }
}

/// Compares explicit plan names; never infers a plan from cost, quotas or keywords.
public enum PlanComparison {
    public static func disagrees(detected: String?, entered: String?, providerKey: String) -> Bool {
        guard let detected = normalized(detected, providerKey: providerKey),
              let entered = normalized(entered, providerKey: providerKey) else { return false }
        if detected == entered { return false }
        // A generic Max declaration makes no claim about the multiplier.
        if providerKey == "anthropic", (detected == "max" || entered == "max"),
           [detected, entered].allSatisfy({ $0 == "max" || $0.range(of: #"^max[1-9][0-9]*x$"#, options: .regularExpression) != nil }) {
            return false
        }
        return true
    }

    private static func normalized(_ raw: String?, providerKey: String) -> String? {
        guard var text = raw?.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        let names: [String]
        switch providerKey {
        case "anthropic": names = ["anthropic claude", "claude", "anthropic"]
        case "openai": names = ["chatgpt", "codex", "openai"]
        case "github-copilot": names = ["github copilot", "copilot", "github"]
        default: names = []
        }
        // Strip only a separator after the provider name, never punctuation
        // that belongs to the tier: "GitHub Copilot Pro+" and "Pro+" must
        // reach the key filter identically, and a raw token such as
        // "chatgpt_plus" must match an entered "ChatGPT Plus".
        let separators = CharacterSet(charactersIn: " :_-").union(.whitespacesAndNewlines)
        for name in names where [" ", ":", "_", "-"].contains(where: { text.hasPrefix(name + $0) }) {
            text = String(text.dropFirst(name.count)).trimmingCharacters(in: separators)
            break
        }
        text = text.replacingOccurrences(of: "×", with: "x")
        let key = text.unicodeScalars.filter { (CharacterSet.alphanumerics.contains($0) || $0 == "+") }.map(String.init).joined()
        guard !key.isEmpty, !["unknown", "unavailable", "notreported"].contains(key) else { return nil }
        // Raw Copilot API plan tokens (for example `individual_pro`) name
        // the same tiers users type; alias them to the user-facing forms so
        // a standard entry is not a false mismatch (Sentry on #277).
        if providerKey == "github-copilot", let alias = copilotTokenAliases[key] {
            return alias
        }
        return key
    }

    private static let copilotTokenAliases: [String: String] = [
        "individualpro": "pro",
        "individualproplus": "pro+",
        "copilotpro": "pro",
        "copilotproplus": "pro+",
    ]
}
