import SwiftUI
import WidgetKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Cross-Platform Color Helpers

enum WidgetColors {
    static var background: Color {
        #if canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.black
        #endif
    }

    static var secondaryBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .secondarySystemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .controlBackgroundColor)
        #else
        return Color.gray.opacity(0.15)
        #endif
    }

    static var tertiaryBackground: Color {
        #if canImport(UIKit)
        return Color(uiColor: .tertiarySystemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .underPageBackgroundColor)
        #else
        return Color.gray.opacity(0.08)
        #endif
    }

    static let teal = Color(red: 0.15, green: 0.72, blue: 0.68)
}

// MARK: - Provider Mark / Icon View

struct ProviderMarkView: View {
    let providerKey: String
    /// The row's own id, which names the Antigravity pool: `antigravity-gemini`
    /// wears the colour Gemini star, `antigravity-third-party` the one-colour
    /// star (a template asset, so it follows Light and Dark).
    var itemId: String? = nil
    let size: CGFloat

    init(providerKey: String, itemId: String? = nil, size: CGFloat) {
        self.providerKey = providerKey
        self.itemId = itemId
        self.size = size
    }

    var body: some View {
        if let custom = customMarkImage() {
            custom
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else if let asset = assetName(for: providerKey), let image = bundledImage(named: asset) {
            image
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            fallbackBadge
        }
    }

    private var fallbackBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(Color.secondary.opacity(0.15))
            Image(systemName: "questionmark.square.dashed")
                .font(.system(size: size * 0.55, weight: .medium))
                .foregroundColor(.secondary)
        }
        .frame(width: size, height: size)
    }

    private func customMarkImage() -> Image? {
        let fm = FileManager.default
        guard let groupURL = fm.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshotStore.appGroupId) else {
            return nil
        }
        let cleanKey = providerKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidates = [
            groupURL.appendingPathComponent("CustomMarks", isDirectory: true),
            groupURL.appendingPathComponent("CodeCaps/CustomMarks", isDirectory: true)
        ]
        for dir in candidates {
            for ext in ["png", "svg", "jpg", "jpeg"] {
                let fileURL = dir.appendingPathComponent("\(cleanKey).\(ext)")
                if fm.fileExists(atPath: fileURL.path) {
                    #if canImport(UIKit)
                    if let uiImg = UIImage(contentsOfFile: fileURL.path) {
                        return Image(uiImage: uiImg)
                    }
                    #elseif canImport(AppKit)
                    if let nsImg = NSImage(contentsOf: fileURL) {
                        return Image(nsImage: nsImg)
                    }
                    #endif
                }
            }
        }
        return nil
    }

    private func bundledImage(named name: String) -> Image? {
        #if canImport(UIKit)
        if let img = UIImage(named: name) {
            return Image(uiImage: img)
        }
        #elseif canImport(AppKit)
        if let img = NSImage(named: NSImage.Name(name)) {
            return Image(nsImage: img)
        }
        #endif
        return nil
    }

    private func assetName(for key: String) -> String? {
        let low = key.lowercased()
        let pool = (itemId ?? "").lowercased()
        if low.contains("antigravity") && pool.contains("gemini") { return "provider-gemini" }
        if low.contains("antigravity") && pool.contains("third-party") { return "provider-antigravity" }
        if low.contains("claude") || low.contains("anthropic") { return "provider-claude" }
        if low.contains("openai") || low.contains("codex") { return "provider-openai" }
        if low.contains("cursor") { return "provider-cursor" }
        if low.contains("minimax") { return "provider-minimax" }
        if low.contains("antigravity") { return "provider-antigravity" }
        if low.contains("gemini") { return "provider-gemini" }
        if low.contains("grok-bot") { return "provider-grok-bot" }
        if low.contains("grok") || low.contains("xai") { return "provider-grok" }
        return nil
    }
}

// MARK: - Mini Progress Bar

struct MiniProgressBar: View {
    let fraction: Double
    var color: Color = Color(red: 0.10, green: 0.70, blue: 0.45)
    var elapsedFraction: Double? = nil
    var height: CGFloat = 4

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let totalW = proxy.size.width
            let safeFrac = min(1.0, max(0.0, fraction))
            let remW = CGFloat(safeFrac) * totalW
            let usedW = totalW - remW

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: height)

                if totalW > 0 {
                    HStack(spacing: 0) {
                        if usedW > 0 {
                            Rectangle()
                                .fill(Color(red: 0.86, green: 0.22, blue: 0.22))
                                .frame(width: usedW)
                        }
                        if remW > 0 {
                            Rectangle()
                                .fill(color)
                                .frame(width: remW)
                        }
                    }
                    .clipShape(Capsule())
                    .frame(height: height)
                }

                if let elapsed = elapsedFraction, elapsed >= 0, elapsed <= 1.0, totalW > 0 {
                    let markerX = CGFloat(elapsed) * totalW
                    let markerHeight = max(height + 6, 11)
                    let markerWidth: CGFloat = 2.5

                    // High-contrast halo so the line is unmistakably visible over red and green segments
                    Capsule()
                        .fill(colorScheme == .dark ? Color.black.opacity(0.75) : Color.white.opacity(0.85))
                        .frame(width: markerWidth + 2.0, height: markerHeight + 2.0)
                        .position(x: markerX, y: proxy.size.height / 2)

                    // Prominent pacing marker line crossing the bar
                    Capsule()
                        .fill(colorScheme == .dark ? Color.white : Color.black)
                        .frame(width: markerWidth, height: markerHeight)
                        .position(x: markerX, y: proxy.size.height / 2)
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Honest Empty State View

struct WidgetEmptyStateView: View {
    let title: String
    let subtitle: String

    init(title: String = "No Quotas Synced", subtitle: String = "Open CodeCaps to connect AI subscription plans.") {
        self.title = title
        self.subtitle = subtitle
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "gauge.with.dots.needle.bottom.0percent")
                .font(.system(size: 20))
                .foregroundColor(WidgetColors.teal)
            Text(title)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Widget Header

/// The app mark at top-left, with an optional trailing note on the right.
///
/// This replaces a teal dot plus the word "CodeCaps".  On the small size that
/// word could not fit next to a countdown and wrapped to "CodeCa", and the
/// countdown it crowded out belonged to whichever plan happened to sort first,
/// so a number on screen had nothing to say which plan it described.
struct WidgetHeaderView: View {
    var markSize: CGFloat = 14
    var trailing: String?

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            CodeCapsMarkView(size: markSize)
            Spacer(minLength: 0)
            if let trailing, !trailing.isEmpty {
                Text(trailing)
                    .font(.system(size: markSize - 2, weight: .regular))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Overview Small View

struct OverviewSmallView: View {
    let entry: CodeCapsWidgetEntry
    var pick: WidgetWindowPick = .mostUrgent

    /// Three plans now that the app name, the plan count and the header
    /// countdown gave their rows back.  The caption line is what made the
    /// third row fit: it costs 9pt and says which window the number is.
    private var displayed: [WidgetPlatformItem] {
        Array(entry.platforms.prefix(3))
    }

    var body: some View {
        if entry.platforms.isEmpty {
            WidgetEmptyStateView(
                title: "No Quotas Synced",
                subtitle: "Open CodeCaps to sync"
            )
            .padding(8)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                WidgetHeaderView(markSize: 13)

                Spacer(minLength: 0)

                VStack(spacing: 6) {
                    ForEach(displayed) { platform in
                        PlanBarRow(
                            platform: platform,
                            pick: pick,
                            markSize: 13,
                            titleFont: 11.5,
                            captionFont: 8.5,
                            percentFont: 11.5,
                            barHeight: 3.5
                        )
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(11)
        }
    }
}

// MARK: - Overview Medium View

struct OverviewMediumView: View {
    let entry: CodeCapsWidgetEntry
    var pick: WidgetWindowPick = .mostUrgent
    var columns: Int = 1

    /// A row is now three lines tall (title, bar, caption), so one plan per row
    /// gets fewer rows than two per row does.  Both counts stay inside the
    /// medium widget's height with room to spare.
    private var cap: Int { columns >= 2 ? 4 : 3 }

    private var displayed: [WidgetPlatformItem] {
        Array(entry.platforms.prefix(cap))
    }

    var body: some View {
        if entry.platforms.isEmpty {
            WidgetEmptyStateView(
                title: "No AI Subscription Quotas Synced",
                subtitle: "Open CodeCaps to connect AI subscription plans."
            )
            .padding(14)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                WidgetHeaderView(
                    markSize: 15,
                    trailing: entry.lastUpdated.map {
                        DateFormatter.localizedString(from: $0, dateStyle: .none, timeStyle: .short)
                    }
                )

                Divider().opacity(0.5)

                PlanGrid(
                    platforms: displayed,
                    columns: columns,
                    pick: pick,
                    markSize: 15,
                    titleFont: 12,
                    captionFont: 9,
                    percentFont: 12,
                    barHeight: 4,
                    spacing: 7,
                    horizontalSpacing: 12
                )

                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }
}

// MARK: - Overview Large View

struct OverviewLargeView: View {
    let entry: CodeCapsWidgetEntry
    var pick: WidgetWindowPick = .mostUrgent
    var columns: Int = 1

    /// Seven rows one per row, twelve two per row.  The header dropped the app
    /// name for the mark, which is what paid for the extra row.
    private var cap: Int { columns >= 2 ? 12 : 7 }

    private var displayed: [WidgetPlatformItem] {
        Array(entry.platforms.prefix(cap))
    }

    /// "8 Tracked Plans" when every tracked plan fits, and "7 Of 8 Tracked" when
    /// the size ran out of room.  Saying "8" above seven rows is the same class
    /// of unexplained number the caption rows exist to remove.
    private var countCaption: String {
        let tracked = entry.platforms.count
        guard tracked > displayed.count else { return "\(tracked) Tracked Plans" }
        return "\(displayed.count) Of \(tracked) Tracked"
    }

    var body: some View {
        if entry.platforms.isEmpty {
            WidgetEmptyStateView(
                title: "No AI Subscription Quotas Synced",
                subtitle: "Open CodeCaps on your Mac or iOS to connect and monitor your plans."
            )
            .padding(14)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                WidgetHeaderView(
                    markSize: 16,
                    trailing: countCaption
                )

                Divider().opacity(0.5)

                PlanGrid(
                    platforms: displayed,
                    columns: columns,
                    pick: pick,
                    markSize: 16,
                    titleFont: 12.5,
                    captionFont: 9.5,
                    percentFont: 12.5,
                    barHeight: 4,
                    spacing: 6,
                    horizontalSpacing: 14
                )

                Spacer(minLength: 0)
            }
            .padding(14)
        }
    }
}

// MARK: - Single Provider Focus View

struct ProviderFocusView: View {
    let entry: CodeCapsWidgetEntry
    @Environment(\.widgetFamily) var family

    /// The configured plan when one is set, otherwise the plan nearest its cap.
    private var platform: WidgetPlatformItem? {
        entry.platforms.first ?? entry.primaryPlatform
    }

    private var pick: WidgetWindowPick { entry.windowPick }

    /// The window the gauge and caption describe, so the number on screen and
    /// the caption under it always name the same window.
    private var shownWindow: WidgetWindowItem? {
        platform?.controllingWindow(pick)
    }

    private var shownPercent: Double? {
        shownWindow?.remainingPercent ?? platform?.remainingPercent
    }

    private var shownMasked: Bool {
        shownWindow?.isMasked ?? platform?.isMasked ?? false
    }

    private var fraction: Double {
        guard let pct = shownPercent, !shownMasked else { return 0.0 }
        return max(0.0, min(1.0, pct / 100.0))
    }

    private var statusColor: Color {
        WidgetPresentation.statusColor(percent: shownPercent, isMasked: shownMasked)
    }

    private var captionToken: String {
        if let window = shownWindow { return window.cadenceToken }
        guard let platform else { return "" }
        return WidgetPresentation.shortCadence(cadence: platform.subtitle, label: platform.title)
    }

    private var captionReset: String {
        if let window = shownWindow { return window.resetCaption() }
        return platform?.resetCaption() ?? ""
    }

    var body: some View {
        if let platform {
            switch family {
            case .systemMedium:
                mediumFocusView(for: platform)
            default:
                smallFocusView(for: platform)
            }
        } else {
            WidgetEmptyStateView(
                title: "No Quota Synced",
                subtitle: "Open CodeCaps to connect plans"
            )
            .padding(10)
        }
    }

    private func smallFocusView(for platform: WidgetPlatformItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                CodeCapsMarkView(size: 12)
                ProviderMarkView(providerKey: platform.providerKey, itemId: platform.id, size: 13)
                Text(platform.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: CGFloat(fraction))
                    .stroke(
                        statusColor,
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 1) {
                    Text(WidgetPresentation.displayPercent(percent: shownPercent, isMasked: shownMasked))
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text("Remaining")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 70, height: 70)

            Spacer(minLength: 0)

            WindowCaptionRow(token: captionToken, resetCaption: captionReset, font: 9)
        }
        .padding(12)
    }

    private func mediumFocusView(for platform: WidgetPlatformItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeaderView(markSize: 15)

            HStack(alignment: .top, spacing: 14) {
                // Left: Gauge
                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .stroke(Color.primary.opacity(0.12), lineWidth: 10)
                        Circle()
                            .trim(from: 0, to: CGFloat(fraction))
                            .stroke(
                                statusColor,
                                style: StrokeStyle(lineWidth: 10, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))

                        VStack(spacing: 1) {
                            ProviderMarkView(providerKey: platform.providerKey, itemId: platform.id, size: 20)
                            Text(WidgetPresentation.displayPercent(percent: shownPercent, isMasked: shownMasked))
                                .font(.system(size: 16, weight: .bold, design: .rounded))
                        }
                    }
                    .frame(width: 80, height: 80)

                    Text(platform.title)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(width: 96)

                // Right: every window the plan reports, each with its own
                // caption.  The old header repeated a single subtitle here,
                // which for Cursor read "Monthly fast requests" — a phrase
                // that came from preview data and described nothing the owner
                // could act on.
                VStack(alignment: .leading, spacing: 7) {
                    if platform.windows.isEmpty {
                        WindowCaptionRow(token: captionToken, resetCaption: captionReset, font: 9.5)
                    } else {
                        ForEach(platform.windows) { win in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(win.label)
                                        .font(.system(size: 11, weight: .medium))
                                        .lineLimit(1)
                                    Spacer(minLength: 2)
                                    Text(win.displayPercent)
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundColor(win.statusColor)
                                }
                                MiniProgressBar(
                                    fraction: max(0.0, min(1.0, (win.remainingPercent ?? 0.0) / 100.0)),
                                    color: win.statusColor,
                                    elapsedFraction: win.elapsedFraction(),
                                    height: 3.5
                                )
                                WindowCaptionRow(
                                    token: win.cadenceToken,
                                    resetCaption: win.resetCaption(),
                                    font: 9
                                )
                            }
                        }
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
    }
}

// MARK: - Lock Screen & Accessory Views

struct AccessoryView: View {
    let entry: CodeCapsWidgetEntry
    @Environment(\.widgetFamily) var family

    private var platform: WidgetPlatformItem? {
        entry.platforms.first ?? entry.primaryPlatform
    }

    var body: some View {
        if let platform {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Gauge(value: platform.progressFraction, in: 0...1) {
                        Text(platform.title.prefix(2).uppercased())
                    } currentValueLabel: {
                        Text(platform.displayPercent.replacingOccurrences(of: "%", with: ""))
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .gaugeStyle(.accessoryCircularCapacity)
                }

            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        CodeCapsMarkView(size: 10)
                        Text(platform.title)
                            .font(.system(size: 12, weight: .bold))
                            .lineLimit(1)
                        Spacer(minLength: 2)
                        Text(platform.displayPercent)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    MiniProgressBar(fraction: platform.progressFraction, color: .primary, elapsedFraction: platform.elapsedFraction, height: 4)
                    WindowCaptionRow(
                        token: platform.controllingWindow(entry.windowPick)?.cadenceToken
                            ?? WidgetPresentation.shortCadence(cadence: platform.subtitle, label: platform.title),
                        resetCaption: platform.controllingWindow(entry.windowPick)?.resetCaption() ?? platform.resetCaption(),
                        font: 9
                    )
                }

            case .accessoryInline:
                let pct = platform.displayPercent
                let cd = platform.countdown()
                Text("\(platform.title): \(pct)\(cd.isEmpty ? "" : " " + cd)")

            default:
                Text("CodeCaps")
            }
        } else {
            switch family {
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "gauge.with.dots.needle.bottom.0percent")
                        .font(.system(size: 14))
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 2) {
                    Text("CodeCaps")
                        .font(.system(size: 12, weight: .bold))
                    Text("No quotas synced")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            case .accessoryInline:
                Text("CodeCaps: Open to connect")
            default:
                Text("CodeCaps")
            }
        }
    }
}
