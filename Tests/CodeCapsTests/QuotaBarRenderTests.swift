import AppKit
import SwiftUI
import XCTest
@testable import CodeCaps
import QuotaCore

/// Renders the two-segment quota bar to PNG so a person can look at it, in both
/// appearances, for the states that matter: 0 / 15 / 50 / 85 / 100 percent
/// remaining, the marker at a tenth, half and nine tenths of the period, Cursor's
/// monthly plan, and the stale and unknown looks.
///
/// This is evidence, not an assertion about pixels, and CI does not depend on
/// it: with `CODECAPS_BAR_RENDER_DIR` unset the test skips, and it skips when
/// SwiftUI's `ImageRenderer` cannot produce an image in the current session.
/// Nothing it writes is committed.
///
///     CODECAPS_BAR_RENDER_DIR=/some/dir swift test --filter QuotaBarRenderTests
@MainActor
final class QuotaBarRenderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let iso = ISO8601DateFormatter()

    // MARK: Fixtures

    private func window(
        label: String,
        token: String?,
        remaining: Double?,
        resetIn: TimeInterval?,
        observedAgo: TimeInterval = 0,
        provider: String = "anthropic"
    ) -> QuotaWindowSnapshot {
        QuotaWindowSnapshot(window: QuotaWindow(
            id: "\(provider):\(label)",
            provider: provider,
            providerKey: provider,
            label: label,
            remainingPercent: remaining,
            remainingUnknown: remaining == nil,
            resetAt: resetIn.map { iso.string(from: now.addingTimeInterval($0)) },
            window: token,
            occurredAt: iso.string(from: now.addingTimeInterval(-observedAgo))), now: now)
    }

    /// A five-hour window `fraction` of the way through its period.
    private func fiveHour(remaining: Double?, elapsed fraction: Double, observedAgo: TimeInterval = 0) -> QuotaWindowSnapshot {
        window(label: "5h window", token: "5h", remaining: remaining,
               resetIn: 5 * 3_600 * (1 - fraction), observedAgo: observedAgo)
    }

    private func row(_ windows: [QuotaWindowSnapshot], provider: String, title: String) -> DisplaySection {
        DisplaySection(
            id: provider,
            providerKey: provider,
            title: title,
            platformTitle: title,
            section: QuotaPlatformSection(providerKey: provider, providerLabel: title, via: nil, expected: true, windows: windows),
            poolKey: nil,
            remainingPercent: windows.compactMap(\.remainingPercent).min(),
            resetAt: windows.compactMap(\.resetAt).min(),
            maskedWindowIds: [])
    }

    // MARK: Gallery

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .frame(width: 170, alignment: .leading)
    }

    private func labelled(_ text: String, _ snapshot: QuotaWindowSnapshot) -> some View {
        HStack(spacing: 10) {
            caption(text)
            GlanceMeter(snapshot: snapshot, now: now)
                .frame(width: Metrics.glanceMeterWidth, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            content()
        }
    }

    private var gallery: some View {
        let cursorPlan = window(label: "Included plan", token: "billing-cycle", remaining: 15,
                                resetIn: 16 * 86_400, provider: "cursor")
        let claude = row([
            fiveHour(remaining: 92, elapsed: 0.4),
            window(label: "7d window", token: "168h", remaining: 11, resetIn: 4 * 86_400),
        ], provider: "anthropic", title: "Claude")
        let cursor = row([cursorPlan], provider: "cursor", title: "Cursor")
        let codex = row([
            window(label: "7d window", token: "1w", remaining: 0, resetIn: 2 * 86_400, provider: "openai"),
        ], provider: "openai", title: "Codex")

        return VStack(alignment: .leading, spacing: 22) {
            section("Remaining: 0, 15, 50, 85, 100 percent  (marker at half)") {
                ForEach([0.0, 15, 50, 85, 100], id: \.self) { remaining in
                    self.labelled("\(Int(remaining))% remaining", self.fiveHour(remaining: remaining, elapsed: 0.5))
                }
            }
            section("Marker at 10, 50, 90 percent of the period  (50% remaining)") {
                ForEach([0.1, 0.5, 0.9], id: \.self) { fraction in
                    self.labelled("marker at \(Int(fraction * 100))%", self.fiveHour(remaining: 50, elapsed: fraction))
                }
            }
            section("Burning faster than time  /  slower than time") {
                labelled("85% used, 20% elapsed", fiveHour(remaining: 15, elapsed: 0.2))
                labelled("20% used, 80% elapsed", fiveHour(remaining: 80, elapsed: 0.8))
            }
            section("Cursor monthly plan  (was no marker)") {
                labelled("Plan, 15% remaining", cursorPlan)
            }
            section("Unknown and stale") {
                labelled("no reading", fiveHour(remaining: nil, elapsed: 0.5))
                labelled("last reported (3h old)", fiveHour(remaining: 40, elapsed: 0.5, observedAgo: 3 * 3_600))
            }
            section("In a Glance row") {
                VStack(spacing: 0) {
                    GlanceRow(row: claude, now: now, issue: nil, origin: .local, markStyle: .template)
                    GlanceRow(row: cursor, now: now, issue: nil, origin: .local, markStyle: .template)
                    GlanceRow(row: codex, now: now, issue: nil, origin: .local, markStyle: .template)
                }
                .frame(width: Metrics.glanceWidth)
            }
            section("Console row") {
                VStack(alignment: .leading, spacing: 14) {
                    QuotaRow(snapshot: fiveHour(remaining: 85, elapsed: 0.4), now: now, sourceFailed: false, compact: false)
                    QuotaRow(snapshot: cursorPlan, now: now, sourceFailed: false, compact: false)
                    QuotaRow(snapshot: cursorPlan, now: now, sourceFailed: false, compact: true)
                }
                .frame(width: 320)
            }
        }
        .padding(18)
    }

    // MARK: Render

    private func png(of scheme: ColorScheme) throws -> Data {
        let background = scheme == .dark ? Color(red: 0.11, green: 0.12, blue: 0.125) : Color(red: 0.96, green: 0.97, blue: 0.97)
        let content = gallery
            .background(background)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        guard let image = renderer.cgImage else {
            throw XCTSkip("ImageRenderer produced no image in this session.")
        }
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
        return try XCTUnwrap(data)
    }

    func testRendersRepresentativeBarsToPNG() throws {
        guard let directory = ProcessInfo.processInfo.environment["CODECAPS_BAR_RENDER_DIR"], !directory.isEmpty else {
            throw XCTSkip("Set CODECAPS_BAR_RENDER_DIR to write the quota bar PNGs.")
        }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            let data = try png(of: scheme)
            let url = URL(fileURLWithPath: directory).appendingPathComponent("quota-bars-\(name).png")
            try data.write(to: url)
            XCTAssertGreaterThan(data.count, 1_000, "\(name) render is suspiciously small")
            XCTAssertNotNil(NSImage(contentsOf: url), "\(name) render is not a readable image")
        }
    }
}
