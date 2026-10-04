import Foundation
import WidgetKit
import SwiftUI

/// Timeline entry representing the state of AI subscription quotas.
public struct CodeCapsWidgetEntry: TimelineEntry {
    public let date: Date
    public let platforms: [WidgetPlatformItem]
    public let lastUpdated: Date?
    public let isPlaceholder: Bool
    /// The widget's own edit-sheet settings, carried on the entry because
    /// WidgetKit hands the content closure an entry and nothing else.  Nil for
    /// gallery placeholders, which then render the defaults.
    public let configuration: SelectQuotaIntent?

    public init(
        date: Date,
        platforms: [WidgetPlatformItem],
        lastUpdated: Date? = nil,
        isPlaceholder: Bool = false,
        configuration: SelectQuotaIntent? = nil
    ) {
        self.date = date
        self.platforms = platforms
        self.lastUpdated = lastUpdated
        self.isPlaceholder = isPlaceholder
        self.configuration = configuration
    }

    /// Plans per row, from the edit sheet.  Defaults to one.
    public var rowLayout: WidgetRowLayout {
        configuration?.rowLayout ?? .onePlanPerRow
    }

    /// Which window stands in for a plan that reports two, from the edit sheet.
    public var windowPick: WidgetWindowPick {
        configuration?.windowPick ?? .mostUrgent
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
        let tokenStore = CompanionReadTokenStore(accessGroup: appGroupId)
        let tokenState = tokenStore.readForWidget(shared: defaults)
        if case .unavailable = tokenState { return cached }
        let token = tokenState.token ?? ""
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
                  tokenStore.readForWidget(shared: defaults) == tokenState else {
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

/// Timeline construction shared by the configurable widget providers.
///
/// The provider itself lives with the intent, because an `AppIntentConfiguration`
/// needs an `AppIntentTimelineProvider`; only the refresh policy is common, so
/// that is all that lives here.
enum WidgetTimelineBuilder {

    /// `showing` narrows the entry to a configured plan; the refresh schedule
    /// still comes from the full snapshot, because a plan that is not on screen
    /// can still be the one that needs a timely reload.
    static func makeTimeline(
        _ snapshot: (platforms: [WidgetPlatformItem], lastUpdated: Date?, isPlaceholder: Bool),
        now: Date,
        showing: [WidgetPlatformItem]? = nil,
        configuration: SelectQuotaIntent? = nil
    ) -> Timeline<CodeCapsWidgetEntry> {
        let entry = CodeCapsWidgetEntry(
            date: now,
            platforms: showing ?? snapshot.platforms,
            lastUpdated: snapshot.lastUpdated,
            isPlaceholder: snapshot.isPlaceholder,
            configuration: configuration
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
