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
    #if os(macOS)
    public static let appGroupId = "CC8UTF7ATG.codecaps"
    #else
    public static let appGroupId = "group.com.simplewithus.codecaps"
    #endif

    private struct SnapshotEnvelope: Decodable {
        let windows: [SnapshotWindow]?
    }

    private struct SnapshotWindow: Decodable {
        let id: String
        let provider: String
        let label: String
        let occurredAt: String?
    }

    /// Returns nil for malformed or unsupported data, and an empty array for a
    /// valid explicit empty snapshot.  The latter is authoritative: it means
    /// the source currently has no readings and must not resurrect stale cache.
    private static func decodeSnapshot(
        _ data: Data,
        platformOrder: [String],
        now: Date
    ) -> [WidgetPlatformItem]? {
        guard let envelope = try? JSONDecoder().decode(SnapshotEnvelope.self, from: data),
              let windows = envelope.windows else {
            return nil
        }
        guard !windows.isEmpty else { return [] }
        let platforms = WidgetPresentation.parseSnapshot(data: data, platformOrder: platformOrder, now: now)
        return platforms.isEmpty ? nil : platforms
    }

    private static func observedAt(in data: Data) -> Date? {
        guard let envelope = try? JSONDecoder().decode(SnapshotEnvelope.self, from: data),
              let windows = envelope.windows else {
            return nil
        }
        let dates = windows.compactMap { window -> Date? in
            guard let occurredAt = window.occurredAt else { return nil }
            if let seconds = Double(occurredAt), seconds.isFinite {
                return Date(timeIntervalSince1970: seconds)
            }
            if let date = ISO8601DateFormatter().date(from: occurredAt) {
                return date
            }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return fractional.date(from: occurredAt)
        }
        return dates.max()
    }

    public static func readSnapshot(now: Date = Date()) -> (platforms: [WidgetPlatformItem], lastUpdated: Date?, isPlaceholder: Bool) {
        let defaults = UserDefaults(suiteName: appGroupId) ?? UserDefaults.standard
        let order = defaults.stringArray(forKey: "platformOrder") ?? []

        // 1. App Group container
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) {
            let file = container.appendingPathComponent("quota-windows.json")
            if let data = try? Data(contentsOf: file) {
                if let parsed = decodeSnapshot(data, platformOrder: order, now: now) {
                    let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
                    let modDate = observedAt(in: data) ?? (attrs?[.modificationDate] as? Date)
                    return (parsed, modDate, parsed.isEmpty)
                }
            }
        }

        // 2. Sandbox Application Support
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let file = appSupport.appendingPathComponent("CodeCaps/quota-windows.json")
            if let data = try? Data(contentsOf: file) {
                let parsed = decodeSnapshot(data, platformOrder: order, now: now) ?? []
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
                let parsed = decodeSnapshot(data, platformOrder: order, now: now) ?? []
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
                let parsed = decodeSnapshot(data, platformOrder: order, now: now) ?? []
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

    /// Pulls a fresh snapshot only for iOS widget timelines and only when the
    /// app has configured an HTTPS endpoint.  Failure leaves the dated shared
    /// cache untouched so a transient network error never fabricates freshness.
    #if os(iOS)
    public static func refreshFromConfiguredEndpoint(
        now: Date = Date(),
        configuration: URLSessionConfiguration = .ephemeral
    ) async -> (platforms: [WidgetPlatformItem], lastUpdated: Date?, isPlaceholder: Bool) {
        let cached = readSnapshot(now: now)
        guard let defaults = UserDefaults(suiteName: appGroupId),
              let endpoint = defaults.string(forKey: "companionSyncEndpoint"),
              !endpoint.isEmpty,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId) else {
            return cached
        }
        let token = defaults.string(forKey: "companionSyncToken") ?? ""
        do {
            let data = try await WidgetSnapshotFetcher.fetch(
                endpoint: endpoint,
                bearerToken: token,
                configuration: configuration
            )
            guard let platforms = decodeSnapshot(data, platformOrder: defaults.stringArray(forKey: "platformOrder") ?? [], now: now) else {
                return cached
            }
            guard defaults.string(forKey: "companionSyncEndpoint") == endpoint,
                  (defaults.string(forKey: "companionSyncToken") ?? "") == token else {
                return readSnapshot(now: now)
            }
            let file = container.appendingPathComponent("quota-windows.json")
            try data.write(to: file, options: .atomic)
            let observedAt = observedAt(in: data) ?? cached.lastUpdated ?? now
            try? FileManager.default.setAttributes([.modificationDate: observedAt], ofItemAtPath: file.path)
            return (platforms, observedAt, platforms.isEmpty)
        } catch {
            return cached
        }
    }
    #endif
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
        let now = Date()
        #if os(iOS)
        Task {
            let snapshot = await WidgetSnapshotStore.refreshFromConfiguredEndpoint(now: now)
            completion(makeTimeline(snapshot, now: now))
        }
        #else
        completion(makeTimeline(WidgetSnapshotStore.readSnapshot(now: now), now: now))
        #endif
    }

    private func makeTimeline(
        _ snapshot: (platforms: [WidgetPlatformItem], lastUpdated: Date?, isPlaceholder: Bool),
        now: Date
    ) -> Timeline<CodeCapsWidgetEntry> {
        let entry = CodeCapsWidgetEntry(
            date: now,
            platforms: snapshot.platforms,
            lastUpdated: snapshot.lastUpdated,
            isPlaceholder: snapshot.isPlaceholder
        )
        var nextRefresh = Calendar.current.date(byAdding: .minute, value: 15, to: now)
            ?? now.addingTimeInterval(900)
        let imminentResets = snapshot.platforms.compactMap(\.resetAt).filter { $0 > now && $0 < nextRefresh }
        if let earliestReset = imminentResets.min() {
            nextRefresh = earliestReset.addingTimeInterval(30)
        }
        return Timeline(entries: [entry], policy: .after(nextRefresh))
    }
}
