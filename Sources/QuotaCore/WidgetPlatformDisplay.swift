import Foundation

/// Canonical platform names for widget and companion surfaces.
///
/// Widget rows must never show a raw provider id slug (e.g. lowercase `cursor`).
/// Keys stay lowercase for wiring; titles are always owner-facing labels.
public enum WidgetPlatformDisplay {
    private static let titlesByCanonicalKey: [String: String] = [
        "anthropic": "Claude Code",
        "openai": "Codex",
        "google-antigravity": "Antigravity",
        "cursor": "Cursor",
        "xai": "xAI",
        "grok": "Grok",
        "grok-bot": "Grok Bot",
        "minimax": "MiniMax",
        "muse-assist": "Muse Assist",
        "muse-code": "Muse Code",
        "kimi": "Kimi",
        "github-copilot": "GitHub Copilot",
        "windsurf": "Windsurf",
        "gemini-cli": "Gemini CLI",
    ]

    /// Resolves the human-readable platform title for a canonical provider key.
    public static func title(
        canonicalKey: String,
        manifestProviderLabel: String? = nil,
        wireProvider: String? = nil
    ) -> String {
        let key = canonicalKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let known = titlesByCanonicalKey[key] { return known }

        if let manifest = manifestProviderLabel?.trimmingCharacters(in: .whitespacesAndNewlines), !manifest.isEmpty {
            let manifestKey = manifest.lowercased()
            if let known = titlesByCanonicalKey[manifestKey] { return known }
            if manifest != manifestKey || manifest.contains(" ") {
                return manifest
            }
        }

        if let wire = wireProvider?.trimmingCharacters(in: .whitespacesAndNewlines), !wire.isEmpty {
            if let known = titlesByCanonicalKey[wire.lowercased()] { return known }
            // Preserve mixed-case / spaced wire names; only fall through for
            // raw lowercase slugs that match the canonical key.
            if wire != wire.lowercased() || wire.contains(" ") {
                return wire
            }
        }

        if let known = titlesByCanonicalKey[key] { return known }
        return key
    }

    /// Whether `title` is just the lowercase provider id, not a display name.
    public static func isRawProviderSlug(_ title: String, canonicalKey: String) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let key = canonicalKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == key && trimmed == trimmed.lowercased()
    }

    /// Resolves the human-readable platform subtitle, mirroring the Mac app's
    /// `displaySubtitle` and `planCostRenewalDetail`.
    ///
    /// Order of precedence:
    /// 1. Pool subtitle (e.g. "Gemini", "Third-Party" for Antigravity)
    /// 2. Custom subtitle if set by the user (`userSubtitle`)
    /// 3. Plan / Cost / Renewal string if `showCostAndRenewal` is enabled
    /// 4. User-entered plan name (`userPlanName`)
    /// 5. Detected/automatic plan name (`detectedPlanName` or `automaticPlanName`)
    /// 6. Provider-specific fallback (e.g. "free" for Muse Assist)
    public static func subtitle(
        planMetadata: PlanMetadata? = nil,
        automaticPlanName: String? = nil,
        poolSubtitle: String? = nil,
        providerKey: String? = nil
    ) -> String? {
        if let pool = poolSubtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !pool.isEmpty {
            return pool
        }
        if let meta = planMetadata {
            if let custom = meta.userSubtitle?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
                return custom
            }
            if meta.showCostAndRenewal == true {
                let plan = meta.userPlanName ?? meta.detectedPlanName ?? automaticPlanName ?? ""
                let cost = meta.userCostUsd ?? ""
                let renewal = (meta.userRenewalDateText ?? "").isEmpty ? "" : "Renews \(meta.userRenewalDateText!)"
                let parts = [plan, cost, renewal].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if !parts.isEmpty {
                    return parts.joined(separator: " · ")
                }
            }
            if let userPlan = meta.userPlanName?.trimmingCharacters(in: .whitespacesAndNewlines), !userPlan.isEmpty {
                return userPlan
            }
            if let detected = meta.detectedPlanName?.trimmingCharacters(in: .whitespacesAndNewlines), !detected.isEmpty {
                return detected
            }
        }
        if let auto = automaticPlanName?.trimmingCharacters(in: .whitespacesAndNewlines), !auto.isEmpty {
            return auto
        }
        let key = providerKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if key == "muse-assist" {
            return "free"
        }
        return nil
    }
}
