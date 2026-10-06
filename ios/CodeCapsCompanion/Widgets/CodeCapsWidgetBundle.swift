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
        AppIntentConfiguration(
            kind: kind,
            intent: SelectQuotaIntent.self,
            provider: CodeCapsIntentProvider()
        ) { entry in
            OverviewWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetColors.background
                }
        }
        .configurationDisplayName("AI Subscription Overview")
        .description("Monitor quotas, remaining percentages, and reset countdowns across your AI subscription plans.  Edit to pick a plan, choose one or two plans per row, toggle two quotas per provider, and pick which window stands in.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OverviewWidgetEntryView: View {
    let entry: CodeCapsWidgetEntry
    @Environment(\.widgetFamily) var family

    var body: some View {
        switch family {
        case .systemSmall:
            OverviewSmallView(entry: entry, pick: entry.windowPick)
        case .systemMedium:
            OverviewMediumView(
                entry: entry,
                pick: entry.windowPick,
                columns: entry.rowLayout.columns,
                quotasPerProvider: entry.quotasPerProvider
            )
        case .systemLarge:
            OverviewLargeView(
                entry: entry,
                pick: entry.windowPick,
                columns: entry.rowLayout.columns,
                quotasPerProvider: entry.quotasPerProvider
            )
        default:
            OverviewLargeView(
                entry: entry,
                pick: entry.windowPick,
                columns: entry.rowLayout.columns,
                quotasPerProvider: entry.quotasPerProvider
            )
        }
    }
}

// MARK: - Single Provider Focus Widget

struct CodeCapsProviderWidget: Widget {
    let kind: String = "CodeCapsProviderWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectQuotaIntent.self,
            provider: CodeCapsIntentProvider()
        ) { entry in
            ProviderFocusView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetColors.background
                }
        }
        .configurationDisplayName("AI Plan Focus")
        .description("Track one AI subscription plan with a circular gauge. Edit to choose the plan and which of its windows the gauge shows.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Lock Screen & Accessory Widget

#if os(iOS)
struct CodeCapsAccessoryWidget: Widget {
    let kind: String = "CodeCapsAccessoryWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: SelectQuotaIntent.self,
            provider: CodeCapsIntentProvider()
        ) { entry in
            AccessoryView(entry: entry)
                .containerBackground(for: .widget) {
                    Color.clear
                }
        }
        .configurationDisplayName("Lock Screen Quota")
        .description("Glance at active AI subscription quotas directly from your Lock Screen or StandBy. Edit to choose the plan.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
#endif
