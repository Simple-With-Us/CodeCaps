import Foundation

/// The one reader behind every declarative endpoint plugin.  It speaks the
/// same contract as the built-in readers — returns a `LocalQuotaResult`,
/// never throws to the caller, never logs a credential — over the shared
/// bounded transport (ephemeral session, no cookies, no redirects, byte and
/// time caps), so plugin windows flow through snapshot export, ranking,
/// and Settings toggles exactly like a built-in provider's.
public struct GenericEndpointQuotaReader: LocalQuotaReading, Sendable {
    private let descriptor: EndpointPluginDescriptor
    private let now: @Sendable () -> Date
    private let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let token: @Sendable () -> String?

    private static let maxResponseBytes = 262_144
    private static let timeout: TimeInterval = 15

    public init(
        descriptor: EndpointPluginDescriptor,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: @escaping @Sendable () -> Date = { Date() },
        fetch: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        self.descriptor = descriptor
        self.now = now
        switch descriptor.auth.type {
        case .none:
            self.token = { nil }
        case .bearerEnv:
            let name = descriptor.auth.env ?? ""
            // Defence in depth behind descriptor validation: only a
            // purpose-made plugin variable is ever read, whatever a
            // hand-built descriptor claims.
            self.token = {
                guard EndpointPluginDescriptor.isPluginEnvName(name) else { return nil }
                return environment[name].flatMap { $0.isEmpty ? nil : $0 }
            }
        }
        self.fetch = fetch ?? Self.makeFetcher()
    }

    public func read() async -> LocalQuotaResult {
        let id = descriptor.providerKey
        do {
            guard let url = descriptor.endpointURL else {
                return LocalQuotaResult(issues: [id: "\(descriptor.displayName) plugin endpoint is not a permitted address."])
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = Self.timeout
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if descriptor.auth.type == .bearerEnv {
                guard let token = token() else {
                    return LocalQuotaResult(issues: [id: "\(descriptor.displayName) plugin needs the \(descriptor.auth.env ?? "configured") environment variable set."])
                }
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let (data, response) = try await fetch(request)
            if response.statusCode == 401 || response.statusCode == 403 {
                return LocalQuotaResult(issues: [id: "\(descriptor.displayName) rejected the configured sign-in."])
            }
            guard (200..<300).contains(response.statusCode) else {
                return LocalQuotaResult(issues: [id: "\(descriptor.displayName) quota service is unavailable."])
            }
            guard data.count <= Self.maxResponseBytes,
                  let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return LocalQuotaResult(issues: [id: "\(descriptor.displayName) returned no readable quota."])
            }
            let windows = Self.parse(root, descriptor: descriptor, observedAt: now())
            if windows.isEmpty {
                return LocalQuotaResult(issues: [id: "\(descriptor.displayName) returned no readable quota."])
            }
            return LocalQuotaResult(windows: windows)
        } catch is CancellationError {
            return LocalQuotaResult(issues: [id: "\(descriptor.displayName) quota refresh was cancelled."])
        } catch {
            if Task.isCancelled {
                return LocalQuotaResult(issues: [id: "\(descriptor.displayName) quota refresh was cancelled."])
            }
            return LocalQuotaResult(issues: [id: "\(descriptor.displayName) quota service could not be reached."])
        }
    }

    static func parse(_ root: [String: Any], descriptor: EndpointPluginDescriptor, observedAt: Date) -> [QuotaWindow] {
        let observed = ISO8601DateFormatter().string(from: observedAt)
        return descriptor.windows.compactMap { spec in
            let absoluteRemaining = EndpointJSONPath.number(root, path: spec.absoluteRemainingPath)
            let absoluteLimit = EndpointJSONPath.number(root, path: spec.absoluteLimitPath)
            let remaining: Double?
            if let percent = EndpointJSONPath.number(root, path: spec.remainingPercentPath) {
                remaining = percent
            } else if let used = EndpointJSONPath.number(root, path: spec.usedPercentPath) {
                remaining = 100 - used
            } else if let absoluteRemaining, let absoluteLimit, absoluteLimit > 0 {
                remaining = absoluteRemaining / absoluteLimit * 100
            } else {
                remaining = nil
            }
            // An out-of-range percentage is a broken endpoint answer, not
            // a full or empty quota; drop the window as unreadable.
            guard let remaining, remaining.isFinite, (0...100).contains(remaining) else { return nil }
            let bounded = remaining
            return QuotaWindow(
                id: descriptor.providerKey + ":" + spec.idSuffix,
                provider: descriptor.providerKey, providerKey: descriptor.providerKey,
                providerLabel: descriptor.displayName, label: spec.label,
                remainingPercent: bounded,
                absoluteRemaining: absoluteRemaining, absoluteLimit: absoluteLimit,
                quotaUnit: spec.quotaUnit,
                planName: EndpointJSONPath.string(root, path: spec.planNamePath),
                isExhausted: bounded == 0, resetAt: resetTimestamp(root, path: spec.resetAtPath),
                window: spec.window, status: .derived(remainingPercent: bounded),
                occurredAt: observed, source: descriptor.id)
        }
    }

    /// A reset stamp may be ISO-8601 text or an epoch number; numbers at or
    /// above 10^12 are milliseconds, anything smaller is seconds.
    private static func resetTimestamp(_ root: [String: Any], path: String?) -> String? {
        guard let path else { return nil }
        if let text = EndpointJSONPath.string(root, path: path) {
            let iso = ISO8601DateFormatter()
            if iso.date(from: text) != nil { return text }
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if iso.date(from: text) != nil { return text }
            return nil
        }
        guard let epoch = EndpointJSONPath.number(root, path: path), epoch > 0, epoch < 10_000_000_000_000 else { return nil }
        let date = Date(timeIntervalSince1970: epoch >= 1_000_000_000_000 ? epoch / 1000 : epoch)
        return ISO8601DateFormatter().string(from: date)
    }

    static func makeFetcher() -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        return { request in
            try await BoundedHTTPFetch.data(for: request, timeout: Self.timeout, maxBytes: Self.maxResponseBytes)
        }
    }
}
