import AppKit
import SwiftUI
import XCTest
@testable import CodeCaps
import QuotaCore

/// Renders the Glance popover to PNG so a person can look at it: both views of
/// the This Mac / Fleet Reported switch, All on and All off with a mix of
/// per-row bells, the two Antigravity pool marks, Cursor's "1m" window, the
/// fleet empty state, in Light and Dark.
///
/// Evidence, not an assertion about pixels, and CI does not depend on it: with
/// `CODECAPS_GLANCE_RENDER_DIR` unset the test skips.  Nothing it writes is
/// committed.
///
///     CODECAPS_GLANCE_RENDER_DIR=/some/dir swift test --filter GlanceRenderTests
@MainActor
final class GlanceRenderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let iso = ISO8601DateFormatter()

    private func window(
        _ id: String,
        provider: String,
        label: String,
        token: String?,
        remaining: Double?,
        resetIn: TimeInterval?
    ) -> QuotaWindow {
        QuotaWindow(
            id: id,
            provider: provider,
            providerKey: provider,
            label: label,
            remainingPercent: remaining,
            remainingUnknown: remaining == nil,
            resetAt: resetIn.map { iso.string(from: now.addingTimeInterval($0)) },
            window: token,
            occurredAt: iso.string(from: now.addingTimeInterval(-60)),
            source: provider)
    }

    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    /// Every provider, with the longest realistic values: 100%, "6d 23h 59m",
    /// "17d 4h 57m" and a monthly Cursor plan.
    private var localWindows: [QuotaWindow] {
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
            window("grok-bot-weekly", provider: "grok-bot", label: "Grok Bot weekly", token: "weekly",
                   remaining: 44, resetIn: 5 * day + 12 * hour),
            window("minimax-5h", provider: "minimax", label: "MiniMax Code (5h window)", token: "5h",
                   remaining: 92, resetIn: 3 * hour + 10 * 60),
            window("minimax-weekly", provider: "minimax", label: "Weekly", token: "weekly",
                   remaining: 81, resetIn: 6 * day + 1 * hour),
        ]
    }

    private var fleetGroups: [FleetWindowGroup] {
        [
            FleetWindowGroup(id: "mac-mini", title: "Mac mini", windows: [
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
            FleetWindowGroup(id: "build-box", title: "build-box", windows: [
                window("bb:codex-5h", provider: "openai", label: "5-hour window", token: "5h",
                       remaining: 76, resetIn: 1 * hour + 12 * 60),
                window("bb:codex-7d", provider: "openai", label: "Weekly window", token: "weekly",
                       remaining: 58, resetIn: 3 * day + 9 * hour),
            ]),
        ]
    }

    private func makeModel(view: GlanceViewMode, alarmsAll: Bool, fleet: Bool) -> (MonitorModel, UserDefaults, String) {
        let suite = "com.jays.codecaps.render." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "localEnabled")  // keeps `start()` and readers out of it
        let model = MonitorModel(defaults: defaults)
        model.injectForTests(sections: QuotaResponse(generatedAt: "", windows: localWindows).platformSections(now: now),
                             now: now)
        if fleet {
            model.injectFleetForTests(groups: fleetGroups, checkedAt: now)
        } else {
            model.injectFleetForTests(groups: [], checkedAt: now)
        }
        model.glanceView = view
        model.alarmsAll = alarmsAll
        if !alarmsAll {
            // A mix: some providers picked, some not.
            for id in ["anthropic", "google-antigravity:gemini", "cursor"] {
                model.alarmManager.setProviderAlarm(true, for: id)
            }
        }
        return (model, defaults, suite)
    }

    private func render(_ name: String, view: GlanceViewMode, alarmsAll: Bool, fleet: Bool = true,
                        dark: Bool, into directory: URL) throws {
        let (model, defaults, suite) = makeModel(view: view, alarmsAll: alarmsAll, fleet: fleet)
        defer { defaults.removePersistentDomain(forName: suite) }
        let height = QuotaGlanceMetrics.popoverHeight(for: model)
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let content = GlancePopover(model: model, openConsole: { _ in }, openSettings: {}, laysOutForSnapshot: true)
            .frame(width: Metrics.glanceWidth, height: height)
            .environment(\.colorScheme, dark ? .dark : .light)

        var image: NSImage?
        appearance.performAsCurrentDrawingAppearance {
            let renderer = ImageRenderer(content: content)
            renderer.scale = 2
            image = renderer.nsImage
        }
        guard let image, let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else {
            throw XCTSkip("ImageRenderer produced no image in this session")
        }
        try png.write(to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"))
    }

    func testRenderGlancePopoverGallery() throws {
        guard let path = ProcessInfo.processInfo.environment["CODECAPS_GLANCE_RENDER_DIR"], !path.isEmpty else {
            throw XCTSkip("Set CODECAPS_GLANCE_RENDER_DIR to render the Glance popover")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            try render("glance-thismac-all-on", view: .thisMac, alarmsAll: true, dark: dark, into: directory)
            try render("glance-thismac-all-off", view: .thisMac, alarmsAll: false, dark: dark, into: directory)
            try render("glance-fleet-all-on", view: .fleetReported, alarmsAll: true, dark: dark, into: directory)
            try render("glance-fleet-all-off", view: .fleetReported, alarmsAll: false, dark: dark, into: directory)
            try render("glance-fleet-empty", view: .fleetReported, alarmsAll: true, fleet: false,
                       dark: dark, into: directory)
        }
    }
}
