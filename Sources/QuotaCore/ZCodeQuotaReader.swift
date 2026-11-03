import Foundation

/// One explicitly supplied Coding Plan key and its inseparable regional endpoint.
public enum ZCodeQuotaRegion: String, Codable, CaseIterable, Equatable, Sendable, Identifiable {
    case zAI = "zai"
    case bigModel = "bigmodel"
    public var id: String { rawValue }
    public var title: String { self == .zAI ? "Z.ai" : "BigModel" }
    public var quotaURL: URL {
        switch self {
        case .zAI: return URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
        case .bigModel: return URL(string: "https://bigmodel.cn/api/monitor/usage/quota/limit")!
        }
    }
}

public struct ZCodeQuotaCredential: Codable, Equatable, Sendable {
    public var region: ZCodeQuotaRegion
    public var apiKey: String

    public init(region: ZCodeQuotaRegion, apiKey: String) {
        self.region = region
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isValid: Bool {
        !apiKey.isEmpty && apiKey.utf8.count <= 8_192
            && apiKey.unicodeScalars.allSatisfy { $0.value >= 33 && $0.value <= 126 }
    }
}

/// Reads quota only with an explicitly supplied Coding Plan API key.
/// ZCode's OAuth business tokens are not quota credentials and are never read here.
public struct ZCodeQuotaReader: Sendable {
    private let now: @Sendable () -> Date
    private let credential: @Sendable () async -> ZCodeQuotaCredential?
    private let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private static let maxResponseBytes = 262_144
    private static let timeout: TimeInterval = 15

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        credential: (@Sendable () async -> ZCodeQuotaCredential?)? = nil,
        fetch: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        self.now = now
        self.credential = credential ?? { nil }
        self.fetch = fetch ?? Self.makeFetcher()
    }

    public func read() async -> LocalQuotaResult {
        do {
            try Task.checkCancellation()
            guard let credential = await credential(), credential.isValid else {
                return LocalQuotaResult(issues: ["zcode": "Z.ai quota setup is needed.\u{00A0} Save a Coding Plan API key in Sources & Fleet."])
            }
            try Task.checkCancellation()
            let result = try await Self.fetchQuota(url: credential.region.quotaURL, token: credential.apiKey, fetch: fetch)
            if result.statusCode == 401 || result.statusCode == 403 {
                return LocalQuotaResult(issues: ["zcode": "The saved Coding Plan API key was rejected."])
            }
            guard (200..<300).contains(result.statusCode), let root = result.root else {
                return LocalQuotaResult(issues: ["zcode": "Z.ai quota service is unavailable."])
            }
            if let noPlan = Self.noPlanMessage(root) { return LocalQuotaResult(issues: ["zcode": noPlan]) }
            guard Self.envelopeSucceeded(root), let data = root["data"] as? [String: Any] else {
                return LocalQuotaResult(issues: ["zcode": "Z.ai quota service is unavailable."])
            }
            let windows = Self.parse(data, observedAt: now(), region: credential.region)
            if windows.isEmpty {
                let rawLimits = data["limits"] as? [[String: Any]]
                let message = rawLimits?.isEmpty == true
                    ? "Z.ai returned no quota windows for this account." : "Z.ai returned no readable quota."
                return LocalQuotaResult(issues: ["zcode": message])
            }
            let issues = windows.allSatisfy { $0.remainingPercent == nil }
                ? ["zcode": "Z.ai returned no readable quota."] : [:]
            return LocalQuotaResult(windows: windows, issues: issues)
        } catch is CancellationError {
            return LocalQuotaResult(issues: ["zcode": "Z.ai quota refresh was cancelled."])
        } catch {
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                return LocalQuotaResult(issues: ["zcode": "Z.ai quota refresh was cancelled."])
            }
            return LocalQuotaResult(issues: ["zcode": "Z.ai quota service is unavailable."])
        }
    }
}

private struct ZCodeHTTPPayload {
    let statusCode: Int
    let root: [String: Any]?
}

private extension ZCodeQuotaReader {
    static func fetchQuota(
        url: URL,
        token: String,
        fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    ) async throws -> ZCodeHTTPPayload {
        // The monitor contract takes the credential verbatim.  Community
        // readers disagree and prepend `Bearer`, so a bare-credential 401 is
        // retried once with the prefix before the session is called rejected.
        for attempt in 0..<2 {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = Self.timeout
            let header = attempt == 0 ? token : "Bearer \(token)"
            request.setValue(header, forHTTPHeaderField: "authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let (data, response) = try await fetch(request)
            if response.statusCode == 401, attempt == 0 { continue }
            let root = data.count <= Self.maxResponseBytes
                ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                : nil
            return ZCodeHTTPPayload(statusCode: response.statusCode, root: root)
        }
        return ZCodeHTTPPayload(statusCode: 401, root: nil)
    }

    /// Success per ZCode's own envelope check: `success` not explicitly false
    /// and `code` absent, 0, or 200.
    static func envelopeSucceeded(_ root: [String: Any]) -> Bool {
        if let success = root["success"] as? Bool, !success { return false }
        guard let code = (root["code"] as? NSNumber)?.intValue else { return true }
        return code == 0 || code == 200
    }

    static func noPlanMessage(_ root: [String: Any]) -> String? {
        let message = (root["msg"] as? String) ?? (root["message"] as? String) ?? ""
        if message.contains("不存在coding plan") || message.contains("没有资格") {
            return "No GLM Coding Plan is active on this account."
        }
        return nil
    }

    /// Maps `data.limits[]` onto windows.  Type semantics from ZCode's own
    /// presentation layer (`codingPlanQuotaPresentation.ts`): TOKENS_LIMIT
    /// (BigModel) and CREDIT_LIMIT (z.ai) are the same token buckets —
    /// `unit: 3` is the rolling five-hour window, `unit: 6` the weekly one —
    /// and TIME_LIMIT is the monthly tool-call quota.  `percentage` is the
    /// USED share; CodeCaps rows show what remains.
    static func parse(_ data: [String: Any], observedAt: Date, region: ZCodeQuotaRegion) -> [QuotaWindow] {
        let observed = ISO8601DateFormatter().string(from: observedAt)
        let plan = (data["level"] as? String).flatMap { level -> String? in
            guard !level.isEmpty, level.utf8.count <= 40,
                  level.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " _+-")).contains) else { return nil }
            let normalized = level.prefix(1).uppercased() + level.dropFirst().lowercased()
            return "GLM Coding \(normalized)"
        }
        guard let limits = data["limits"] as? [[String: Any]] else { return [] }
        var windows: [QuotaWindow] = []
        for limit in limits {
            guard let type = limit["type"] as? String, !type.isEmpty else { continue }
            let unit = (limit["unit"] as? NSNumber)?.intValue
            let descriptor = descriptor(type: type, unit: unit)
            let percentage = number(limit["percentage"])
            let remaining = number(limit["remaining"])
            // currentValue is the CONSUMED amount and number is the window
            // length; the cap only exists when the payload names a remaining
            // figure, as remaining + used.
            let used = number(limit["currentValue"])
            let cap: Double? = remaining.flatMap { r in used.map { r + $0 } }
            let percent: Double?
            if let percentage {
                percent = min(100, max(0, 100 - percentage))
            } else if let remaining, let cap, cap > 0 {
                percent = min(100, max(0, remaining / cap * 100))
            } else {
                percent = nil
            }
            let exhausted = percent == 0
            windows.append(QuotaWindow(
                id: "local-mac:zcode:\(type.lowercased())-\(unit.map(String.init) ?? "x")",
                provider: region.title, providerKey: "zcode", providerLabel: region.title,
                sourceApp: "local-mac", label: descriptor.label,
                remainingPercent: percent,
                absoluteRemaining: remaining, absoluteLimit: cap,
                quotaUnit: descriptor.unitLabel,
                planName: plan,
                remainingUnknown: percent == nil,
                isExhausted: exhausted,
                resetAt: resetTimestamp(limit["nextResetTime"]),
                window: descriptor.window,
                status: QuotaWindowStatus.derived(remainingPercent: percent),
                skip: exhausted, skipReason: exhausted ? "quota exhausted" : nil,
                occurredAt: observed, source: "zcode"
            ))
        }
        return windows
    }

    static func descriptor(type: String, unit: Int?) -> (label: String, window: String, unitLabel: String) {
        if type == "TIME_LIMIT" {
            return ("MCP tool calls", "monthly", "calls")
        }
        let unitLabel = type == "CREDIT_LIMIT" ? "credits" : "tokens"
        switch unit {
        case 3: return ("5-hour limit", "5h", unitLabel)
        case 6: return ("Weekly limit", "weekly", unitLabel)
        default: return ("Usage limit", "unspecified", unitLabel)
        }
    }

    static func resetTimestamp(_ value: Any?) -> String? {
        guard let milliseconds = number(value), milliseconds > 0 else { return nil }
        return ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: milliseconds / 1000))
    }

    static func makeFetcher() -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        return { request in
            let config = URLSessionConfiguration.ephemeral
            config.httpCookieStorage = nil
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.timeoutIntervalForRequest = Self.timeout
            config.timeoutIntervalForResource = Self.timeout
            let session = URLSession(configuration: config, delegate: ZCodeNoRedirectDelegate(), delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ZCodeQuotaError.unavailable }
            if let length = http.value(forHTTPHeaderField: "Content-Length"), let count = Int(length), count > Self.maxResponseBytes {
                throw ZCodeQuotaError.unavailable
            }
            var data = Data()
            data.reserveCapacity(16_384)
            for try await byte in bytes {
                guard data.count < Self.maxResponseBytes else { throw ZCodeQuotaError.unavailable }
                data.append(byte)
            }
            return (data, http)
        }
    }

    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }
}

private enum ZCodeQuotaError: Error {
    case unavailable
}

private final class ZCodeNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
