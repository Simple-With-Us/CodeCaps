import Foundation

/// Infisical as the sole source of truth for CodeCaps' app-level settings.
///
/// The fleet-wide contract (see INFISICAL.md at the repo root):
/// 1. **Load at startup** into an in-memory cache.  A load failure never
///    blocks launch — the app keeps its local values until the next refresh.
/// 2. **Never fetch per-request.**  `value(for:)` is a synchronous,
///    memory-only read; no network call leaves this type except from
///    `load()`, `refresh()` and `set(_:for:)` (the last two only from the
///    background refresh timer, `applicationDidBecomeActive`, and the
///    owner's explicit Save actions).
/// 3. **Background refresh** keeps serving the last-known-good cache when a
///    refresh fails; the failure is recorded on `lastError`, never thrown.
/// 4. **Write-through on admin save.**  `set(_:for:)` writes to Infisical
///    FIRST and only updates the cache after the write succeeds.  A failed
///    write throws and leaves the cache untouched — the cache and Infisical
///    never diverge silently.
///
/// The universal-auth client secret is provisioned by the owner into his own
/// Keychain (Settings → Infisical Sync) and held here only in memory.  It is
/// never logged, never persisted by this type, and never leaves an error
/// message.  The iOS companion never holds it at all — the Mac app owns the
/// Infisical read and the companion keeps reading through its existing API.
///
/// The class is `@unchecked Sendable`: every stored property is either a
/// value type or guarded by `lock`, so synchronous memory-only reads are safe
/// from any thread and the network calls stay in `async` functions.
public final class InfisicalSettings: @unchecked Sendable {

    // MARK: - Inventory

    /// Keys this app manages in Infisical.  The full inventory, sensitivity,
    /// and defaults live in INFISICAL.md.
    public enum Keys {
        /// Service URL the Mac app pulls other machines' quota windows from.
        public static let pullEndpoint = "PULL_ENDPOINT"
        /// Service URL the Mac app pushes this Mac's quota windows to.
        public static let pushEndpoint = "PUSH_ENDPOINT"
        /// Seconds between background refreshes of this cache.  Tunable via
        /// Infisical itself, per the fleet-wide pattern.
        public static let refreshSeconds = "SETTINGS_REFRESH_SECONDS"
    }

    private static let managedKeys = [Keys.pullEndpoint, Keys.pushEndpoint, Keys.refreshSeconds]

    /// Fallback refresh cadence when the key is absent or unparseable.
    public static let defaultRefreshInterval: TimeInterval = 300
    /// Floor for an admin-set cadence, so a typo cannot turn the refresh
    /// timer into a hot loop.
    public static let minimumRefreshInterval: TimeInterval = 60

    /// Every build reads the `prod` environment, and only `prod`.  The dev and
    /// staging environments are retired (owner, 2026-10-10), so a `.dev` build
    /// reads prod too.  `TokenStore` and `InfisicalIdentityStore` still scope
    /// Keychain items per build.  `accessToken(for:revision:)` refuses any
    /// configuration whose environment differs, before any request is sent.
    public static func defaultEnvironment() -> String { "prod" }

    // MARK: - Configuration

    public struct Configuration: Equatable, Sendable {
        public var siteURL: URL
        public var projectId: String
        public var environment: String
        public var clientId: String
        public var clientSecret: String

        public init(
            siteURL: URL = URL(string: "https://app.infisical.com")!,
            projectId: String,
            environment: String,
            clientId: String,
            clientSecret: String
        ) {
            self.siteURL = siteURL
            self.projectId = projectId
            self.environment = environment
            self.clientId = clientId
            self.clientSecret = clientSecret
        }
    }

    // MARK: - Errors

    public enum SettingsError: Error, LocalizedError {
        case notConfigured
        case superseded
        case invalidDestination
        case projectUnavailable(status: Int)
        case loginFailed(status: Int)
        case fetchFailed(status: Int)
        case writeFailed(status: Int)
        case decoding(String)
        case transport(Error)

        public var errorDescription: String? {
            switch self {
            case .superseded:
                return "Infisical setup changed while this request was running.  Try again with the current setup."
            case .invalidDestination:
                return "Infisical did not confirm the selected Project ID and environment.  The previous setup is unchanged."
            case .projectUnavailable(let status):
                return "Infisical project verification failed (HTTP \(status)).  Check the Project ID and identity access."
            case .notConfigured:
                return "Infisical sync is not set up.  Add your client identity under Settings → Infisical Sync (see INFISICAL.md)."
            case .loginFailed(let status):
                return "Infisical login failed (HTTP \(status)).  Check the client identity under Settings → Infisical Sync."
            case .fetchFailed(let status):
                return "Infisical settings fetch failed (HTTP \(status)).  The last-known-good values are still in effect."
            case .writeFailed(let status):
                return "Infisical write failed (HTTP \(status)) — the setting was NOT saved, so the cache and Infisical cannot diverge."
            case .decoding(let what):
                return "Infisical returned an unexpected response (\(what))."
            case .transport(let error):
                return "Infisical request failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - Transport seam

    /// One HTTP round trip.  `URLSessionTransport` is the live implementation;
    /// tests inject a mock.  Bodies and headers here are request plumbing —
    /// secret *values* are never logged by this type.
    public protocol Transport: Sendable {
        func send(
            method: String,
            url: URL,
            headers: [String: String],
            body: Data?
        ) async throws -> (data: Data, statusCode: Int)
    }

    public struct URLSessionTransport: Transport {
        private let timeout: TimeInterval

        public init(timeout: TimeInterval = 30) {
            self.timeout = timeout
        }

        public func send(
            method: String,
            url: URL,
            headers: [String: String],
            body: Data?
        ) async throws -> (data: Data, statusCode: Int) {
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.timeoutInterval = timeout
            for (field, value) in headers {
                request.setValue(value, forHTTPHeaderField: field)
            }
            request.httpBody = body
            // Ephemeral: nothing about these requests is cached, cookied, or
            // written to disk — same posture as the quota fetchers.
            let session = URLSession(configuration: .ephemeral)
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
    }

    // MARK: - State

    /// The app's one settings store.  Tests build their own instances with a
    /// mock transport and never touch this one, so no test hits the network.
    public static let shared = InfisicalSettings()

    private let transport: Transport
    private let lock = NSLock()
    private var _configuration: Configuration?
    private var _generation: UInt64 = 0

    /// A fence for callers that adopt results after awaiting network work.
    public struct Revision: Equatable, Sendable {
        fileprivate let generation: UInt64
    }

    public var revision: Revision {
        lock.lock()
        defer { lock.unlock() }
        return Revision(generation: _generation)
    }

    public func isCurrent(_ revision: Revision) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return revision.generation == _generation
    }

    private func checkCurrent(_ revision: Revision) throws {
        guard isCurrent(revision) else { throw SettingsError.superseded }
    }
    private var _cache: [String: String] = [:]
    private var _loadedAt: Date?
    private var _lastError: String?

    public init(transport: Transport = URLSessionTransport()) {
        self.transport = transport
    }

    // MARK: - Configuration

    public func configure(_ configuration: Configuration) {
        lock.lock()
        defer { lock.unlock() }
        guard _configuration != configuration else { return }
        _generation &+= 1
        _configuration = configuration
        _cache = [:]
        _loadedAt = nil
        _lastError = nil
    }

    public func clearConfiguration() {
        // The no-persistence overload is useful at startup and in core tests.
        try? clearConfiguration(persist: {})
    }

    /// Persistence and the runtime switch share a synchronous commit boundary.
    /// A Keychain failure leaves the active configuration and cache intact.
    public func clearConfiguration(persist: () throws -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        _generation &+= 1
        try persist()
        _configuration = nil
        _cache = [:]
        _loadedAt = nil
        _lastError = nil
    }

    public func beginSetupChange() -> Revision {
        lock.lock()
        defer { lock.unlock() }
        _generation &+= 1
        return Revision(generation: _generation)
    }

    /// Explicit Save validates a candidate in isolation. No new secret listing
    /// permission is needed: project metadata verifies the destination, followed
    /// by the same three named reads used for refresh. The synchronous persistence
    /// callback must not call back into this settings instance.
    @discardableResult
    public func validateAndConfigure(
        _ configuration: Configuration,
        revision: Revision? = nil,
        persist: () throws -> Void
    ) async throws -> Revision {
        let revision = revision ?? beginSetupChange()
        guard !configuration.projectId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !configuration.environment.isEmpty else { throw SettingsError.invalidDestination }
        let values = try await fetchManaged(configuration: configuration, revision: revision,
                                            verifyDestination: true)
        return try commitSetup(configuration, values: values, revision: revision, persist: persist)
    }

    private func commitSetup(_ configuration: Configuration, values: [String: String],
                             revision: Revision, persist: () throws -> Void) throws -> Revision {
        lock.lock()
        defer { lock.unlock() }
        guard revision.generation == _generation else { throw SettingsError.superseded }
        try persist()
        // Retire refreshes that started against the old setup during validation.
        _generation &+= 1
        _configuration = configuration
        _cache = values
        _loadedAt = Date()
        _lastError = nil
        return Revision(generation: _generation)
    }

    /// Whether the owner has provisioned an Infisical identity.  With no
    /// identity every read falls back to local values and every save stays
    /// local — today's behaviour, unchanged.
    public var isProvisioned: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _configuration != nil
    }

    private func configurationOrThrow() throws -> (Configuration, Revision) {
        lock.lock()
        defer { lock.unlock() }
        guard let configuration = _configuration else {
            throw SettingsError.notConfigured
        }
        return (configuration, Revision(generation: _generation))
    }

    // MARK: - Memory-only reads

    /// Synchronous, memory-only read.  This is the only read path the refresh
    /// loop, the quota fetchers, and the UI may use — it never touches the
    /// network.  Returns nil for missing keys and for empty values (an empty
    /// value in Infisical means "not configured").
    public func value(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let raw = _cache[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw
    }

    public func allValues() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return _cache
    }

    public var lastLoadedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _loadedAt
    }

    /// The most recent refresh failure, if any.  Loud but non-fatal: the
    /// cache keeps serving last-known-good underneath it.
    public var lastError: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastError
    }

    /// The background refresh cadence, tunable via Infisical itself.
    public var refreshInterval: TimeInterval {
        guard let raw = value(for: Keys.refreshSeconds),
              let seconds = TimeInterval(raw) else {
            return Self.defaultRefreshInterval
        }
        return max(seconds, Self.minimumRefreshInterval)
    }

    // MARK: - Load / refresh

    /// Fetch only the managed keys from Infisical, replacing the cache.  Throws on any failure
    /// and leaves the previous cache untouched.  Off the main thread by
    /// construction — every caller awaits it from a background task.
    public func load() async throws {
        let (configuration, revision) = try configurationOrThrow()
        let values = try await fetchManaged(configuration: configuration, revision: revision)
        try install(values, revision: revision)
    }

    private func install(_ values: [String: String], revision: Revision) throws {
        lock.lock()
        defer { lock.unlock() }
        guard revision.generation == _generation else { throw SettingsError.superseded }
        _cache = values
        _loadedAt = Date()
        _lastError = nil
    }

    /// Best-effort refresh. Failures from a retired destination cannot replace
    /// the current status, and success cannot resurrect its cached endpoints.
    public func refresh() async {
        guard let (configuration, revision) = try? configurationOrThrow() else { return }
        do {
            let values = try await fetchManaged(configuration: configuration, revision: revision)
            try install(values, revision: revision)
        } catch {
            record(error, revision: revision)
        }
    }

    private func record(_ error: Error, revision: Revision) {
        lock.lock()
        defer { lock.unlock() }
        guard revision.generation == _generation else { return }
        _lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    // MARK: - Write-through

    /// Writes `value` to Infisical FIRST, then updates the cache.  A failed
    /// Infisical write throws and the cache is left exactly as it was.
    public func set(_ value: String, for key: String, expectedRevision: Revision? = nil) async throws {
        let (configuration, revision) = try configurationOrThrow()
        if let expectedRevision, expectedRevision != revision { throw SettingsError.superseded }
        try await writeSecret(configuration: configuration, revision: revision, key: key, value: value)
        try install(value, for: key, revision: revision)
    }

    private func install(_ value: String, for key: String, revision: Revision) throws {
        lock.lock()
        defer { lock.unlock() }
        guard revision.generation == _generation else { throw SettingsError.superseded }
        _cache[key] = value
        _loadedAt = Date()
        _lastError = nil
    }

    /// Write-through that is a no-op until the owner provisions an identity,
    /// so settings call sites stay one line and unprovisioned behaviour is
    /// byte-for-byte today's.
    public func writeThrough(_ value: String, for key: String) async throws {
        guard let (_, revision) = try? configurationOrThrow() else { return }
        try await set(value, for: key, expectedRevision: revision)
    }

    // MARK: - Infisical REST

    private func accessToken(for configuration: Configuration, revision: Revision) async throws -> String {
        try checkCurrent(revision)
        // Prod-only guard: no login, read or write goes out for another environment.
        guard configuration.environment == Self.defaultEnvironment() else {
            throw SettingsError.invalidDestination
        }
        let url = configuration.siteURL.appendingPathComponent("api/v1/auth/universal-auth/login")
        let body = try JSONSerialization.data(withJSONObject: [
            "clientId": configuration.clientId,
            "clientSecret": configuration.clientSecret,
        ])
        let (data, status) = try await sending {
            try await self.transport.send(
                method: "POST",
                url: url,
                headers: ["Content-Type": "application/json"],
                body: body
            )
        }
        try checkCurrent(revision)
        guard status == 200 else { throw SettingsError.loginFailed(status: status) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["accessToken"] as? String, !token.isEmpty else {
            throw SettingsError.decoding("login response carried no accessToken")
        }
        return token
    }

    private func verifyProject(configuration: Configuration, token: String, revision: Revision) async throws {
        try checkCurrent(revision)
        let url = configuration.siteURL.appendingPathComponent("api/v1/projects")
            .appendingPathComponent(configuration.projectId)
        let (data, status) = try await sending {
            try await self.transport.send(method: "GET", url: url,
                                          headers: ["Authorization": "Bearer \(token)"], body: nil)
        }
        try checkCurrent(revision)
        guard status == 200 else { throw SettingsError.projectUnavailable(status: status) }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let project = json["project"] as? [String: Any],
              project["id"] as? String == configuration.projectId,
              let environments = project["environments"] as? [[String: Any]],
              environments.contains(where: { $0["slug"] as? String == configuration.environment }) else {
            throw SettingsError.invalidDestination
        }
    }

    private func fetchManaged(configuration: Configuration, revision: Revision,
                              verifyDestination: Bool = false) async throws -> [String: String] {
        let token = try await accessToken(for: configuration, revision: revision)
        if verifyDestination {
            try await verifyProject(configuration: configuration, token: token, revision: revision)
        }
        var values: [String: String] = [:]
        for key in Self.managedKeys {
            try checkCurrent(revision)
            guard var components = URLComponents(
                url: configuration.siteURL.appendingPathComponent("api/v3/secrets/raw").appendingPathComponent(key),
                resolvingAgainstBaseURL: false
            ) else {
                throw SettingsError.decoding("could not build the named secret URL")
            }
            components.queryItems = [
                URLQueryItem(name: "workspaceId", value: configuration.projectId),
                URLQueryItem(name: "environment", value: configuration.environment),
                URLQueryItem(name: "secretPath", value: "/"),
                URLQueryItem(name: "type", value: "shared"),
                URLQueryItem(name: "expandSecretReferences", value: "false"),
                URLQueryItem(name: "include_imports", value: "false"),
            ]
            guard let url = components.url else {
                throw SettingsError.decoding("could not build the named secret URL")
            }
            let (data, status) = try await sending {
                try await self.transport.send(
                    method: "GET",
                    url: url,
                    headers: ["Authorization": "Bearer \(token)"],
                    body: nil
                )
            }
            try checkCurrent(revision)
            if status == 404 { continue }
            guard status == 200 else { throw SettingsError.fetchFailed(status: status) }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let secret = json["secret"] as? [String: Any],
                  let returnedKey = secret["secretKey"] as? String, returnedKey == key,
                  let value = secret["secretValue"] as? String else {
                throw SettingsError.decoding("named secret response was invalid")
            }
            if !value.isEmpty { values[key] = value }
        }
        return values
    }

    private func writeSecret(configuration: Configuration, revision: Revision, key: String, value: String) async throws {
        let token = try await accessToken(for: configuration, revision: revision)
        let encoded = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        // The /raw/ write path accepts a plaintext secretValue (the pilot
        // validated this: the non-raw path demands client-side E2EE fields).
        let url = configuration.siteURL.appendingPathComponent("api/v3/secrets/raw/\(encoded)")
        let body = try JSONSerialization.data(withJSONObject: [
            "workspaceId": configuration.projectId,
            "environment": configuration.environment,
            "secretPath": "/",
            "secretValue": value,
            "type": "shared",
        ])
        let headers = ["Authorization": "Bearer \(token)", "Content-Type": "application/json"]
        let (_, patchStatus) = try await sending {
            try await self.transport.send(method: "PATCH", url: url, headers: headers, body: body)
        }
        try checkCurrent(revision)
        if patchStatus == 404 {
            // Secret does not exist yet — create it.
            let (_, postStatus) = try await sending {
                try await self.transport.send(method: "POST", url: url, headers: headers, body: body)
            }
            try checkCurrent(revision)
            guard (200...299).contains(postStatus) else {
                throw SettingsError.writeFailed(status: postStatus)
            }
            return
        }
        guard (200...299).contains(patchStatus) else {
            throw SettingsError.writeFailed(status: patchStatus)
        }
    }

    /// Maps transport-level failures into `SettingsError.transport` while
    /// letting `SettingsError` pass through untouched.
    private func sending(
        _ work: () async throws -> (data: Data, statusCode: Int)
    ) async throws -> (data: Data, statusCode: Int) {
        do {
            return try await work()
        } catch let error as SettingsError {
            throw error
        } catch {
            throw SettingsError.transport(error)
        }
    }
}
