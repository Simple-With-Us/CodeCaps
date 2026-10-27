import SwiftUI
import WidgetKit
import AppIntents

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
    /// What the caption says.
    ///
    /// It is a value and not three arguments,  because the qualifier used to be an
    /// argument with a default:  a surface that rendered a window's caption could
    /// leave it out,  and the omission showed up only in a review.  A caption now
    /// carries its qualifier,  and one built from a window carries that window's.
    let caption: QuotaWindowCaption
    var font: CGFloat = 9

    var body: some View {
        HStack(spacing: 4) {
            if !caption.token.isEmpty || !caption.qualifier.isEmpty {
                HStack(spacing: 3) {
                    if !caption.token.isEmpty {
                        Text(caption.token)
                            .font(.system(size: font, weight: .semibold, design: .rounded))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if !caption.qualifier.isEmpty {
                        Text(caption.qualifier)
                            .font(.system(size: font, weight: .medium))
                            .foregroundColor(.secondary.opacity(0.8))
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
            }
            Spacer(minLength: 0)
            if !caption.resetCaption.isEmpty {
                Text(caption.resetCaption)
                    .font(.system(size: font, weight: .medium, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .truncationMode(.tail)
            }
        }
    }
}

// MARK: - Single Bar For A Plan

/// What a plan at its cap shows instead of a bar.
///
/// Owner 2026-10-11: the same plan could show "100%" on its 5-hour window
/// while its weekly allowance was spent, which reads as healthy on a plan that
/// cannot be used.  So a capped row draws no bar and no percentage: it names
/// the cap and counts down to the reset that lifts it.
///
/// The cadence token and the reset caption keep their usual places, so the
/// caption line still says *which* window ran out and when it returns.
struct PlanAtCapRow: View {
    let platform: WidgetPlatformItem
    let window: WidgetWindowItem
    var showMark: Bool = true
    var markSize: CGFloat = 14
    var titleFont: CGFloat = 12
    var captionFont: CGFloat = 9
    var percentFont: CGFloat = 12

    private var captionToken: String {
        window.cadenceToken.isEmpty ? window.label : window.cadenceToken
    }

    /// The words, in Title Case like every other owner-facing string here.
    static let label = "At Cap"

    var body: some View {
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
                Text(Self.label)
                    .font(.system(size: percentFont, weight: .bold, design: .rounded))
                    .foregroundColor(WidgetPresentation.statusColor(percent: 0, isMasked: false))
            }

            WindowCaptionRow(
                caption: window.caption,
                font: captionFont
            )
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(platform.title): at cap. \(window.resetCaption())")
    }
}

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
        if let atCap = platform.atCapWindow(), platform.usableMuseExtra == nil {
            // Owner 2026-10-11: a plan at its cap showed a bar labelled 100%
            // beside a plan that could not be used.  The words go where the bar
            // was, and the bar does not get drawn at all.
            PlanAtCapRow(
                platform: platform,
                window: atCap,
                showMark: showMark,
                markSize: markSize,
                titleFont: titleFont,
                captionFont: captionFont,
                percentFont: percentFont
            )
        } else if quotasPerProvider == .twoIfAvailable, let pair = platform.dualWindows() {
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
                }
                HStack(spacing: 8) {
                    Text(captionToken).font(.system(size: captionFont, weight: .semibold))
                    Text(WidgetPresentation.displayPercent(percent: percent, isMasked: shown.window?.isMasked ?? platform.isMasked))
                        .font(.system(size: percentFont, weight: .bold, design: .rounded))
                        .foregroundColor(statusColor)
                    Text(shown.window?.countdown() ?? platform.countdown())
                        .font(.system(size: captionFont - 0.5)).foregroundStyle(.secondary)
                }.lineLimit(1).minimumScaleFactor(0.8)

                MiniProgressBar(
                    fraction: fraction,
                    color: statusColor,
                    elapsedFraction: shown.window?.elapsedFraction(),
                    hasReading: !(shown.window?.isMasked ?? platform.isMasked) && percent?.isFinite == true,
                    height: barHeight
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
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                if showMark {
                    ProviderMarkView(providerKey: platform.providerKey, itemId: platform.id, size: markSize)
                }
                Text(platform.title).font(.system(size: titleFont, weight: .semibold)).lineLimit(1)
            }
            HStack(spacing: columnSpacing) {
                allowance(window1, fraction: fraction1)
                allowance(window2, fraction: fraction2)
            }
        }
    }

    private func allowance(_ window: WidgetWindowItem, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 7) {
                Text(window.cadenceToken).font(.system(size: captionFont, weight: .semibold))
                Text(window.displayPercent)
                    .font(.system(size: percentFont, weight: .bold, design: .rounded))
                    .foregroundStyle(window.statusColor)
                Text(window.countdown().isEmpty ? "—" : window.countdown())
                    .font(.system(size: captionFont - 0.5)).foregroundStyle(.secondary)
            }.lineLimit(1).minimumScaleFactor(0.8)
            MiniProgressBar(fraction: fraction, color: window.statusColor,
                elapsedFraction: window.elapsedFraction(),
                hasReading: !window.isMasked && window.remainingPercent?.isFinite == true, height: barHeight)
        }.frame(maxWidth: .infinity, alignment: .leading)
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
    var detailScope: String? = nil

    var body: some View {
        if columns <= 1 {
            VStack(spacing: spacing) {
                ForEach(platforms) { platform in
                    HStack(alignment: .top, spacing: 4) {
                    Group {
                    // Checked here too, not only inside `PlanBarRow`: this
                    // branch builds `PlanDualBarRow` directly, so a capped plan
                    // would otherwise keep both of its bars.
                    if let atCap = platform.atCapWindow(), platform.usableMuseExtra == nil {
                        PlanAtCapRow(
                            platform: platform,
                            window: atCap,
                            showMark: true,
                            markSize: markSize,
                            titleFont: titleFont,
                            captionFont: captionFont,
                            percentFont: percentFont
                        )
                    } else if quotasPerProvider == .twoIfAvailable, let pair = platform.dualWindows() {
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
                    if let detailScope {
                        Button(intent: ShowWidgetPlanDetailIntent(planID: platform.id, overviewKey: detailScope)) {
                            Image(systemName: "info.circle").font(.system(size: 11))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Details for \(platform.title)")
                    }
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
