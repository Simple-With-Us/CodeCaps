import AppIntents
import Foundation
import WidgetKit

// MARK: - Plans Per Row

/// How many plans share one row in the medium and large overview widgets.
///
/// One plan per row gives a plan the full widget width, which is what lets its
/// caption read `5h` on the left and `Resets in 3h 12m` on the right without
/// truncating.  Two per row halves the width so more plans fit on screen.
public enum WidgetRowLayout: String, AppEnum, Sendable {
    case onePlanPerRow
    case twoPlansPerRow

    public static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Plans Per Row")
    public static var caseDisplayRepresentations: [WidgetRowLayout: DisplayRepresentation] = [
        .onePlanPerRow: "One Plan Per Row",
        .twoPlansPerRow: "Two Plans Per Row"
    ]

    /// Column count for the plan grid.
    public var columns: Int { self == .twoPlansPerRow ? 2 : 1 }
}

// MARK: - Quotas Per Provider

/// How many quota bars a single plan displays in widgets wider than small.
///
/// When a plan reports multiple windows (such as a 5-hour and 7-day cap),
/// choosing two quotas per row displays both bars side by side with their own
/// percentages and reset countdowns.  Choosing one quota displays a single wide
/// bar for the controlling window.
public enum WidgetQuotasPerProvider: String, AppEnum, Sendable {
    case twoIfAvailable
    case oneQuota

    public static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Quotas Per Provider")
    public static var caseDisplayRepresentations: [WidgetQuotasPerProvider: DisplayRepresentation] = [
        .twoIfAvailable: "Two Quotas (When Available)",
        .oneQuota: "One Quota"
    ]
}

// MARK: - Which Window Stands In

/// Which single window represents a plan that reports more than one.
///
/// Claude Code has a 5-hour and a 7-day cap but one bar per row, so one of them
/// has to stand in.  The rule is a choice rather than a hidden constant, because
/// "which one is that?" is the obvious first question when a number is on
/// screen with no label.
public enum WidgetWindowPick: String, AppEnum, Sendable {
    /// Least remaining first, soonest reset breaking a tie.  The one that will
    /// stop the owner working soonest.
    case mostUrgent
    /// The window that resets first, so the number moves soonest.
    case resetsSoonest
    /// Most remaining — the plan read as headroom.
    case mostHeadroom

    public static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "Window Shown")
    public static var caseDisplayRepresentations: [WidgetWindowPick: DisplayRepresentation] = [
        .mostUrgent: "Closest To Its Cap",
        .resetsSoonest: "Resets Soonest",
        .mostHeadroom: "Most Remaining"
    ]
}

// MARK: - Plan Entity

/// A selectable plan, listed from the live snapshot so the picker's options are
/// the plans the owner actually has rather than a hardcoded list that drifts.
public struct WidgetPlanEntity: AppEntity, Identifiable, Hashable {
    public init(id: String, title: String, windowCount: Int) {
        self.id = id
        self.title = title
        self.windowCount = windowCount
    }

    public static var typeDisplayRepresentation = TypeDisplayRepresentation(name: "AI Subscription Plan")
    public static var defaultQuery = WidgetPlanQuery()

    public let id: String
    public let title: String
    public let windowCount: Int

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: LocalizedStringResource(stringLiteral: title),
            subtitle: windowCount > 1
                ? LocalizedStringResource(stringLiteral: "\(windowCount) windows")
                : LocalizedStringResource(stringLiteral: "1 window")
        )
    }

    public static var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "AI Subscription Plan")
    }
}

public struct WidgetPlanQuery: EntityQuery {
    public init() {}


    public func entities(for identifiers: [WidgetPlanEntity.ID]) async throws -> [WidgetPlanEntity] {
        let available = Self.currentPlans()
        let wanted = Set(identifiers)
        return available.filter { wanted.contains($0.id) }
    }

    public func suggestedEntities() async throws -> [WidgetPlanEntity] {
        Self.currentPlans()
    }

    /// Read straight from the shared snapshot.  A widget edit sheet cannot do
    /// network work, so this shows the last synced plans — the same data the
    /// widget body will render, which keeps the picker from promising a plan
    /// the widget cannot show.
    private static func currentPlans() -> [WidgetPlanEntity] {
        WidgetSnapshotStore.readSnapshot().platforms.map { platform in
            WidgetPlanEntity(
                id: platform.id,
                title: platform.title,
                windowCount: platform.windows.count
            )
        }
    }
}

// MARK: - The Configuration Intent

/// The whole widget edit sheet.
///
/// Every widget used to be a `StaticConfiguration`, which is why the edit button
/// opened a sheet with nothing in it: a static configuration has no parameters
/// to show.  Moving to `AppIntentConfiguration` is what puts the dropdowns back.
public struct SelectQuotaIntent: WidgetConfigurationIntent {
    public init() {}

    public static var title: LocalizedStringResource = "Choose Quotas"
    public static var description = IntentDescription("Pick which plan this widget shows, how many plans share a row, whether to show two quotas per provider, and which window stands in when displaying a single bar.")

    /// The plan to show.  Unset means every plan, in the overview widgets, and
    /// the most urgent one in the focus widget.
    @Parameter(title: "Plan")
    public var plan: WidgetPlanEntity?

    /// One plan per row, or two.
    @Parameter(title: "Plans Per Row", default: .onePlanPerRow)
    public var rowLayout: WidgetRowLayout

    /// Quotas shown per provider in a row when space permits.
    @Parameter(title: "Quotas Per Provider", default: .twoIfAvailable)
    public var quotasPerProvider: WidgetQuotasPerProvider

    /// Which window stands in for a plan that reports two.
    @Parameter(title: "Window Shown", default: .mostUrgent)
    public var windowPick: WidgetWindowPick

    public static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$plan) \(\.$rowLayout) with \(\.$quotasPerProvider) (\(\.$windowPick))")
    }
}

// MARK: - Intent Timeline Provider

/// Timeline provider for the configurable widgets.
///
/// The configuration is applied here rather than in the view so every widget
/// size and the lock-screen accessories all read the same filtered entry.
public struct CodeCapsIntentProvider: AppIntentTimelineProvider {
    public typealias Entry = CodeCapsWidgetEntry
    public typealias Intent = SelectQuotaIntent

    public func placeholder(in context: Context) -> CodeCapsWidgetEntry {
        CodeCapsWidgetEntry(
            date: Date(),
            platforms: WidgetPresentation.placeholders,
            lastUpdated: nil,
            isPlaceholder: true
        )
    }

    public func snapshot(for configuration: SelectQuotaIntent, in context: Context) async -> CodeCapsWidgetEntry {
        if context.isPreview {
            return placeholder(in: context)
        }
        let (platforms, lastUpdated, isPlaceholder) = WidgetSnapshotStore.readSnapshot()
        return entry(from: (platforms, lastUpdated, isPlaceholder), configuration: configuration)
    }

    public func timeline(for configuration: SelectQuotaIntent, in context: Context) async -> Timeline<CodeCapsWidgetEntry> {
        let now = Date()
        #if os(iOS)
        let snapshot = await WidgetSnapshotStore.refreshFromConfiguredEndpoint(now: now)
        #else
        let snapshot = WidgetSnapshotStore.readSnapshot(now: now)
        #endif
        return WidgetTimelineBuilder.makeTimeline(
            snapshot,
            now: now,
            showing: filtered(snapshot.platforms, by: configuration),
            configuration: configuration
        )
    }

    private func entry(
        from snapshot: (platforms: [WidgetPlatformItem], lastUpdated: Date?, isPlaceholder: Bool),
        configuration: SelectQuotaIntent
    ) -> CodeCapsWidgetEntry {
        CodeCapsWidgetEntry(
            date: Date(),
            platforms: filtered(snapshot.platforms, by: configuration),
            lastUpdated: snapshot.lastUpdated,
            isPlaceholder: snapshot.isPlaceholder,
            configuration: configuration
        )
    }

    /// A plan the snapshot no longer has is filtered out rather than shown
    /// stale, so deleting a plan in CodeCaps cannot leave a ghost row behind in
    /// a widget whose configuration still names it.
    public func filtered(
        _ platforms: [WidgetPlatformItem],
        by configuration: SelectQuotaIntent
    ) -> [WidgetPlatformItem] {
        guard let wanted = configuration.plan?.id else { return platforms }
        let match = platforms.filter { $0.id == wanted }
        return match.isEmpty ? platforms : match
    }
}
