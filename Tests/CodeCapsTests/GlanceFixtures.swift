import AppKit
import SwiftUI
import XCTest
@testable import CodeCaps
import QuotaCore

private final class ActiveWindow: NSWindow {
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
}

/// Demo readings and a snapshot helper shared by the two tests that draw the
/// Glance popover and the Console to PNG.  The numbers are invented: they are
/// chosen to show the longest realistic values ("100%", "6d 23h",
/// "17d 4h"), not to describe anyone's real accounts.
@MainActor
enum GlanceFixtures {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let hour: TimeInterval = 3_600
    static let day: TimeInterval = 86_400
    private static let iso = ISO8601DateFormatter()

    static func window(
        _ id: String,
        provider: String,
        label: String,
        token: String?,
        remaining: Double?,
        resetIn: TimeInterval?,
        source: String? = nil,
        model: String? = nil
    ) -> QuotaWindow {
        QuotaWindow(
            id: id,
            provider: provider,
            providerKey: provider,
            modelId: model,
            label: label,
            remainingPercent: remaining,
            remainingUnknown: remaining == nil,
            resetAt: resetIn.map { iso.string(from: now.addingTimeInterval($0)) },
            window: token,
            occurredAt: iso.string(from: now.addingTimeInterval(-60)),
            source: source ?? (provider == "google-antigravity" ? "Antigravity quota summary" : provider))
    }

    /// Every provider, with the longest realistic values and a monthly Cursor plan.
    static var localWindows: [QuotaWindow] {
        [
            window("claude-5h", provider: "anthropic", label: "5-hour window", token: "5h",
                   remaining: 13, resetIn: hour + 47 * 60),
            window("claude-7d", provider: "anthropic", label: "7-day window", token: "168h",
                   remaining: 98, resetIn: 4 * day + 10 * hour + 47 * 60),
            window("codex-5h", provider: "openai", label: "5-hour window", token: "5h",
                   remaining: 100, resetIn: 4 * hour + 41 * 60),
            window("codex-7d", provider: "openai", label: "Weekly window", token: "weekly",
                   remaining: 100, resetIn: 6 * day + 23 * hour + 59 * 60),
            window("antigravity:gemini:5h", provider: "google-antigravity", label: "Gemini Models · 5-hour",
                   token: "5h", remaining: 87, resetIn: 4 * hour + 54 * 60),
            window("antigravity:gemini:weekly", provider: "google-antigravity", label: "Gemini Models · Weekly",
                   token: "weekly", remaining: 64, resetIn: 5 * day + 2 * hour),
            window("antigravity:third-party:5h", provider: "google-antigravity", label: "Third-Party Models · 5-hour",
                   token: "5h", remaining: 40, resetIn: 2 * hour + 5 * 60),
            window("antigravity:third-party:weekly", provider: "google-antigravity", label: "Third-Party Models · Weekly",
                   token: "weekly", remaining: 18, resetIn: 3 * day + 7 * hour),
            window("local-mac:cursor:plan", provider: "cursor", label: "Included plan", token: "billing-cycle",
                   remaining: 62, resetIn: 17 * day + 4 * hour + 57 * 60),
            window("grok-weekly", provider: "xai", label: "Weekly credits", token: "weekly",
                   remaining: 71, resetIn: 2 * day + 3 * hour),
        ] + grokBotWindows + miniMaxWindows(prefix: "")
    }

    /// Grok Bot as the owner's Mac reports it: two readers speak for one weekly
    /// allowance, Cursor's DashboardService and the `gbu` CLI, and a `gbu` that
    /// cannot read adds a placeholder with no reading and no cadence on top.
    /// The row must still draw ONE weekly meter (owner delta 2026-09-30: a stray
    /// extra, empty "7d" bar).
    static var grokBotWindows: [QuotaWindow] {
        [
            window("local-mac:grok-bot:weekly", provider: "grok-bot", label: "Grok Bot weekly", token: "weekly",
                   remaining: 44.4, resetIn: 5 * day + 12 * hour, source: "Cursor DashboardService"),
            window("local-mac:grok-bot:gbu-weekly", provider: "grok-bot", label: "Grok Bot weekly", token: "weekly",
                   remaining: 44.38, resetIn: 5 * day + 12 * hour, source: "gbu"),
            window("local-mac:grok-bot:gbu-unknown", provider: "grok-bot", label: "Grok Bot weekly", token: nil,
                   remaining: nil, resetIn: nil, source: "gbu"),
        ]
    }

    /// MiniMax as its reader reports it: a "general" 4h and weekly pair, which
    /// the row meters, and a "video" daily and weekly pair, which it does not.
    static func miniMaxWindows(prefix: String) -> [QuotaWindow] {
        [
            window("\(prefix)general:interval", provider: "minimax", label: "general (4h window)", token: "4h",
                   remaining: 92, resetIn: 3 * hour + 10 * 60, model: "general"),
            window("\(prefix)general:weekly", provider: "minimax", label: "general (1w window)", token: "1w",
                   remaining: 81, resetIn: 4 * day + 2 * hour + 42 * 60, model: "general"),
            window("\(prefix)video:interval", provider: "minimax", label: "video (1d window)", token: "1d",
                   remaining: 100, resetIn: 17 * hour + 5 * 60, model: "video"),
            window("\(prefix)video:weekly", provider: "minimax", label: "video (1w window)", token: "1w",
                   remaining: 96, resetIn: 4 * day + 2 * hour + 42 * 60, model: "video"),
        ]
    }

    /// A third window on Claude, as its real reports carry, so the row has
    /// something to expand.
    static var claudeSonnetWindow: QuotaWindow {
        window("claude-7d-sonnet", provider: "anthropic", label: "7-day window (Sonnet)", token: "168h",
               remaining: 99, resetIn: 4 * day + 10 * hour + 47 * 60)
    }

    static var fleetGroups: [FleetWindowGroup] {
        [
            FleetWindowGroup(id: "mac-mini", title: "Mac mini", windows: miniMaxWindows(prefix: "mini:") + [
                window("mini:claude-5h", provider: "anthropic", label: "5-hour window", token: "5h",
                       remaining: 0, resetIn: 38 * 60),
                window("mini:claude-7d", provider: "anthropic", label: "7-day window", token: "168h",
                       remaining: 22, resetIn: 2 * day + 5 * hour),
                window("mini:antigravity:gemini:5h", provider: "google-antigravity", label: "Gemini Models · 5-hour",
                       token: "5h", remaining: 100, resetIn: 5 * hour),
                window("mini:antigravity:gemini:weekly", provider: "google-antigravity",
                       label: "Gemini Models · Weekly", token: "weekly", remaining: 90, resetIn: 6 * day),
                window("mini:antigravity:third-party:5h", provider: "google-antigravity",
                       label: "Third-Party Models · 5-hour", token: "5h", remaining: 55, resetIn: 3 * hour),
                window("mini:antigravity:third-party:weekly", provider: "google-antigravity",
                       label: "Third-Party Models · Weekly", token: "weekly", remaining: 47, resetIn: 4 * day),
            ]),
            FleetWindowGroup(id: "chatgpt.com", title: FleetOrigin.title(for: "chatgpt.com"), windows: [
                window("gpt:codex-5h", provider: "openai", label: "5-hour window", token: "5h",
                       remaining: 76, resetIn: 1 * hour + 12 * 60, source: "chatgpt.com"),
                window("gpt:codex-7d", provider: "openai", label: "Weekly window", token: "weekly",
                       remaining: 58, resetIn: 3 * day + 9 * hour, source: "chatgpt.com"),
            ]),
        ]
    }

    /// A model with the demo readings and its own throwaway defaults.  The
    /// caller removes `suite` from `defaults` when done.
    static func makeModel(
        view: GlanceViewMode,
        alarmsAll: Bool,
        fleet: Bool,
        pickedAlarms: [String] = ["anthropic", "google-antigravity:gemini", "cursor"],
        localReadersOn: Bool = false,
        extraWindows: [QuotaWindow] = [],
        signedOut: Set<String> = [],
        historyURL: URL? = nil,
        alertHistory: [RunawayAlertRecord] = []
    ) -> (model: MonitorModel, defaults: UserDefaults, suite: String) {
        let suite = "com.jays.codecaps.render." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        // Nothing here calls `start()`, so no reader runs either way; this only
        // decides what the footer and the empty states say.
        defaults.set(localReadersOn, forKey: "localEnabled")
        if let data = try? JSONEncoder().encode(alertHistory) {
            defaults.set(data, forKey: "runawayAlertHistory")
        }
        let model = MonitorModel(defaults: defaults, burnRateHistoryURL: historyURL)
        // A signed-out provider reports no windows and the issue its reader
        // gives, which is what the row turns into "not signed in".
        let windows = (localWindows + extraWindows).filter { !signedOut.contains($0.providerKey ?? $0.provider) }
        var issues: [String: String] = [:]
        if signedOut.contains("anthropic") { issues["anthropic"] = ClaudeLoginState.signedOut.issue }
        model.injectForTests(sections: QuotaResponse(generatedAt: "", windows: windows).platformSections(now: now),
                             now: now, issues: issues)
        if historyURL != nil { model.injectLocalHistorySourceForTests(windows) }
        model.injectFleetForTests(groups: fleet ? fleetGroups : [], checkedAt: now)
        model.glanceView = view
        model.alarmsAll = alarmsAll
        if !alarmsAll {
            for id in pickedAlarms {
                model.alarmManager.setProviderAlarm(true, for: id)
            }
        }
        return (model, defaults, suite)
    }

    /// Draws a SwiftUI view into a PNG the way AppKit would on screen —
    /// scroll views, lists and text fields included, which `ImageRenderer`
    /// leaves blank.  `nil` when the session cannot draw offscreen.
    static func png<V: View>(of view: V, size: CGSize, dark: Bool) -> Data? {
        // `controlActiveState` makes SwiftUI draw switches and prominent buttons
        // as they look in the frontmost window rather than greyed out.
        let host = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .environment(\.controlActiveState, .key))
        host.frame = NSRect(origin: .zero, size: size)
        // A window that claims to be key, so the prominent button draws in its
        // accent colour as it does on screen rather than greyed out.
        let window = ActiveWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()

        // Twice the points, so the PNG is sharp at 2x.
        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        window.appearance?.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: rep)
        }
        return rep.representation(using: .png, properties: [:])
    }
}
