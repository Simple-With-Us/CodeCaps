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
        let assetName = assetName(for: providerKey)
        #if canImport(UIKit)
        if let image = UIImage(named: assetName) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            fallbackBadge
        }
        #elseif canImport(AppKit)
        if let image = NSImage(named: NSImage.Name(assetName)) {
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            fallbackBadge
        }
        #else
        fallbackBadge
        #endif
    }

    private var fallbackBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(WidgetPresentation.providerColor(providerKey: providerKey).opacity(0.2))
            Text(initial(for: providerKey))
                .font(.system(size: size * 0.55, weight: .bold, design: .rounded))
                .foregroundColor(WidgetPresentation.providerColor(providerKey: providerKey))
        }
        .frame(width: size, height: size)
    }

    private func initial(for key: String) -> String {
        let low = key.lowercased()
        if low.contains("claude") || low.contains("anthropic") { return "C" }
        if low.contains("openai") || low.contains("codex") { return "O" }
        if low.contains("cursor") { return "Cu" }
        if low.contains("minimax") { return "M" }
        if low.contains("antigravity") { return "A" }
        if low.contains("grok") { return "G" }
        if low.contains("gemini") { return "Ge" }
        return String(key.prefix(1)).uppercased()
    }

    private func assetName(for key: String) -> String {
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
        return "provider-antigravity"
    }
}

// MARK: - Mini Progress Bar

struct MiniProgressBar: View {
    let fraction: Double
    let color: Color
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))
                    .frame(height: height)
                Capsule()
                    .fill(color)
                    .frame(width: max(3, proxy.size.width * CGFloat(fraction)), height: height)
            }
        }
        .frame(height: height)
    }
}

// MARK: - Overview Small View

struct OverviewSmallView: View {
    let entry: CodeCapsWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 5) {
                Circle()
                    .fill(WidgetColors.teal)
                    .frame(width: 7, height: 7)
                Text("CodeCaps")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer()
                if let first = entry.platforms.first, !first.countdown().isEmpty {
                    Text(first.countdown())
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
            }

            Spacer(minLength: 0)

            // Top 2 Platforms
            let displayed = Array(entry.platforms.prefix(2))
            if displayed.isEmpty {
                Text("No AI subscriptions active")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(displayed) { platform in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                ProviderMarkView(providerKey: platform.providerKey, itemId: platform.id, size: 14)
                                Text(platform.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(1)
                                Spacer()
                                Text(platform.displayPercent)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .foregroundColor(platform.statusColor)
                            }
                            MiniProgressBar(
                                fraction: platform.progressFraction,
                                color: platform.statusColor,
                                height: 3.5
                            )
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            // Footer
            HStack {
                Text(entry.isPlaceholder ? "Preview" : "\(entry.platforms.count) Plans")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if let updated = entry.lastUpdated {
                    Text(updated, style: .time)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
    }
}

// MARK: - Overview Medium View

struct OverviewMediumView: View {
    let entry: CodeCapsWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(WidgetColors.teal)
                    .frame(width: 8, height: 8)
                Text("CodeCaps")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text("·" + widgetSentenceGap + "AI Plan Quotas")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                if let updated = entry.lastUpdated {
                    Text(updated, style: .time)
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(.secondary)
                } else if entry.isPlaceholder {
                    Text("Sample Data")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }

            Divider()
                .opacity(0.5)

            // 4 Items in 2x2 grid or list
            let displayed = Array(entry.platforms.prefix(4))
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 10) {
                ForEach(displayed) { platform in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            ProviderMarkView(providerKey: platform.providerKey, itemId: platform.id, size: 16)
                            Text(platform.title)
                                .font(.system(size: 12, weight: .semibold))
                                .lineLimit(1)
                            Spacer()
                            Text(platform.displayPercent)
                                .font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundColor(platform.statusColor)
                        }
                        MiniProgressBar(
                            fraction: platform.progressFraction,
                            color: platform.statusColor,
                            height: 4
                        )
                        HStack {
                            Text(platform.subtitle)
                                .font(.system(size: 9, weight: .regular))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            Spacer()
                            if !platform.countdown().isEmpty {
                                Text(platform.countdown())
                                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
    }
}

// MARK: - Overview Large View

struct OverviewLargeView: View {
    let entry: CodeCapsWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(WidgetColors.teal)
                    .frame(width: 9, height: 9)
                Text("CodeCaps")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Spacer()
                Text("\(entry.platforms.count) Active Plans")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(WidgetColors.secondaryBackground)
                    .clipShape(Capsule())
            }

            Divider()
                .opacity(0.5)

            // Up to 6 platforms with allowance windows
            let displayed = Array(entry.platforms.prefix(6))
            VStack(spacing: 8) {
                ForEach(displayed) { platform in
                    HStack(spacing: 10) {
                        ProviderMarkView(providerKey: platform.providerKey, itemId: platform.id, size: 24)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(platform.title)
                                    .font(.system(size: 13, weight: .semibold))
                                Spacer()
                                Text(platform.displayPercent)
                                    .font(.system(size: 13, weight: .bold, design: .rounded))
                                    .foregroundColor(platform.statusColor)
                            }

                            MiniProgressBar(
                                fraction: platform.progressFraction,
                                color: platform.statusColor,
                                height: 4
                            )

                            HStack {
                                Text(platform.subtitle)
                                    .font(.system(size: 10))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                Spacer()
                                if !platform.countdown().isEmpty {
                                    Text("resets in " + platform.countdown())
                                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .padding(6)
                    .background(WidgetColors.secondaryBackground.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }

            Spacer(minLength: 0)

            // Footer
            HStack {
                if let updated = entry.lastUpdated {
                    Text("Updated " + DateFormatter.localizedString(from: updated, dateStyle: .none, timeStyle: .short))
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("CodeCaps AI Monitor")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
        .padding(14)
    }
}

// MARK: - Single Provider Focus View

struct ProviderFocusView: View {
    let entry: CodeCapsWidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        let platform = entry.primaryPlatform ?? entry.platforms.first ?? WidgetPresentation.placeholders[0]

        switch family {
        case .systemMedium:
            mediumFocusView(for: platform)
        default:
            smallFocusView(for: platform)
        }
    }

    private func smallFocusView(for platform: WidgetPlatformItem) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                ProviderMarkView(providerKey: platform.providerKey, itemId: platform.id, size: 14)
                Text(platform.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
            }

            Spacer(minLength: 0)

            // Circular Gauge
            ZStack {
                Circle()
                    .stroke(Color.primary.opacity(0.12), lineWidth: 9)
                Circle()
                    .trim(from: 0, to: CGFloat(platform.progressFraction))
                    .stroke(
                        platform.statusColor,
                        style: StrokeStyle(lineWidth: 9, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 1) {
                    Text(platform.displayPercent)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundColor(.primary)
                    Text("remaining")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 72, height: 72)

            Spacer(minLength: 0)

            HStack {
                if !platform.countdown().isEmpty {
                    Text("Resets in " + platform.countdown())
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    Text(platform.subtitle)
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(12)
    }

    private func mediumFocusView(for platform: WidgetPlatformItem) -> some View {
        HStack(spacing: 16) {
            // Left: Gauge
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(Color.primary.opacity(0.12), lineWidth: 10)
                    Circle()
                        .trim(from: 0, to: CGFloat(platform.progressFraction))
                        .stroke(
                            platform.statusColor,
                            style: StrokeStyle(lineWidth: 10, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))

                    VStack(spacing: 1) {
                        ProviderMarkView(providerKey: platform.providerKey, itemId: platform.id, size: 20)
                        Text(platform.displayPercent)
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                    }
                }
                .frame(width: 80, height: 80)

                Text(platform.title)
                    .font(.system(size: 12, weight: .bold))
                    .lineLimit(1)
            }
            .frame(width: 100)

            // Right: Windows and details
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(platform.subtitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    if !platform.countdown().isEmpty {
                        Text("Reset " + platform.countdown())
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(WidgetColors.secondaryBackground)
                            .clipShape(Capsule())
                    }
                }

                if platform.windows.isEmpty {
                    Text("No individual window breakdown reported.")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                } else {
                    VStack(spacing: 6) {
                        ForEach(platform.windows) { win in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(win.label)
                                        .font(.system(size: 11, weight: .medium))
                                    Spacer()
                                    Text(win.displayPercent)
                                        .font(.system(size: 11, weight: .bold, design: .rounded))
                                        .foregroundColor(win.statusColor)
                                }
                                MiniProgressBar(
                                    fraction: max(0.0, min(1.0, (win.remainingPercent ?? 0.0) / 100.0)),
                                    color: win.statusColor,
                                    height: 3.5
                                )
                            }
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .padding(14)
    }
}

// MARK: - Lock Screen & Accessory Views

struct AccessoryView: View {
    let entry: CodeCapsWidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        let platform = entry.primaryPlatform ?? entry.platforms.first ?? WidgetPresentation.placeholders[0]

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
                    Text(platform.title)
                        .font(.system(size: 12, weight: .bold))
                    Spacer()
                    Text(platform.displayPercent)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                MiniProgressBar(fraction: platform.progressFraction, color: .primary, height: 4)
                HStack {
                    Text(platform.subtitle)
                        .font(.system(size: 9))
                    Spacer()
                    if !platform.countdown().isEmpty {
                        Text(platform.countdown())
                            .font(.system(size: 9, design: .monospaced))
                    }
                }
                .foregroundColor(.secondary)
            }

        case .accessoryInline:
            let pct = platform.displayPercent
            let cd = platform.countdown()
            Text("\(platform.title): \(pct)\(cd.isEmpty ? "" : " · " + cd)")

        default:
            Text("CodeCaps")
        }
    }
}
