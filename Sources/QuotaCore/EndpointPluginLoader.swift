import Foundation

/// Loads declarative endpoint plugins from
/// `~/Library/Application Support/CodeCaps/Plugins/*.json`.
///
/// Loading is fail-closed and quiet: an unreadable, oversize, malformed, or
/// invalid file is skipped (never half-applied), a duplicate or reserved id
/// loses to the first valid file in filename order, and no file content —
/// which could quote a secret by mistake — is ever logged or surfaced.  The
/// absence of the directory is the normal case and simply means no plugins.
public enum EndpointPluginLoader {
    public static let maxFiles = 20
    public static let maxFileBytes = 65_536

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodeCaps/Plugins", isDirectory: true)
    }

    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var descriptors: [EndpointPluginDescriptor] = []
        var loadedAt: Date = .distantPast
    }

    private static let cache = Cache()

    /// A short-lived cache of the default folder for main-thread callers
    /// (Settings rows, reader toggles) that cannot rescan the disk on every
    /// access.  The refresh path keeps using `load()` directly, so a new
    /// plugin file is picked up within one refresh regardless.
    public static func loadCached(ttl: TimeInterval = 60) -> [EndpointPluginDescriptor] {
        // No Plugins folder is the normal case: answer empty without
        // stamping the cache, so a folder created a moment later is seen
        // on the next access instead of after the TTL.
        guard FileManager.default.fileExists(atPath: defaultDirectory.path) else { return [] }
        cache.lock.lock()
        defer { cache.lock.unlock() }
        if Date().timeIntervalSince(cache.loadedAt) <= ttl { return cache.descriptors }
        // A scan that cannot even list the folder is transient: serve the
        // last good rows and retry on the next access rather than caching
        // the failure for the full TTL.
        guard (try? FileManager.default.contentsOfDirectory(
            at: defaultDirectory, includingPropertiesForKeys: nil)) != nil else {
            return cache.descriptors
        }
        cache.descriptors = load()
        cache.loadedAt = Date()
        return cache.descriptors
    }

    public static func load(directory: URL = defaultDirectory) -> [EndpointPluginDescriptor] {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return [] }
        let files = entries
            .filter { $0.pathExtension.lowercased() == "json" && !$0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .prefix(maxFiles)
        var seenIDs = Set<String>()
        var seenProviderKeys = Set<String>()
        var descriptors: [EndpointPluginDescriptor] = []
        for file in files {
            guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
                  data.count <= maxFileBytes,
                  let descriptor = try? JSONDecoder().decode(EndpointPluginDescriptor.self, from: data),
                  let valid = try? descriptor.validated(),
                  seenIDs.insert(valid.id).inserted,
                  seenProviderKeys.insert(valid.providerKey).inserted else { continue }
            descriptors.append(valid)
        }
        return descriptors
    }

    /// Registrations for the local reader registry.  Every plugin is an
    /// optional reader: it defaults to enabled like the other optional
    /// readers, its factory is never invoked while disabled, and its id
    /// (`plugin:<slug>`) keeps it clear of every built-in toggle.
    public static func registrations(
        descriptors: [EndpointPluginDescriptor],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [LocalQuotaReaderRegistration] {
        descriptors.map { descriptor in
            LocalQuotaReaderRegistration(
                id: descriptor.id, label: descriptor.displayName,
                configurationMetadata: ["providerKey": descriptor.providerKey], isOptional: true
            ) {
                GenericEndpointQuotaReader(descriptor: descriptor, environment: environment)
            }
        }
    }
}
