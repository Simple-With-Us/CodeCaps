import WidgetKit
import SwiftUI

/// Main WidgetBundle declaring CodeCaps widgets across iOS and macOS.
@main
struct CodeCapsWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodeCapsOverviewWidget()
        CodeCapsProviderWidget()
        #if os(iOS)
        CodeCapsAccessoryWidget()
        #endif
    }
}

// MARK: - Overview Widget

struct CodeCapsOverviewWidget: Widget {
    let kind: String = "CodeCapsOverviewWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodeCapsTimelineProvider()) { entry in
            OverviewWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetColors.background
                }
        }
        .configurationDisplayName("AI Subscription Overview")
        .description("Monitor quotas, remaining percentages, and reset countdowns across your active AI subscription plans.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OverviewWidgetEntryView: View {
    let entry: CodeCapsWidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            OverviewSmallView(entry: entry)
        case .systemMedium:
            OverviewMediumView(entry: entry)
        case .systemLarge:
            OverviewLargeView(entry: entry)
        default:
            OverviewSmallView(entry: entry)
        }
    }
}

// MARK: - Single Provider Focus Widget

struct CodeCapsProviderWidget: Widget {
    let kind: String = "CodeCapsProviderWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodeCapsTimelineProvider()) { entry in
            ProviderFocusView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetColors.background
                }
        }
        .configurationDisplayName("AI Plan Focus")
        .description("Track the AI subscription plan nearest to its quota cap with a circular progress gauge.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Lock Screen & Accessory Widget

#if os(iOS)
struct CodeCapsAccessoryWidget: Widget {
    let kind: String = "CodeCapsAccessoryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CodeCapsTimelineProvider()) { entry in
            AccessoryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("Lock Screen Quota")
        .description("Glance at active AI subscription quotas directly from your Lock Screen or StandBy.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
#endif
