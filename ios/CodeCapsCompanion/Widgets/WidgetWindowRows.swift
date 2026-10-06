import SwiftUI
import WidgetKit

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - CodeCaps Mark

/// The app mark, drawn top-left on every widget.
///
/// The owner asked for the black-on-transparent CC mark to replace the bullet
/// plus the word "CodeCaps".  The asset is a template image, so it renders as
/// black in Light and white in Dark without a second copy.
///
/// The word "CodeCaps" used to sit in this corner at 11pt bold, which wrapped
/// to "CodeCa" on the small size: there was only room for five glyphs once the
/// countdown was on the same line.  The mark has no text, so it cannot wrap.
///
/// If the asset is not in the bundle the view renders nothing rather than a
/// reserved gap, so a missing mark never indents the content below it.
struct CodeCapsMarkView: View {
    var size: CGFloat = 14

    private static let assetName = "codecaps-mark"

    var body: some View {
        Group {
            if let image = bundledImage() {
                image
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
            }
        }
    }

    private func bundledImage() -> Image? {
        #if canImport(UIKit)
        if let img = UIImage(named: CodeCapsMarkView.assetName) {
            return Image(uiImage: img)
        }
        #elseif canImport(AppKit)
        if let img = NSImage(named: NSImage.Name(CodeCapsMarkView.assetName)) {
            return Image(nsImage: img)
        }
        #endif
        return nil
    }
}

// MARK: - Window Caption Row

/// The line under a quota bar: the cadence token on the left, the reset
/// countdown on the right.
///
/// This is the row that makes a window identifiable.  A bar on its own says
/// "74%"; a bar with `5h` beside it says "74% of the 5-hour window, resetting in
/// 3h 12m".  Both halves are optional — a window with no reset shows the token
/// alone, and one with an unknown cadence shows the reset alone.
struct WindowCaptionRow: View {
    let token: String
    let resetCaption: String
    var font: CGFloat = 9

    var body: some View {
        HStack(spacing: 4) {
            if !token.isEmpty {
                Text(token)
                    .font(.system(size: font, weight: .semibold, design: .rounded))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: 0)
            if !resetCaption.isEmpty {
                Text(resetCaption)
                    .font(.system(size: font, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
    }
}

// MARK: - Single Bar For A Plan

/// One quota bar for a plan, with the caption row that names it.
///
/// When `platform.windows` holds two entries and the row is only wide enough
/// for one bar, the bar shown is `platform.controllingWindow(pick)` — most
/// urgent by default, and the owner can change that in the widget's edit
/// sheet.  A plan with one window always shows that window.
struct PlanBarRow: View {
    let platform: WidgetPlatformItem
    var pick: WidgetWindowPick = .mostUrgent
    var quotasPerProvider: WidgetQuotasPerProvider = .oneQuota
    var showMark: Bool = true
    var markSize: CGFloat = 14
    var titleFont: CGFloat = 12
    var captionFont: CGFloat = 9
    var percentFont: CGFloat = 12
    var barHeight: CGFloat = 3.5

    /// The bar's own source, so the caption names the window it came from
    /// rather than the plan's aggregate.
    private var shown: (percent: Double?, window: WidgetWindowItem?) {
        if let picked = platform.controllingWindow(pick) {
            return (picked.remainingPercent, picked)
        }
        return (platform.remainingPercent, nil)
    }

    private var percent: Double? { shown.percent }

    private var captionToken: String {
        if let window = shown.window { return window.cadenceToken }
        return WidgetPresentation.shortCadence(cadence: platform.subtitle, label: platform.title)
    }

    private var captionReset: String {
        if let window = shown.window { return window.resetCaption() }
        return platform.resetCaption()
    }

    private var statusColor: Color {
        WidgetPresentation.statusColor(percent: percent, isMasked: shown.window?.isMasked ?? platform.isMasked)
    }

    private var fraction: Double {
        guard let pct = percent else { return 0.0 }
        return max(0.0, min(1.0, pct / 100.0))
    }

    var body: some View {
        if quotasPerProvider == .twoIfAvailable, let pair = platform.dualWindows() {
            PlanDualBarRow(
                platform: platform,
                window1: pair.window1,
                window2: pair.window2,
                showMark: showMark,
                markSize: markSize,
                titleFont: titleFont,
                captionFont: captionFont,
                percentFont: percentFont,
                barHeight: barHeight
            )
        } else {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    if showMark {
                        ProviderMarkView(
                            providerKey: platform.providerKey,
                            itemId: platform.id,
                            size: markSize
                        )
                    }
                    Text(platform.title)
                        .font(.system(size: titleFont, weight: .semibold))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(WidgetPresentation.displayPercent(percent: percent, isMasked: shown.window?.isMasked ?? platform.isMasked))
                        .font(.system(size: percentFont, weight: .bold, design: .rounded))
                        .foregroundColor(statusColor)
                }

                MiniProgressBar(
                    fraction: fraction,
                    color: statusColor,
                    elapsedFraction: shown.window?.elapsedFraction(),
                    height: barHeight
                )

                WindowCaptionRow(
                    token: captionToken,
                    resetCaption: captionReset,
                    font: captionFont
                )
            }
        }
    }
}

// MARK: - Dual Quota Bars For A Plan

/// Two quota bars side by side for a plan that reports multiple windows,
/// giving each window its own bar, percent, and reset caption in the row.
struct PlanDualBarRow: View {
    let platform: WidgetPlatformItem
    let window1: WidgetWindowItem
    let window2: WidgetWindowItem
    var showMark: Bool = true
    var markSize: CGFloat = 14
    var titleFont: CGFloat = 12
    var captionFont: CGFloat = 9
    var percentFont: CGFloat = 12
    var barHeight: CGFloat = 3.5
    var columnSpacing: CGFloat = 10

    private var fraction1: Double {
        guard let pct = window1.remainingPercent, !window1.isMasked else { return 0.0 }
        return max(0.0, min(1.0, pct / 100.0))
    }

    private var fraction2: Double {
        guard let pct = window2.remainingPercent, !window2.isMasked else { return 0.0 }
        return max(0.0, min(1.0, pct / 100.0))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: columnSpacing) {
                // Left Column header: Mark, title, and Window 1 percent
                HStack(spacing: 5) {
                    if showMark {
                        ProviderMarkView(
                            providerKey: platform.providerKey,
                            itemId: platform.id,
                            size: markSize
                        )
                    }
                    Text(platform.title)
                        .font(.system(size: titleFont, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 2)
                    Text(window1.displayPercent)
                        .font(.system(size: percentFont, weight: .bold, design: .rounded))
                        .foregroundColor(window1.statusColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Right Column header: Window 2 cadence token or label, and Window 2 percent
                HStack(spacing: 4) {
                    Text(window2.cadenceToken.isEmpty ? window2.label : window2.cadenceToken)
                        .font(.system(size: captionFont, weight: .semibold, design: .rounded))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(window2.displayPercent)
                        .font(.system(size: percentFont, weight: .bold, design: .rounded))
                        .foregroundColor(window2.statusColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Dual bars
            HStack(spacing: columnSpacing) {
                MiniProgressBar(
                    fraction: fraction1,
                    color: window1.statusColor,
                    elapsedFraction: window1.elapsedFraction(),
                    height: barHeight
                )
                .frame(maxWidth: .infinity)

                MiniProgressBar(
                    fraction: fraction2,
                    color: window2.statusColor,
                    elapsedFraction: window2.elapsedFraction(),
                    height: barHeight
                )
                .frame(maxWidth: .infinity)
            }

            // Dual captions
            HStack(spacing: columnSpacing) {
                WindowCaptionRow(
                    token: window1.cadenceToken,
                    resetCaption: window1.resetCaption(),
                    font: captionFont
                )
                .frame(maxWidth: .infinity)

                WindowCaptionRow(
                    token: window2.cadenceToken,
                    resetCaption: window2.resetCaption(),
                    font: captionFont
                )
                .frame(maxWidth: .infinity)
            }
        }
    }
}

// MARK: - Plan Grid

/// The plan list for a widget, honouring one or two plans per row, and
/// single or dual quota bars per provider.
///
/// One plan per row gives each plan the full width and lets its caption breathe.
/// When two quotas per provider is enabled, plans with multiple windows show
/// both bars side by side.  Two plans per row halves the width to fit more plans.
struct PlanGrid: View {
    let platforms: [WidgetPlatformItem]
    var columns: Int = 1
    var pick: WidgetWindowPick = .mostUrgent
    var quotasPerProvider: WidgetQuotasPerProvider = .twoIfAvailable
    var markSize: CGFloat = 16
    var titleFont: CGFloat = 12
    var captionFont: CGFloat = 9
    var percentFont: CGFloat = 12
    var barHeight: CGFloat = 4
    var spacing: CGFloat = 8
    var horizontalSpacing: CGFloat = 12

    var body: some View {
        if columns <= 1 {
            VStack(spacing: spacing) {
                ForEach(platforms) { platform in
                    if quotasPerProvider == .twoIfAvailable, let pair = platform.dualWindows() {
                        PlanDualBarRow(
                            platform: platform,
                            window1: pair.window1,
                            window2: pair.window2,
                            showMark: true,
                            markSize: markSize,
                            titleFont: titleFont,
                            captionFont: captionFont,
                            percentFont: percentFont,
                            barHeight: barHeight,
                            columnSpacing: horizontalSpacing
                        )
                    } else {
                        PlanBarRow(
                            platform: platform,
                            pick: pick,
                            quotasPerProvider: quotasPerProvider,
                            showMark: true,
                            markSize: markSize,
                            titleFont: titleFont,
                            captionFont: captionFont,
                            percentFont: percentFont,
                            barHeight: barHeight
                        )
                    }
                }
            }
        } else {
            let layout = [
                GridItem(.flexible(), spacing: horizontalSpacing, alignment: .top),
                GridItem(.flexible(), spacing: horizontalSpacing, alignment: .top)
            ]
            LazyVGrid(columns: layout, alignment: .leading, spacing: spacing) {
                ForEach(platforms) { platform in
                    PlanBarRow(
                        platform: platform,
                        pick: pick,
                        quotasPerProvider: .oneQuota,
                        showMark: true,
                        markSize: markSize,
                        titleFont: titleFont,
                        captionFont: captionFont,
                        percentFont: percentFont,
                        barHeight: barHeight
                    )
                }
            }
        }
    }
}
