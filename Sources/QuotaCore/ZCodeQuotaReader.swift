import CryptoKit
import Foundation

/// Reads the GLM Coding Plan quota behind the local ZCode sign-in.
///
/// ZCode keeps its OAuth business tokens in `~/.zcode/v2/credentials.json`,
/// each value sealed as `enc:v1:<iv>.<tag>.<ciphertext>` with AES-256-GCM
/// under a key derived from a per-machine, non-secret fallback string
/// (ZCode's own `credentialCipherProvider.ts`: SHA-256 of
/// `zcode-credential-fallback:darwin:<home>:<user>`, overridable through
/// `ZCODE_CREDENTIAL_SECRET`).  Decrypted values never leave this type; when
/// the store cannot be read or opened the reader says so and publishes
/// nothing.
///
/// The monitor endpoint does NOT take the raw business token: ZCode's own
/// usage pipeline (`project-access-token-client.ts` +
/// `accountProviderCredentialService.ts`, whose comment states the material
/// is a request-time token that never touches the long-term key cache)
/// exchanges it for a short-lived project token and calls
/// `/api/monitor/usage/quota/limit` with `Bearer <project token>`.  This
/// reader mirrors that chain:
///
///   1. `GET /api/biz/customer/getCustomerInfo` to select the personal
///      organization/project (projects whose `projectType` is not `2`,
///      preferring 默认机构 / 默认项目);
///   2. `GET /api/biz/v1/organization/{org}/projects/{proj}/api_keys` to
///      find the existing `zcode-api-key` entry — LIST ONLY, a missing key
///      is reported as an issue, never created;
///   3. `POST {api_keys}/{apiKeyId}/access_tokens` to mint the request-time
///      token — the same sign-in material ZCode itself requests on every
///      refresh, not a persistent account change;
///   4. `GET /api/monitor/usage/quota/limit` with `Bearer <project token>`.
///
/// Version tolerance: no public 3.16.x source exists, so the contract is
/// grounded on the v3.15.1..v3.17.1 upstream bracket.  Every step is
/// byte-stable across the bracket EXCEPT customerInfo's z.ai authorization
/// (Bearer in 3.15.1, raw in 3.17.1, whose comment says a Bearer rejection
/// there would be misread as login invalidation).  That one call is tried
/// raw first and retried with `Bearer` only on an HTTP 401/403 — never on a
/// transport or payload failure.  Only ZCode's own origins are contacted.
public struct ZCodeQuotaReader: Sendable {
    private let now: @Sendable () -> Date
    private let credentials: @Sendable () -> [String: String]
    private let zcodeClientVersion: @Sendable () -> String?
    private let fetch: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private static let maxResponseBytes = 262_144
    private static let maxCredentialBytes = 1_048_576
    private static let timeout: TimeInterval = 15

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() },
        credentials: (@Sendable () -> [String: String])? = nil,
        zcodeClientVersion: (@Sendable () -> String?)? = nil,
        fetch: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil
    ) {
        self.now = now
        let home = homeDirectory.standardizedFileURL
        self.credentials = credentials ?? { Self.readLocalCredentials(home: home) }
        self.zcodeClientVersion = zcodeClientVersion ?? { Self.installedZCodeVersion() }
        self.fetch = fetch ?? Self.makeFetcher()
    }

    private enum Family {
        case zai
        case bigmodel
    }

    private struct Account {
        let family: Family
        let loginKey: String
        let origin: String
    }

    private static let accounts: [Account] = [
        // z.ai first: the desktop sign-in is a Z.ai account; the BigModel
        // token is the China-side equivalent of the same plan.
        Account(family: .zai, loginKey: "oauth:zai:access_token", origin: "https://api.z.ai"),
        Account(family: .bigmodel, loginKey: "oauth:bigmodel:access_token", origin: "https://bigmodel.cn"),
    ]

    /// Chain failures that map to honest account issues instead of the
    /// generic unavailable/rejected wording.
    private enum Flow: Error {
        /// 401/403 anywhere in the chain: the sign-in itself is rejected.
        case rejected
        /// Transport failure, non-success envelope, or malformed payload,
        /// tagged with the failing step and a coarse, privacy-safe category.
        case unavailable(Step, Category)
        /// A truthful account state to publish (no project, no key, disabled).
        case account(String)
    }

    /// The chain step a failure belongs to, named after ZCode's own calls.
    /// The raw values are the whole disclosure: no URLs, no parameters.
    private enum Step: String {
        case customerInfo
        case apiKeys
        case accessTokens
        case quota
    }

    /// Coarse failure category.  Bounded labels only, so repeated refreshes
    /// produce identical strings and no response body, token, or account
    /// identifier ever crosses into the issue text.
    private enum Category {
        case transport
        case http(Int)
        case envelope
        case malformed

        var label: String {
            switch self {
            case .transport: return "transport"
            case .http(let status): return "http \(status)"
            case .envelope: return "envelope"
            case .malformed: return "malformed response"
            }
        }
    }

    public func read() async -> LocalQuotaResult {
        do {
            let store = credentials()
            var sawCredential = false
            var rejected = false
            var firstAccountIssue: String?
            var firstUnavailable: (Step, Category)?
            for account in Self.accounts {
                guard let login = store[account.loginKey], Self.validToken(login) else { continue }
                sawCredential = true
                do {
                    return try await readAccount(account, login: login)
                } catch is CancellationError {
                    // Cooperative cancellation is not a transport failure;
                    // rethrow so the outer catch reports the cancellation.
                    throw CancellationError()
                } catch let flow as Flow {
                    switch flow {
                    case .rejected:
                        rejected = true
                    case .account(let message):
                        if firstAccountIssue == nil { firstAccountIssue = message }
                    case .unavailable(let step, let category):
                        if firstUnavailable == nil { firstUnavailable = (step, category) }
                    }
                } catch {
                    // One unreachable endpoint must not mask a healthy second
                    // account.
                }
            }
            if !sawCredential {
                // No ZCode sign-in on this Mac: the product is absent, not broken.
                return LocalQuotaResult()
            }
            if let firstAccountIssue {
                return LocalQuotaResult(issues: ["zcode": firstAccountIssue])
            }
            if rejected {
                return LocalQuotaResult(issues: ["zcode": "ZCode session was rejected; sign in again in ZCode."])
            }
            if let firstUnavailable {
                return LocalQuotaResult(issues: ["zcode": "ZCode quota service is unavailable (\(firstUnavailable.0.rawValue) step: \(firstUnavailable.1.label))."])
            }
            return LocalQuotaResult(issues: ["zcode": "ZCode quota service is unavailable."])
        } catch is CancellationError {
            return LocalQuotaResult(issues: ["zcode": "ZCode quota refresh was cancelled."])
        } catch {
            return LocalQuotaResult(issues: ["zcode": "ZCode quota service is unavailable."])
        }
    }

    private func readAccount(_ account: Account, login: String) async throws -> LocalQuotaResult {
        let (organizationId, projectId) = try await selectProject(account, login: login)
        let keyId = try await codingPlanKeyId(account, login: login, organizationId: organizationId, projectId: projectId)
        let token = try await mintProjectToken(account, login: login, organizationId: organizationId, projectId: projectId, keyId: keyId)
        return try await quota(account, token: token)
    }

    /// Step 1: the personal organization/project, per ZCode's own selection:
    /// non-team projects (`projectType` other than "2"), preferring the
    /// default-named organization and project, else the first of each.
    private func selectProject(_ account: Account, login: String) async throws -> (String, String) {
        let url = URL(string: "\(account.origin)/api/biz/customer/getCustomerInfo")!
        // The single bracket-unstable header: raw first, `Bearer` only after
        // an HTTP auth rejection, and never for the bigmodel family.
        // The retry trigger is deliberately HTTP-only: ZCode's own client
        // treats a non-success envelope as an invalid response, not an auth
        // signal, so a 200 with a failed envelope never swaps the header form.
        let forms = account.family == .zai ? [login, "Bearer \(login)"] : [login]
        for (index, header) in forms.enumerated() {
            let payload = try await requestStep(.customerInfo, "GET", url: url, authorization: header)
            if payload.statusCode == 401 || payload.statusCode == 403 {
                if index + 1 < forms.count { continue }
                throw Flow.rejected
            }
            guard (200..<300).contains(payload.statusCode) else {
                throw Flow.unavailable(.customerInfo, .http(payload.statusCode))
            }
            guard let data = Self.envelopeData(payload.root) as? [String: Any] else {
                throw Flow.unavailable(.customerInfo, payload.root == nil ? .malformed : .envelope)
            }
            guard let organizations = data["organizations"] as? [[String: Any]] else {
                throw Flow.unavailable(.customerInfo, .malformed)
            }
            // ZCode's own selection, kept exact: non-team projects, the
            // default-named organization/project when present, else first.
            let personal: [(id: String, name: String?, projects: [[String: Any]])] = organizations.compactMap { org in
                guard let organizationId = org["organizationId"] as? String, !organizationId.isEmpty else { return nil }
                let projects = (org["projects"] as? [[String: Any]] ?? []).filter { project in
                    if let type = project["projectType"] as? String { return type != "2" }
                    if let type = project["projectType"] as? NSNumber { return type.intValue != 2 }
                    return true
                }
                guard !projects.isEmpty else { return nil }
                return (organizationId, org["organizationName"] as? String, projects)
            }
            let org = personal.first(where: { $0.name?.contains("默认机构") == true }) ?? personal.first
            let project = org.flatMap { candidate in
                candidate.projects.first(where: { ($0["projectName"] as? String)?.contains("默认项目") == true }) ?? candidate.projects.first
            }
            guard let organizationId = org?.id,
                  let projectId = project?["projectId"] as? String, !projectId.isEmpty else {
                throw Flow.account("ZCode sign-in has no selectable personal project.")
            }
            return (organizationId, projectId)
        }
        // Unreachable (every iteration returns or throws) but required: the
        // compiler cannot prove the loop never completes normally.
        throw Flow.rejected
    }

    /// Step 2: the existing `zcode-api-key` entry's id.  LIST ONLY: ZCode
    /// creates the key here when absent, and this reader deliberately does
    /// not — an absent key is an account issue, not a mutation to perform.
    private func codingPlanKeyId(_ account: Account, login: String, organizationId: String, projectId: String) async throws -> String {
        let base = "\(account.origin)/api/biz/v1/organization/\(Self.pathEscape(organizationId))/projects/\(Self.pathEscape(projectId))/api_keys"
        let url = URL(string: base)!
        // Personal key management keeps the family-dependent form across the
        // whole bracket: z.ai Bearer, bigmodel raw.
        let header = account.family == .zai ? "Bearer \(login)" : login
        let payload = try await requestStep(.apiKeys, "GET", url: url, authorization: header)
        if payload.statusCode == 401 || payload.statusCode == 403 { throw Flow.rejected }
        guard (200..<300).contains(payload.statusCode) else {
            throw Flow.unavailable(.apiKeys, .http(payload.statusCode))
        }
        guard let list = Self.envelopeData(payload.root) as? [[String: Any]] else {
            throw Flow.unavailable(.apiKeys, payload.root == nil ? .malformed : .envelope)
        }
        for entry in list where entry["name"] as? String == "zcode-api-key" {
            if let id = entry["apiKey"] as? String, !id.isEmpty {
                return id
            }
        }
        throw Flow.account("ZCode account has no coding-plan API key yet; open ZCode once to finish the coding-plan setup.")
    }

    /// Step 3: mint the request-time project token.  `Bearer` for both
    /// families, stable across the bracket.  An envelope 404 means the key
    /// vanished.  The minted token is short-lived sign-in material (the
    /// payload carries its own expiry), the same call ZCode's monitor makes
    /// every refresh.  Live shape (z.ai, verified 2026-11-04): the mint
    /// payload names its flag `enabled` — `enable` never appears — and
    /// `enabled: false` still mints a token the quota endpoint accepts, so
    /// the flag is consulted only when no token came back.
    private func mintProjectToken(_ account: Account, login: String, organizationId: String, projectId: String, keyId: String) async throws -> String {
        let base = "\(account.origin)/api/biz/v1/organization/\(Self.pathEscape(organizationId))/projects/\(Self.pathEscape(projectId))/api_keys"
        let url = URL(string: "\(base)/\(Self.pathEscape(keyId))/access_tokens")!
        var body: [String: Any] = ["clientType": "zcode"]
        if let version = zcodeClientVersion() { body["clientVersion"] = version }
        let payload = try await requestStep(.accessTokens, "POST", url: url, authorization: "Bearer \(login)", body: body)
        if payload.statusCode == 401 || payload.statusCode == 403 { throw Flow.rejected }
        guard (200..<300).contains(payload.statusCode) else { throw Flow.unavailable(.accessTokens, .http(payload.statusCode)) }
        guard let root = payload.root else { throw Flow.unavailable(.accessTokens, .malformed) }
        if (root["code"] as? NSNumber)?.intValue == 404 || (root["code"] as? String) == "404" {
            throw Flow.account("ZCode's coding-plan key no longer exists; sign in again in ZCode.")
        }
        guard let data = Self.envelopeData(root) as? [String: Any] else { throw Flow.unavailable(.accessTokens, .envelope) }
        if let token = data["accessToken"] as? String, Self.validToken(token) {
            return token
        }
        if Self.booleanFlag(data, keys: ["enabled", "enable"]) == false {
            throw Flow.account("ZCode reports the coding-plan token disabled.")
        }
        throw Flow.unavailable(.accessTokens, .malformed)
    }

    /// Step 4: the quota read, always `Bearer <project token>` — the one
    /// credential form the bracket agrees on for this endpoint.
    private func quota(_ account: Account, token: String) async throws -> LocalQuotaResult {
        let url = URL(string: "\(account.origin)/api/monitor/usage/quota/limit")!
        let payload = try await requestStep(.quota, "GET", url: url, authorization: "Bearer \(token)")
        if payload.statusCode == 401 || payload.statusCode == 403 { throw Flow.rejected }
        guard (200..<300).contains(payload.statusCode) else { throw Flow.unavailable(.quota, .http(payload.statusCode)) }
        guard let root = payload.root else { throw Flow.unavailable(.quota, .malformed) }
        // Account truths are thrown, not returned: read() records the issue
        // and still tries the second account, which may be healthy.
        if let noPlan = Self.noPlanMessage(root) {
            throw Flow.account(noPlan)
        }
        guard Self.envelopeSucceeded(root), let data = root["data"] as? [String: Any] else { throw Flow.unavailable(.quota, .envelope) }
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
            throw Flow.account(message)
        }
        let issues = windows.allSatisfy { $0.remainingPercent == nil }
            ? ["zcode": "ZCode returned no readable quota."]
            : [:]
        return LocalQuotaResult(windows: windows, issues: issues)
    }

    private func request(
        _ method: String,
        url: URL,
        authorization: String,
        body: [String: Any]? = nil
    ) async throws -> ZCodeHTTPPayload {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = Self.timeout
        request.setValue(authorization, forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body, let encoded = try? JSONSerialization.data(withJSONObject: body) {
            request.httpBody = encoded
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await fetch(request)
        let root = data.count <= Self.maxResponseBytes
            ? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            : nil
        return ZCodeHTTPPayload(statusCode: response.statusCode, root: root)
    }

    /// One chain step's request, with transport failures tagged at the call
    /// site so a dead endpoint names its step instead of falling through
    /// silently.  Cancellation stays cancellation, never a transport report.
    private func requestStep(
        _ step: Step,
        _ method: String,
        url: URL,
        authorization: String,
        body: [String: Any]? = nil
    ) async throws -> ZCodeHTTPPayload {
        do {
            return try await request(method, url: url, authorization: authorization, body: body)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Flow.unavailable(step, .transport)
        }
    }
}

private struct ZCodeHTTPPayload {
    let statusCode: Int
    let root: [String: Any]?
}

private extension ZCodeQuotaReader {
    /// The success envelope ZCode's management and mint endpoints share:
    /// `code` 0 or 200, as a number or a string (`project-access-token-response.ts`).
    static func envelopeData(_ root: [String: Any]?) -> Any? {
        guard let root else { return nil }
        let code: Int?
        if let number = root["code"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            code = number.intValue
        } else if let text = root["code"] as? String {
            code = Int(text)
        } else {
            code = nil
        }
        guard code == 0 || code == 200 else { return nil }
        return root["data"]
    }

    /// `encodeURIComponent` semantics for ids inside a path: everything
    /// outside the unreserved set is escaped.
    static func pathEscape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? value
    }

    /// The first named key that carries a boolean-shaped value, tolerating
    /// the JSON bool, numeric 0/1, and "true"/"false" string forms seen
    /// across the management endpoints; nil when no key carries one.
    static func booleanFlag(_ data: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            guard let value = data[key] else { continue }
            if let bool = value as? Bool { return bool }
            if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
                return number.intValue != 0
            }
            if let text = value as? String {
                if text == "true" { return true }
                if text == "false" { return false }
            }
        }
        return nil
    }

    /// The installed ZCode app's own version, for the mint body's
    /// `clientVersion`; omitted when the app cannot be read.
    static func installedZCodeVersion() -> String? {
        let plist = URL(fileURLWithPath: "/Applications/ZCode.app/Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let version = root["CFBundleShortVersionString"] as? String,
              !version.isEmpty, version.utf8.count <= 40,
              version.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-")).contains) else { return nil }
        return version
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
            // `usage` is the server's own window cap (live-verified 2026-11-04:
            // 2000 per five hours, 10000 weekly) and currentValue is the
            // CONSUMED amount; the cap falls back to remaining + used only
            // when the payload names no usage figure.
            let used = number(limit["currentValue"])
            let cap: Double? = number(limit["usage"]) ?? remaining.flatMap { r in used.map { r + $0 } }
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
