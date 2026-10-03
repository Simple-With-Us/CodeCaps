import Foundation
import WidgetKit
import SwiftUI

/// Timeline entry representing the state of AI subscription quotas.
public struct CodeCapsWidgetEntry: TimelineEntry {
    public let date: Date
    public let platforms: [WidgetPlatformItem]
    public let lastUpdated: Date?
    public let isPlaceholder: Bool

    public init(
        date: Date,
        platforms: [WidgetPlatformItem],
        lastUpdated: Date? = nil,
        isPlaceholder: Bool = false
    ) {
        self.date = date
        self.platforms = platforms
        self.lastUpdated = lastUpdated
        self.isPlaceholder = isPlaceholder
    }

    /// Primary platform to display in single-provider focus widgets.
    /// Prefers the platform nearest to cap (lowest remaining percent), or the first platform.
    public var primaryPlatform: WidgetPlatformItem? {
        platforms.min { a, b in
            (a.remainingPercent ?? 100) < (b.remainingPercent ?? 100)
        } ?? platforms.first
    }
}

/// Helper for reading cached quota snapshots from the shared App Group container.
public enum WidgetSnapshotStore {
    public static let appGroupId = "group.com.simplewithus.codecaps"

    public static func readSnapshot(now: Date = Date()) -> (platforms: [WidgetPlatformItem], lastUpdated: Date?, isPlaceholder: Bool) {
        let defaults = UserDefaults(suiteName: appGroupId) ?? UserDefaults.standard
        let order = defaults.stringArray(forKey: "platformOrder") ?? []

        // 1. App Group container
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            let file = container.appendingPathComponent("quota-windows.json")
            if let data = try? Data(contentsOf: file) {
                let parsed = WidgetPresentation.parseSnapshot(data: data, platformOrder: order, now: now)
                if !parsed.isEmpty {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
                    let modDate = attrs?[.modificationDate] as? Date
                    return (parsed, modDate, false)
                }
            }
        }

        // 2. Sandbox Application Support
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let file = appSupport.appendingPathComponent("CodeCaps/quota-windows.json")
            if let data = try? Data(contentsOf: file) {
                let parsed = WidgetPresentation.parseSnapshot(data: data, platformOrder: order, now: now)
                if !parsed.isEmpty {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
                    let modDate = attrs?[.modificationDate] as? Date
                    return (parsed, modDate, false)
                }
            }
        }

        // 3. Sandbox Caches
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let file = caches.appendingPathComponent("quota-windows.json")
            if let data = try? Data(contentsOf: file) {
                let parsed = WidgetPresentation.parseSnapshot(data: data, platformOrder: order, now: now)
                if !parsed.isEmpty {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
                    let modDate = attrs?[.modificationDate] as? Date
                    return (parsed, modDate, false)
                }
            }
        }

        // 4. macOS Host Application Support (CodeCaps or Usage Monitor path)
        for subpath in ["CodeCaps/quota-windows.json", "Usage Monitor/quota-windows.json"] {
            let hostPath = ("~/Library/Application Support/\(subpath)" as NSString).expandingTildeInPath
            if let data = try? Data(contentsOf: URL(fileURLWithPath: hostPath)) {
                let parsed = WidgetPresentation.parseSnapshot(data: data, platformOrder: order, now: now)
                if !parsed.isEmpty {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: hostPath)
                    let modDate = attrs?[.modificationDate] as? Date
                    return (parsed, modDate, false)
                }
            }
        }

        // 5. Unconfigured / no data synced state (honest empty state, no fake numbers)
        return ([], nil, true)
    }
}

/// Timeline provider for CodeCaps widgets.
public struct CodeCapsTimelineProvider: TimelineProvider {
    public typealias Entry = CodeCapsWidgetEntry

    public init() {}

    public func placeholder(in context: Context) -> CodeCapsWidgetEntry {
        CodeCapsWidgetEntry(
            date: Date(),
            platforms: WidgetPresentation.placeholders,
            lastUpdated: nil,
            isPlaceholder: true
        )
    }

    public func getSnapshot(in context: Context, completion: @escaping (CodeCapsWidgetEntry) -> Void) {
        if context.isPreview {
            completion(placeholder(in: context))
            return
        }
        let (platforms, lastUpdated, isPlaceholder) = WidgetSnapshotStore.readSnapshot()
        completion(CodeCapsWidgetEntry(
            date: Date(),
            platforms: platforms,
            lastUpdated: lastUpdated,
            isPlaceholder: isPlaceholder
        ))
    }

    public func getTimeline(in context: Context, completion: @escaping (Timeline<CodeCapsWidgetEntry>) -> Void) {
        let (platforms, lastUpdated, isPlaceholder) = WidgetSnapshotStore.readSnapshot()
        let now = Date()
        let entry = CodeCapsWidgetEntry(
            date: now,
            platforms: platforms,
            lastUpdated: lastUpdated,
            isPlaceholder: isPlaceholder
        )

        // Schedule next refresh: 15 minutes, or sooner if a quota window resets within 15 minutes
        var nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: now)
            ?? now.addingTimeInterval(900)

        let imminentResets = platforms.compactMap(\.resetAt).filter { $0 > now && $0 < nextRefresh }
        if let earliestReset = imminentResets.min() {
            // Refresh 30 seconds after the quota window resets so updated readings appear promptly
            nextRefresh = earliestReset.addingTimeInterval(30)
        }

        let timeline = Timeline(entries: [entry], policy: .after(nextRefresh))
        completion(timeline)
    }
}
