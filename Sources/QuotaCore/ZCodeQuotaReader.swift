import CryptoKit
import Foundation

/// Reads the GLM Coding Plan quota behind the local ZCode sign-in.
///
/// ZCode keeps its OAuth business tokens in `~/.zcode/v2/credentials.json`,
/// each value sealed as `enc:v1:<iv>.<tag>.<ciphertext>` with AES-256-GCM
/// under a key derived from a per-machine, non-secret fallback string
/// (ZCode's own `credentialCipherProvider.ts`: SHA-256 of
/// `zcode-credential-fallback:darwin:<home>:<user>`, overridable through
/// `ZCODE_CREDENTIAL_SECRET`).  The monitor endpoint takes the credential
/// verbatim in the `authorization` header — ZCode's own client deliberately
/// adds no `Bearer` prefix.  Decrypted values never leave this type; when the
/// store cannot be read or opened the reader says so and publishes nothing.
public struct ZCodeQuotaReader: Sendable {
    private let now: @Sendable () -> Date
    private let credentials: @Sendable () -> [String: String]
    private let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private static let maxResponseBytes = 262_144
    private static let maxCredentialBytes = 1_048_576
    private static let timeout: TimeInterval = 15

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() },
        credentials: (@Sendable () -> [String: String])? = nil,
        fetch: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        self.now = now
        let home = homeDirectory.standardizedFileURL
        self.credentials = credentials ?? { Self.readLocalCredentials(home: home) }
        self.fetch = fetch ?? Self.makeFetcher()
    }

    public func read() async -> LocalQuotaResult {
        do {
            let store = credentials()
            // z.ai first: the desktop sign-in is a Z.ai account; the BigModel
            // token is the China-side equivalent of the same plan.
            let candidates: [(key: String, url: URL)] = [
                ("oauth:zai:access_token", URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!),
                ("oauth:bigmodel:access_token", URL(string: "https://bigmodel.cn/api/monitor/usage/quota/limit")!),
            ]
            var sawCredential = false
            var rejected = false
            for candidate in candidates {
                guard let token = store[candidate.key], Self.validToken(token) else { continue }
                sawCredential = true
                let result: ZCodeHTTPPayload
                do {
                    result = try await Self.fetchQuota(url: candidate.url, token: token, fetch: fetch)
                } catch is CancellationError {
                    // Cooperative cancellation is not a transport failure;
                    // rethrow so the outer catch reports the cancellation.
                    throw CancellationError()
                } catch {
                    // One unreachable endpoint must not mask a healthy second
                    // account.
                    continue
                }
                if result.statusCode == 401 || result.statusCode == 403 {
                    rejected = true
                    continue
                }
                guard (200..<300).contains(result.statusCode), let root = result.root else { continue }
                if let noPlan = Self.noPlanMessage(root) {
                    return LocalQuotaResult(issues: ["zcode": noPlan])
                }
                guard Self.envelopeSucceeded(root), let data = root["data"] as? [String: Any] else { continue }
                let windows = Self.parse(data, observedAt: now())
                if windows.isEmpty {
                    // A 200 envelope with an empty limits array is a truthful
                    // account state (no quota windows on this plan), not a
                    // parse failure; say so instead of claiming unreadability.
                    let rawLimits = data["limits"] as? [[String: Any]]
                    // Only an observed empty array is the truthful empty
                    // state; a missing or mistyped limits value is unreadable.
                    let message = (rawLimits?.isEmpty == true)
                        ? "ZCode returned no quota windows for this account."
                        : "ZCode returned no readable quota."
                    return LocalQuotaResult(issues: ["zcode": message])
                }
                let issues = windows.allSatisfy { $0.remainingPercent == nil }
                    ? ["zcode": "ZCode returned no readable quota."]
                    : [:]
                return LocalQuotaResult(windows: windows, issues: issues)
            }
            if !sawCredential {
                // No ZCode sign-in on this Mac: the product is absent, not broken.
                return LocalQuotaResult()
            }
            if rejected {
                return LocalQuotaResult(issues: ["zcode": "ZCode session was rejected; sign in again in ZCode."])
            }
            return LocalQuotaResult(issues: ["zcode": "ZCode quota service is unavailable."])
        } catch is CancellationError {
            return LocalQuotaResult(issues: ["zcode": "ZCode quota refresh was cancelled."])
        } catch {
            return LocalQuotaResult(issues: ["zcode": "ZCode quota service is unavailable."])
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
            return "No GLM Coding Plan is active on this ZCode account."
        }
        return nil
    }

    /// Maps `data.limits[]` onto windows.  Type semantics from ZCode's own
    /// presentation layer (`codingPlanQuotaPresentation.ts`): TOKENS_LIMIT
    /// (BigModel) and CREDIT_LIMIT (z.ai) are the same token buckets —
    /// `unit: 3` is the rolling five-hour window, `unit: 6` the weekly one —
    /// and TIME_LIMIT is the monthly tool-call quota.  `percentage` is the
    /// USED share; CodeCaps rows show what remains.
    static func parse(_ data: [String: Any], observedAt: Date) -> [QuotaWindow] {
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
                provider: "ZCode", providerKey: "zcode", providerLabel: "ZCode",
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

    // MARK: - Local credential store

    /// Decrypts the values of `~/.zcode/v2/credentials.json`.  Any entry that
    /// fails to open is dropped rather than failing the whole store, and a
    /// store that yields no usable values reads as "not signed in".
    static func readLocalCredentials(home: URL) -> [String: String] {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["ZCODE_DATA_BASE_DIR"].map { URL(fileURLWithPath: $0) } ?? home
        let file = base.appendingPathComponent(".zcode/v2/credentials.json")
        guard let data = try? Data(contentsOf: file, options: .mappedIfSafe),
              data.count <= Self.maxCredentialBytes,
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        let secret = environment["ZCODE_CREDENTIAL_SECRET"]
            ?? "zcode-credential-fallback:darwin:\(home.path):\(NSUserName())"
        let key = SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))
        var store: [String: String] = [:]
        for (name, value) in raw {
            guard let text = value as? String else { continue }
            if let opened = decrypt(text, key: key) {
                store[name] = opened
            } else if !text.hasPrefix("enc:v1:"), validToken(text) {
                store[name] = text
            }
        }
        return store
    }

    /// Opens one `enc:v1:<iv>.<tag>.<ciphertext>` value (AES-256-GCM, 12-byte
    /// nonce, 16-byte tag; base64url segments, in ZCode's own order).
    static func decrypt(_ value: String, key: SymmetricKey) -> String? {
        let prefix = "enc:v1:"
        guard value.hasPrefix(prefix) else { return nil }
        let parts = value.dropFirst(prefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let nonceData = base64url(parts[0]), nonceData.count == 12,
              let tagData = base64url(parts[1]), tagData.count == 16,
              let ciphertext = base64url(parts[2]), !ciphertext.isEmpty,
              let nonce = try? AES.GCM.Nonce(data: nonceData),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagData),
              let opened = try? AES.GCM.open(box, using: key) else {
            return nil
        }
        return String(data: opened, encoding: .utf8)
    }

    static func base64url(_ text: Substring) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    static func validToken(_ token: String) -> Bool {
        !token.isEmpty && token.utf8.count <= 8_192 && !token.contains("\r") && !token.contains("\n")
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
