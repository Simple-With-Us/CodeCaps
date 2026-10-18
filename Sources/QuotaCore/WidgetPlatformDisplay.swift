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
}
