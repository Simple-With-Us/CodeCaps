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
        guard let groupURL = fm.containerURL(forSecurityApplicationGroupIdentifier: "group.com.simplewithus.codecaps") else {
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
                    Rectangle()
                        .fill(Color.primary.opacity(0.85))
                        .frame(width: 1.5, height: height + 2)
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

// MARK: - Overview Small View

struct OverviewSmallView: View {
    let entry: CodeCapsWidgetEntry

    var body: some View {
        if entry.platforms.isEmpty {
            WidgetEmptyStateView(
                title: "No Quotas Synced",
                subtitle: "Open CodeCaps to sync"
            )
            .padding(8)
        } else {
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
                                elapsedFraction: platform.elapsedFraction,
                                height: 3.5
                            )
                        }
                    }
                }

                Spacer(minLength: 0)

                // Footer
                HStack {
                    Text("\(entry.platforms.count) Plans")
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
}

// MARK: - Overview Medium View

struct OverviewMediumView: View {
    let entry: CodeCapsWidgetEntry

    var body: some View {
        if entry.platforms.isEmpty {
            WidgetEmptyStateView(
                title: "No AI Subscription Quotas Synced",
                subtitle: "Open CodeCaps to connect AI subscription plans."
            )
            .padding(14)
        } else {
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
                            elapsedFraction: platform.elapsedFraction,
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
}

// MARK: - Overview Large View

struct OverviewLargeView: View {
    let entry: CodeCapsWidgetEntry

    var body: some View {
        if entry.platforms.isEmpty {
            WidgetEmptyStateView(
                title: "No AI Subscription Quotas Synced",
                subtitle: "Open CodeCaps on your Mac or iOS to connect and monitor your plans."
            )
            .padding(14)
        } else {
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
                                    elapsedFraction: platform.elapsedFraction,
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
}

// MARK: - Single Provider Focus View

struct ProviderFocusView: View {
    let entry: CodeCapsWidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        if let platform = entry.primaryPlatform ?? entry.platforms.first {
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
                                    elapsedFraction: win.elapsedFraction(),
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
        if let platform = entry.primaryPlatform ?? entry.platforms.first {
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
                    MiniProgressBar(fraction: platform.progressFraction, color: .primary, elapsedFraction: platform.elapsedFraction, height: 4)
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
