import Foundation

/// The result of the local, read-only quota probes.
///
/// `issues` is deliberately a provider-keyed, user-safe map.  Credential
/// contents, account identifiers, response bodies, and underlying errors never
/// leave this type.
public struct LocalQuotaResult: Equatable, Sendable {
    public let windows: [QuotaWindow]
    public let issues: [String: String]
    /// Provider keys whose credential exists on this Mac but is unreadable
    /// until the owner allows this build once.  Kept apart from `issues`
    /// because it is the difference between "sign in" — which the owner
    /// cannot act on when they already have — and a button they can press.
    public let consentNeeded: Set<String>

    public init(windows: [QuotaWindow] = [],
                issues: [String: String] = [:],
                consentNeeded: Set<String> = []) {
        self.windows = windows
        self.issues = issues
        self.consentNeeded = consentNeeded
    }
}

/// Reads the quota sources that the vendor CLIs already use on this Mac.
///
/// The default instance has no configurable credential search path: it reads
/// only the four documented CLI files below and the single Antigravity helper
/// path.  Network requests use an ephemeral session and refuse redirects.
public struct LocalQuotaReader: Sendable {
    public static let providerKeys = ["anthropic", "openai", "xai", "minimax", "google-antigravity"]

    private let homeDirectory: URL
    private let now: @Sendable () -> Date
    private let fetchJSON: @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let runAntigravity: @Sendable () async throws -> Data
    private let readClaudeCredential: @Sendable () async -> ClaudeCredentialAccess
    private let renewClaudeLogin: @Sendable () async -> Void
    private let renewalThrottle: ClaudeRenewalThrottle
    private let claudeKeychainTimeout: TimeInterval

    private static let maxCredentialBytes = 1_048_576
    private static let maxResponseBytes = 1_048_576
    private static let maxProcessOutputBytes = 262_144
    private static let requestTimeout: TimeInterval = 15
    private static let processTimeout: TimeInterval = 30
    private static let claudeRenewTimeout: TimeInterval = 45

    /// `homeDirectory`, `now`, and the transport/process closures are
    /// injectable solely for offline tests.  Production uses the current home
    /// directory, a real clock, and the bounded transports below.
    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() },
        fetchJSON: (@Sendable (URLRequest) async throws -> (Data, HTTPURLResponse))? = nil,
        runAntigravity: (@Sendable () async throws -> Data)? = nil,
        readClaudeCredential: (@Sendable () async -> ClaudeCredentialAccess)? = nil,
        renewClaudeLogin: (@Sendable () async -> Void)? = nil,
        renewalThrottle: ClaudeRenewalThrottle = .shared,
        claudeKeychainTimeout: TimeInterval = ClaudeCredentialSource.boundedAccessTimeout
    ) {
        self.homeDirectory = homeDirectory.standardizedFileURL
        self.now = now
        self.fetchJSON = fetchJSON ?? Self.makeFetcher()
        self.runAntigravity = runAntigravity ?? Self.makeAntigravityRunner(homeDirectory: self.homeDirectory)
        if let readClaudeCredential { self.readClaudeCredential = readClaudeCredential }
        else if self.homeDirectory == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL {
            self.readClaudeCredential = { await ClaudeCredentialSource.access() }
        } else { self.readClaudeCredential = { .missing } }
        if let renewClaudeLogin { self.renewClaudeLogin = renewClaudeLogin }
        else if self.homeDirectory == FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL {
            self.renewClaudeLogin = Self.makeClaudeRenewer(homeDirectory: self.homeDirectory)
        } else { self.renewClaudeLogin = {} }
        self.renewalThrottle = renewalThrottle
        self.claudeKeychainTimeout = claudeKeychainTimeout
    }

    /// Reads all configured local sources concurrently.  This method never
    /// refreshes OAuth credentials itself and never posts telemetry.  The one
    /// exception is asking Claude Code to renew its own expired login, which
    /// Claude Code performs and writes on its own.
    public func read() async -> LocalQuotaResult {
        await withTaskGroup(of: ProviderRead.self, returning: LocalQuotaResult.self) { group in
            for provider in Provider.allCases {
                group.addTask { await self.read(provider: provider) }
            }

            var windows: [QuotaWindow] = []
            var issues: [String: String] = [:]
            var consentNeeded: Set<String> = []
            for await result in group {
                windows.append(contentsOf: result.windows)
                if let issue = result.issue { issues[result.provider.key] = issue }
                if result.needsConsent { consentNeeded.insert(result.provider.key) }
            }
            windows.sort { ($0.providerKey ?? $0.provider, $0.id) < ($1.providerKey ?? $1.provider, $1.id) }
            return LocalQuotaResult(windows: windows, issues: issues, consentNeeded: consentNeeded)
        }
    }

    private func read(provider: Provider) async -> ProviderRead {
        do {
            switch provider {
            case .claude: return try await readClaude()
            case .codex: return try await readCodex()
            case .grok: return try await readGrok()
            case .minimax: return try await readMiniMax()
            case .antigravity: return try await readAntigravity()
            }
        } catch let error as LocalReaderError {
            return ProviderRead(provider: provider, windows: [], issue: error.message)
        } catch is CancellationError {
            return ProviderRead(provider: provider, windows: [], issue: "Quota refresh was cancelled.")
        } catch {
            return ProviderRead(provider: provider, windows: [], issue: "Quota source is unavailable.")
        }
    }

    private func readClaude() async throws -> ProviderRead {
        let provider = Provider.claude
        var file = (try? readJSONObject(relativePath: ".claude/.credentials.json")) ?? [:]
        var candidate = ClaudeOAuthParser.validOAuth(in: file, now: now())
        // The Keychain is consulted only when Claude Code's own file has no
        // usable credential, so a fresh file never costs a Keychain call.
        var access = ClaudeCredentialAccess.missing
        var renewable = false
        if candidate == nil {
            access = await ClaudeCredentialSource.boundedAccess(timeout: claudeKeychainTimeout) { await readClaudeCredential() }
            // A read that could not finish says nothing about the login, so
            // stop here: no renewal run and no second read on a Mac that is
            // already too loaded to answer, and the row says "temporarily
            // unavailable" rather than "sign in" or "needs permission".
            if access == .temporarilyUnavailable {
                return ProviderRead(provider: provider, windows: [],
                                    issue: ClaudeLoginState.temporarilyUnavailable.issue)
            }
            var keychainRoot = credentialRoot(access)
            candidate = ClaudeOAuthParser.validOAuth(in: keychainRoot, now: now())
            renewable = ClaudeOAuthParser.isRenewable(in: file, now: now())
                || ClaudeOAuthParser.isRenewable(in: keychainRoot, now: now())
            // Claude Code refreshes its 8-hour access token only while it
            // runs.  An expired-but-renewable login means it is idle, so ask
            // it to renew its own login (at most once per 15 minutes) and
            // read the result back.  CodeCaps never writes or refreshes it.
            if candidate == nil, renewable,
               await renewalThrottle.perform(now: now(), action: renewClaudeLogin) {
                file = (try? readJSONObject(relativePath: ".claude/.credentials.json")) ?? [:]
                access = await ClaudeCredentialSource.boundedAccess(timeout: claudeKeychainTimeout) { await readClaudeCredential() }
                keychainRoot = credentialRoot(access)
                candidate = ClaudeOAuthParser.validOAuth(in: file, now: now())
                    ?? ClaudeOAuthParser.validOAuth(in: keychainRoot, now: now())
                renewable = ClaudeOAuthParser.isRenewable(in: file, now: now())
                    || ClaudeOAuthParser.isRenewable(in: keychainRoot, now: now())
            }
        }
        guard let oauth = candidate, let token = firstString(oauth, ["accessToken", "access_token"]) else {
            let state = ClaudeLoginState.resolve(hasUsableCredential: false, access: access, renewable: renewable)
            return ProviderRead(provider: provider, windows: [], issue: state.issue,
                                needsConsent: state.needsConsent)
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        // A file token the server rejects is "sign in again."  Only a token
        // that came from the remembered Keychain grant asks for Allow Access.
        let tokenFromKeychain = ClaudeOAuthParser.validOAuth(in: file, now: now()) == nil
        let payload: [String: Any]
        do {
            payload = try await requestJSON(request)
        } catch LocalReaderError.reauth {
            ClaudeCredentialSource.resetRememberedCredential()
            if tokenFromKeychain {
                var renewed = false
                if renewable {
                    renewed = await renewalThrottle.perform(now: now(), action: renewClaudeLogin)
                }
                if renewed {
                    let refreshedFile = (try? readJSONObject(relativePath: ".claude/.credentials.json")) ?? [:]
                    let refreshedAccess = await ClaudeCredentialSource.boundedAccess(timeout: claudeKeychainTimeout) { await readClaudeCredential() }
                    let refreshedKeychain = credentialRoot(refreshedAccess)
                    if let refreshedOAuth = ClaudeOAuthParser.validOAuth(in: refreshedFile, now: now())
                        ?? ClaudeOAuthParser.validOAuth(in: refreshedKeychain, now: now()),
                       let refreshedToken = firstString(refreshedOAuth, ["accessToken", "access_token"]) {
                        var retryRequest = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
                        retryRequest.httpMethod = "GET"
                        retryRequest.setValue("Bearer \(refreshedToken)", forHTTPHeaderField: "Authorization")
                        retryRequest.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
                        if let retryPayload = try? await requestJSON(retryRequest) {
                            let retryWindows = parseClaude(retryPayload, planType: firstString(refreshedOAuth, ["subscriptionType", "subscription_type"]), observedAt: now())
                            if !retryWindows.isEmpty {
                                return ProviderRead(provider: provider, windows: retryWindows, issue: nil)
                            }
                        }
                    }
                }
                let issue = renewable ? ClaudeLoginState.idle.issue : ClaudeLoginState.signedOut.issue
                return ProviderRead(provider: provider, windows: [], issue: issue,
                                    needsConsent: false)
            }
            throw LocalReaderError.reauth
        }
        let windows = parseClaude(payload, planType: firstString(oauth, ["subscriptionType", "subscription_type"]), observedAt: now())
        guard !windows.isEmpty else {
            return ProviderRead(provider: provider, windows: [unknownWindow(provider: provider, label: "Claude quota", observedAt: now())], issue: "Claude returned no readable quota windows.")
        }
        return ProviderRead(provider: provider, windows: windows, issue: nil)
    }

    /// The decoded Keychain record, or an empty dictionary when it is absent,
    /// unreadable, or oversized.
    private func credentialRoot(_ access: ClaudeCredentialAccess) -> [String: Any] {
        guard let data = access.data, data.count <= Self.maxCredentialBytes else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    private func readCodex() async throws -> ProviderRead {
        let provider = Provider.codex
        guard let root = try readJSONObject(relativePath: ".codex/auth.json") else {
            return ProviderRead(provider: provider, windows: [], issue: "Codex is not signed in locally.")
        }
        let tokens = record(root["tokens"])
        guard let token = firstString(tokens, ["access_token", "accessToken"]) else {
            return ProviderRead(provider: provider, windows: [], issue: "Codex is not signed in locally.")
        }

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("codex-cli", forHTTPHeaderField: "User-Agent")
        if let accountID = firstString(tokens, ["account_id", "accountId"]) { request.setValue(accountID, forHTTPHeaderField: "chatgpt-account-id") }
        let payload = try await requestJSON(request)
        let windows = parseCodex(payload, planType: firstString(root, ["plan_type", "planType", "plan"]), observedAt: now())
        guard !windows.isEmpty else {
            return ProviderRead(provider: provider, windows: [unknownWindow(provider: provider, label: "Codex quota", observedAt: now())], issue: "Codex returned no readable quota windows.")
        }
        return ProviderRead(provider: provider, windows: windows, issue: nil)
    }

    private func readGrok() async throws -> ProviderRead {
        let provider = Provider.grok
        guard let root = try readJSONObject(relativePath: ".grok/auth.json") else {
            return ProviderRead(provider: provider, windows: [], issue: "Grok is not signed in locally.")
        }
        // Try every plausible flat and nested key path against the root
        // first.  `firstString` walks dotted paths, so this list covers the
        // shapes where Grok stores under a `tokens` or `auth` sub-dict.
        let tokenKeys = [
            "key", "access_token", "accessToken", "token", "api_key", "apiKey",
            "tokens.key", "tokens.access_token", "tokens.accessToken",
            "tokens.token", "tokens.api_key", "tokens.apiKey",
            "auth.key", "auth.access_token", "auth.accessToken",
            "auth.token", "auth.api_key", "auth.apiKey",
        ]
        var token = firstString(root, tokenKeys)
        // Fall back to the single-key unwrap.  Grok also stores credentials
        // keyed by an endpoint URL (`{"https://api.x.ai": {"key": "..."}}`),
        // which is not reachable through the dotted-key list above because
        // the host name is data, not a known constant.  The unwrap only fires
        // when there is exactly one top-level key whose value is a dict, so
        // it cannot accidentally pick a wrong sub-dict when the file has
        // multiple sections.
        if token == nil {
            let profiles = root.values.compactMap { $0 as? [String: Any] }
            if root.count == 1, profiles.count == 1 {
                token = firstString(profiles[0], tokenKeys)
            }
        }
        guard let token else {
            return ProviderRead(provider: provider, windows: [], issue: "Grok is not signed in locally.")
        }
        let expiryKeys = ["expires_at", "expiresAt",
                          "tokens.expires_at", "tokens.expiresAt",
                          "auth.expires_at", "auth.expiresAt"]
        var expiry = firstTimestamp(root, expiryKeys)
        if expiry == nil {
            let profiles = root.values.compactMap { $0 as? [String: Any] }
            if root.count == 1, profiles.count == 1 {
                expiry = firstTimestamp(profiles[0], expiryKeys)
            }
        }
        if let expiry, let date = parseDate(expiry), date <= now() {
            return ProviderRead(provider: provider, windows: [], issue: "Grok needs you to sign in again.")
        }
        var request = URLRequest(url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let payload = try await requestJSON(request)
        let windows = parseGrok(payload, observedAt: now())
        return ProviderRead(provider: provider, windows: windows, issue: windows.first?.remainingPercent == nil ? "Grok returned no readable quota percentage." : nil)
    }

    private func readMiniMax() async throws -> ProviderRead {
        let provider = Provider.minimax
        guard let root = try readJSONObject(relativePath: ".mmx/config.json") else {
            return ProviderRead(provider: provider, windows: [], issue: "MiniMax is not signed in locally.")
        }
        guard let token = firstString(root, ["api_key", "apiKey", "key", "token", "auth.api_key", "auth.apiKey"]) else {
            return ProviderRead(provider: provider, windows: [], issue: "MiniMax is not signed in locally.")
        }
        var lastError: LocalReaderError = .unavailable
        for endpoint in ["https://api.minimax.io/v1/api/openplatform/coding_plan/remains", "https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains"] {
            var request = URLRequest(url: URL(string: endpoint)!)
            request.httpMethod = "GET"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            do {
                let payload = try await requestJSON(request)
                let windows = parseMiniMax(payload, observedAt: now())
                guard !windows.isEmpty else {
                    return ProviderRead(provider: provider, windows: [unknownWindow(provider: provider, label: "MiniMax quota", observedAt: now())], issue: "MiniMax returned no readable quota windows.")
                }
                return ProviderRead(provider: provider, windows: windows, issue: nil)
            } catch let error as LocalReaderError {
                lastError = error
            }
        }
        throw lastError
    }

    private func readAntigravity() async throws -> ProviderRead {
        let provider = Provider.antigravity
        let data = try await runAntigravity()
        guard data.count <= Self.maxProcessOutputBytes,
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return ProviderRead(provider: provider, windows: [unknownWindow(provider: provider, label: "Antigravity quota", observedAt: now())], issue: "Antigravity quota output was unavailable.")
        }
        let windows = parseAntigravity(object, observedAt: now())
        guard !windows.isEmpty else {
            return ProviderRead(provider: provider, windows: [unknownWindow(provider: provider, label: "Antigravity quota", observedAt: now())], issue: "Antigravity returned no readable quota windows.")
        }
        return ProviderRead(provider: provider, windows: windows, issue: nil)
    }

    private func readJSONObject(relativePath: String) throws -> [String: Any]? {
        let url = homeDirectory.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            data = try handle.read(upToCount: Self.maxCredentialBytes + 1) ?? Data()
        }
        catch { throw LocalReaderError.unavailable }
        guard data.count <= Self.maxCredentialBytes else { throw LocalReaderError.unavailable }
        guard let object = try? JSONSerialization.jsonObject(with: data), let root = object as? [String: Any] else { throw LocalReaderError.malformed }
        return root
    }

    private func requestJSON(_ request: URLRequest) async throws -> [String: Any] {
        do {
            let (data, response) = try await fetchJSON(request)
            guard (200..<300).contains(response.statusCode) else {
                if response.statusCode == 401 || response.statusCode == 403 { throw LocalReaderError.reauth }
                throw LocalReaderError.unavailable
            }
            guard data.count <= Self.maxResponseBytes,
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let root = object as? [String: Any] else { throw LocalReaderError.malformed }
            return root
        } catch let error as LocalReaderError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw LocalReaderError.unavailable }
    }
}

private enum Provider: String, CaseIterable, Sendable {
    case claude, codex, grok, minimax, antigravity
    var key: String {
        switch self { case .claude: return "anthropic"; case .codex: return "openai"; case .grok: return "xai"; case .minimax: return "minimax"; case .antigravity: return "google-antigravity" }
    }
    var label: String {
        switch self { case .claude: return "Claude Code"; case .codex: return "Codex"; case .grok: return "Grok"; case .minimax: return "MiniMax"; case .antigravity: return "Antigravity" }
    }
    var via: String? { self == .antigravity ? "antigravity" : nil }
}

private struct ProviderRead: Sendable {
    let provider: Provider
    let windows: [QuotaWindow]
    let issue: String?
    /// True only for the Claude reader, and only when a Claude Code login is
    /// present but this build has not been allowed to read it.
    var needsConsent: Bool = false
}

private enum LocalReaderError: Error {
    case unavailable, malformed, reauth
    var message: String {
        switch self { case .unavailable: return "Quota source is unavailable."; case .malformed: return "Quota response was unavailable."; case .reauth: return "This account needs you to sign in again." }
    }
}

private func record(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }

private func firstString(_ root: [String: Any], _ keys: [String]) -> String? {
    for key in keys {
        var value: Any? = root
        for part in key.split(separator: ".") { value = record(value)[String(part)] }
        if let string = value as? String,
           !string.contains("\r"), !string.contains("\n"),
           !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
    return nil
}

private func firstNumber(_ root: [String: Any], _ keys: [String]) -> Double? {
    for key in keys {
        let value = root[key]
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite { return number.doubleValue }
        if let string = value as? String, let number = Double(string), number.isFinite { return number }
    }
    return nil
}

private func validTimestamp(_ value: Any?) -> String? {
    if let string = value as? String, parseDate(string) != nil { return string }
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite {
        let seconds = number.doubleValue > 10_000_000_000 ? number.doubleValue / 1000 : number.doubleValue
        return isoFormatter.string(from: Date(timeIntervalSince1970: seconds))
    }
    return nil
}

private func parseDate(_ value: String) -> Date? {
    ISO8601DateFormatter().date(from: value) ?? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter.date(from: value)
    }()
}

private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter
}()

private func percentage(_ value: Double?) -> Double? {
    guard let value, value.isFinite else { return nil }
    return min(100, max(0, value))
}

private func windowToken(seconds: Double?) -> String? {
    guard let seconds, seconds.isFinite, seconds >= 1, seconds <= 31_536_000 else { return nil }
    let rounded = Int(seconds.rounded())
    if rounded % 604800 == 0 { return "\(rounded / 604800)w" }
    if rounded % 86400 == 0 { return "\(rounded / 86400)d" }
    if rounded % 3600 == 0 { return "\(rounded / 3600)h" }
    return nil
}

private func window(
    provider: Provider,
    id: String,
    label: String,
    remaining: Double?,
    resetAt: String?,
    windowToken: String?,
    modelId: String? = nil,
    modelType: String? = nil,
    absoluteRemaining: Double? = nil,
    absoluteLimit: Double? = nil,
    quotaUnit: String? = nil,
    planName: String? = nil,
    periodStart: String? = nil,
    observedAt: Date
) -> QuotaWindow {
    let bounded = percentage(remaining)
    return QuotaWindow(
        id: "local-mac:\(provider.key):\(id)", provider: provider.label,
        providerKey: provider.key, providerLabel: provider.label, via: provider.via,
        sourceApp: "local-mac", modelId: modelId, modelType: modelType, label: label,
        remainingPercent: bounded, absoluteRemaining: absoluteRemaining, absoluteLimit: absoluteLimit,
        quotaUnit: quotaUnit, planName: planName,
        resetAt: resetAt, window: windowToken,
        occurredAt: isoFormatter.string(from: observedAt), source: provider.label,
        periodStart: periodStart
    ).normalizedForExport()
}

private func unknownWindow(provider: Provider, label: String, observedAt: Date) -> QuotaWindow {
    window(provider: provider, id: "unknown", label: label, remaining: nil, resetAt: nil, windowToken: nil, observedAt: observedAt)
}

private func parseClaude(_ root: [String: Any], planType: String?, observedAt: Date) -> [QuotaWindow] {
    let suffixes = ["opus", "sonnet", "haiku"]
    var result: [QuotaWindow] = []
    for (key, raw) in root {
        let value = record(raw)
        let utilization = firstNumber(value, ["utilization", "utilization_percent", "utilizationPercent", "used_percent", "usedPercent"])
        let direct = firstNumber(value, ["remaining_percent", "remainingPercent"])
        guard utilization != nil || direct != nil else { continue }
        var base = key; var model: String?
        for suffix in suffixes where key.hasSuffix("_\(suffix)") { model = suffix; base = String(key.dropLast(suffix.count + 1)); break }
        guard let token = claudeToken(base) ?? claudeToken(key) else { continue }
        let remaining = direct.map(percentage) ?? utilization.map { 100 - min(100, max(0, $0)) }
        let title = model.map { "\($0.prefix(1).uppercased())\($0.dropFirst())" }
        // The rate-limit key's suffix names the model family, not one model id,
        // so it is the family a consumer can route on.  Keys with no suffix
        // cover the whole subscription and leave the family empty.
        result.append(window(provider: .claude, id: key, label: title == nil ? "\(token) window" : "\(token) window (\(title!))", remaining: remaining, resetAt: firstTimestamp(value, ["resets_at", "resetsAt", "reset_at", "resetAt"]), windowToken: token, modelId: model, modelType: model, planName: planType, observedAt: observedAt))
    }
    return result.sorted { $0.id < $1.id }
}

private func claudeToken(_ value: String) -> String? {
    let parts = value.split(separator: "_"); guard parts.count >= 2 else { return nil }
    let units = ["hour": "h", "day": "d", "week": "w", "month": "mo"]
    let unit = String(parts[parts.count - 1]).replacingOccurrences(of: "s", with: "")
    guard let suffix = units[unit] else { return nil }
    let count = Int(parts[parts.count - 2]) ?? ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "seven": 7, "ten": 10, "twelve": 12, "fourteen": 14, "thirty": 30][String(parts[parts.count - 2])]
    return count.map { "\($0)\(suffix)" }
}

private func parseCodex(_ root: [String: Any], planType: String?, observedAt: Date) -> [QuotaWindow] {
    let limits = record(root["rate_limit"] ?? root["rateLimit"] ?? root["rate_limits"] ?? root["rateLimits"] ?? root["limits"])
    var result: [QuotaWindow] = []
    func append(_ slot: String, _ value: [String: Any], modelId: String? = nil) {
        let used = firstNumber(value, ["used_percent", "usedPercent", "utilization", "percent_used"])
        let direct = firstNumber(value, ["remaining_percent", "remainingPercent"])
        guard used != nil || direct != nil else { return }
        let token = windowToken(seconds: firstNumber(value, ["limit_window_seconds", "limitWindowSeconds", "window_seconds"])) ?? firstNumber(value, ["window_minutes", "windowMinutes"]).flatMap { windowToken(seconds: $0 * 60) }
        let reset = firstTimestamp(value, ["resets_at", "resetsAt", "reset_at", "resetAt"]) ?? firstNumber(value, ["reset_after_seconds", "resetAfterSeconds", "resets_in_seconds"]).flatMap { seconds in seconds >= 0 && seconds.isFinite && seconds <= 31_536_000 ? isoFormatter.string(from: observedAt.addingTimeInterval(seconds)) : nil }
        let remaining = direct.map(percentage) ?? used.map { 100 - min(100, max(0, $0)) }
        let suffix = modelId.map { " (\($0))" } ?? ""
        result.append(window(provider: .codex, id: slot, label: token.map { "\($0) window\(suffix)" } ?? "\(slot.capitalized) window\(suffix)", remaining: remaining, resetAt: reset, windowToken: token, modelId: modelId, planName: planType, observedAt: observedAt))
    }
    for (slot, names) in [("primary", ["primary_window", "primaryWindow", "primary"]), ("secondary", ["secondary_window", "secondaryWindow", "secondary"])] {
        var raw: Any?
        for name in names where limits[name] != nil { raw = limits[name]; break }
        let value = record(raw)
        guard !value.isEmpty else { continue }
        append(slot, value)
    }
    let additional = limits["additional_rate_limits"] ?? limits["additionalRateLimits"] ?? root["additional_rate_limits"] ?? root["additionalRateLimits"]
    if let records = additional as? [[String: Any]] {
        for (index, entry) in records.enumerated() {
            let name = firstString(entry, ["name", "id", "model", "model_id", "modelId"]) ?? "additional-\(index + 1)"
            append(name, entry, modelId: firstString(entry, ["model", "model_id", "modelId"]))
        }
    } else if let records = additional as? [String: Any] {
        for (name, raw) in records { append(name, record(raw), modelId: name) }
    }
    return result
}

private func parseGrok(_ root: [String: Any], observedAt: Date) -> [QuotaWindow] {
    let config = record(root["config"])
    if let used = firstNumber(config, ["creditUsagePercent"]) {
        let period = record(config["currentPeriod"])
        let reset = firstTimestamp(period, ["end"]) ?? firstTimestamp(config, ["billingPeriodEnd"])
        let start = firstTimestamp(period, ["start"]) ?? firstTimestamp(config, ["billingPeriodStart"])
        let cadence: String? = if let start, let reset, let startDate = parseDate(start), let endDate = parseDate(reset) {
            windowToken(seconds: endDate.timeIntervalSince(startDate))
        } else { nil }
        // On-demand caps and prepaid balances are separate from this subscription.
        return [window(provider: .grok, id: "subscription", label: cadence.map { "\($0) window" } ?? "Subscription window",
                       remaining: 100 - used, resetAt: reset, windowToken: cadence, periodStart: start, observedAt: observedAt)]
    }
    let nested = record(root["credits"] ?? root["usage"] ?? root["billing"] ?? root["data"])
    var merged = nested; for (key, value) in root { merged[key] = value }
    let remainingDirect = firstNumber(merged, ["remainingPercent", "remaining_percent", "percentageRemaining", "percentage_remaining"])
    let usedDirect = firstNumber(merged, ["usedPercent", "used_percent", "percentage", "percentageUsed", "percentage_used", "utilization"])
    let usedCount = firstNumber(nested, ["used", "used_credits", "usedCredits"]) ?? firstNumber(root, ["used", "used_credits", "usedCredits"])
    let limit = firstNumber(nested, ["limit", "total", "quota", "limit_credits"]) ?? firstNumber(root, ["limit", "total", "quota", "limit_credits"])
    let remainingCount = firstNumber(merged, ["remaining", "remaining_credits"])
    let used = usedDirect ?? (usedCount.flatMap { u in limit.map { l in l > 0 ? u / l * 100 : nil } } ?? nil)
    let remaining = remainingDirect ?? used.map { 100 - $0 } ?? (remainingCount.flatMap { r in limit.map { l in l > 0 ? r / l * 100 : nil } } ?? nil)
    let seconds = firstNumber(merged, ["limit_window_seconds", "limitWindowSeconds", "window_seconds"])
    let token = windowToken(seconds: seconds) ?? firstString(merged, ["window", "period", "interval", "cadence"])
    let absoluteRemaining = remainingCount ?? (limit.flatMap { l in usedCount.map { l - $0 } })
    return [window(provider: .grok, id: token ?? "quota", label: token.map { "\($0) window" } ?? "Quota window", remaining: remaining, resetAt: firstTimestamp(merged, ["resetAt", "reset_at", "nextResetAt", "next_reset_at", "resets_at", "resetsAt", "renewal_date", "period_end"]), windowToken: token, absoluteRemaining: absoluteRemaining, absoluteLimit: limit, quotaUnit: limit == nil ? nil : "credits", planName: firstString(merged, ["tier", "plan", "plan_type", "planType", "subscription"]), observedAt: observedAt)]
}

private func parseMiniMax(_ root: [String: Any], observedAt: Date) -> [QuotaWindow] {
    let status = firstNumber(record(root["base_resp"] ?? root["baseResp"]), ["status_code", "statusCode"])
    if status != nil && status != 0 { return [] }
    let payload = record(root["data"])
    let rows = (root["model_remains"] ?? root["modelRemains"] ?? payload["model_remains"] ?? payload["modelRemains"]) as? [[String: Any]] ?? []
    let planName = firstString(root, ["plan", "plan_type", "planType", "subscription", "subscription_type"])
        ?? firstString(payload, ["plan", "plan_type", "planType", "subscription", "subscription_type", "plan_name", "planName"])
    let millisReset: (Double?) -> String? = { millis in
        guard let millis, millis.isFinite, millis >= 0, millis <= 31_536_000_000 else { return nil }
        let date = observedAt.addingTimeInterval(millis / 1000)
        return date.timeIntervalSince1970.isFinite ? isoFormatter.string(from: date) : nil
    }
    let countRemaining: ([String: Any], [String], [String]) -> (remaining: Double, limit: Double)? = { row, remainingKeys, limitKeys in
        guard let remaining = firstNumber(row, remainingKeys), remaining >= 0,
              let limit = firstNumber(row, limitKeys), limit > 0 else { return nil }
        return (remaining, limit)
    }
    let percentageRemaining: ([String: Any], [String]) -> Double? = { row, keys in
        guard let value = firstNumber(row, keys) else { return nil }
        return percentage(value)
    }
    var result: [QuotaWindow] = []
    for row in rows {
        let model = firstString(row, ["model_name", "modelName", "model"]) ?? "model"
        let intervalPercent = percentageRemaining(row, ["current_interval_remaining_percent", "currentIntervalRemainingPercent"])
        let weeklyPercent = percentageRemaining(row, ["current_weekly_remaining_percent", "currentWeeklyRemainingPercent"])
        let intervalCounts = countRemaining(
            row,
            ["current_interval_remaining_count", "currentIntervalRemainingCount", "current_interval_remains_count", "currentIntervalRemainsCount", "current_interval_usage_count", "currentIntervalUsageCount", "usage_count"],
            ["current_interval_total_count", "currentIntervalTotalCount", "total_count"]
        )
        let weeklyCounts = countRemaining(
            row,
            ["current_weekly_remaining_count", "currentWeeklyRemainingCount", "current_weekly_remains_count", "currentWeeklyRemainsCount", "current_weekly_usage_count", "currentWeeklyUsageCount"],
            ["current_weekly_total_count", "currentWeeklyTotalCount"]
        )

        let intervalReset = firstTimestamp(row, ["current_interval_end_time", "currentIntervalEndTime", "interval_end_time", "intervalEndTime", "end_time", "endTime", "reset_time", "resetAt"])
            ?? millisReset(firstNumber(row, ["remains_time", "remainsTime"]))
        let weeklyReset = firstTimestamp(row, ["current_weekly_end_time", "currentWeeklyEndTime", "weekly_end_time", "weeklyEndTime", "weekly_reset_time", "weeklyResetTime", "weekly_reset_at", "weeklyResetAt"])
            ?? millisReset(firstNumber(row, ["weekly_remains_time", "weeklyRemainsTime"]))
        let intervalStart = firstTimestamp(row, ["current_interval_start_time", "currentIntervalStartTime", "start_time", "startTime"])
        let weeklyStart = firstTimestamp(row, ["current_weekly_start_time", "currentWeeklyStartTime", "weekly_start_time", "weeklyStartTime"])
        let intervalToken: String? = if let intervalStart, let intervalReset, let start = parseDate(intervalStart), let end = parseDate(intervalReset) {
            windowToken(seconds: end.timeIntervalSince(start))
        } else {
            nil
        }
        let weeklyToken: String? = if let weeklyStart, let weeklyReset, let start = parseDate(weeklyStart), let end = parseDate(weeklyReset) {
            windowToken(seconds: end.timeIntervalSince(start))
        } else {
            "weekly"
        }

        let intervalRemaining = intervalPercent ?? intervalCounts.map { $0.remaining / $0.limit * 100 }
        let weeklyRemaining = weeklyPercent ?? weeklyCounts.map { $0.remaining / $0.limit * 100 }

        let isGeneral = model.lowercased() == "general" || model.lowercased() == "coding_plan"
        let isVideo = model.lowercased().contains("video") || model.lowercased().contains("hailuo")
        let intervalLabel: String
        let weeklyLabel: String
        if isGeneral {
            intervalLabel = intervalToken == "5h" ? "5-hour window" : (intervalToken.map { "\($0) window" } ?? "5-hour window")
            weeklyLabel = (weeklyToken == "1w" || weeklyToken == "weekly") ? "Weekly window" : (weeklyToken.map { "\($0) window" } ?? "Weekly window")
        } else if isVideo {
            intervalLabel = "Video"
            weeklyLabel = "Video (Weekly window)"
        } else {
            intervalLabel = intervalToken.map { "\(model) (\($0) window)" } ?? "\(model) (interval window)"
            weeklyLabel = weeklyToken.map { "\(model) (\($0) window)" } ?? "\(model) (weekly window)"
        }

        if isVideo {
            // MiniMax coding plan has the 5h and 1w quotas.  Video is supplementary and discrete
            // (e.g. 5/5 left per day).  The extraneous weekly video window (35/35) is omitted.
            if intervalPercent != nil || intervalCounts != nil || intervalReset != nil {
                let remaining = intervalCounts?.remaining ?? 5
                let limit = intervalCounts?.limit ?? 5
                result.append(window(provider: .minimax, id: "\(model):interval", label: intervalLabel, remaining: intervalRemaining ?? 100, resetAt: intervalReset, windowToken: intervalToken ?? "1d", modelId: model, absoluteRemaining: remaining, absoluteLimit: limit, quotaUnit: "videos", planName: planName, periodStart: intervalStart, observedAt: observedAt))
            }
            continue
        }

        if intervalPercent != nil || intervalCounts != nil || intervalReset != nil {
            result.append(window(provider: .minimax, id: "\(model):interval", label: intervalLabel, remaining: intervalRemaining, resetAt: intervalReset, windowToken: intervalToken, modelId: model, absoluteRemaining: intervalCounts?.remaining, absoluteLimit: intervalCounts?.limit, quotaUnit: intervalCounts == nil ? nil : "requests", planName: planName, periodStart: intervalStart, observedAt: observedAt))
        }
        if weeklyPercent != nil || weeklyCounts != nil || weeklyReset != nil {
            result.append(window(provider: .minimax, id: "\(model):weekly", label: weeklyLabel, remaining: weeklyRemaining, resetAt: weeklyReset, windowToken: weeklyToken, modelId: model, absoluteRemaining: weeklyCounts?.remaining, absoluteLimit: weeklyCounts?.limit, quotaUnit: weeklyCounts == nil ? nil : "requests", planName: planName, periodStart: weeklyStart, observedAt: observedAt))
        }
        if intervalPercent == nil, intervalCounts == nil, intervalReset == nil, weeklyPercent == nil, weeklyCounts == nil, weeklyReset == nil {
            result.append(window(provider: .minimax, id: "\(model):unknown", label: model, remaining: nil, resetAt: nil, windowToken: nil, modelId: model, planName: planName, observedAt: observedAt))
        }
    }
    return result
}

private func parseAntigravity(_ object: Any, observedAt: Date) -> [QuotaWindow] {
    let root = object as? [String: Any]
    let entries = (root?["models"] ?? root?["quotas"] ?? root?["records"] ?? object) as? [[String: Any]] ?? []
    var result: [QuotaWindow] = []
    for entry in entries {
        guard let model = firstString(entry, ["modelId", "model", "id", "name"]) else { continue }
        let fraction = firstNumber(entry, ["remainingPercentage", "remaining_percentage"])
        let remaining = entry["isExhausted"] as? Bool == true ? 0 : fraction.map { min(1, max(0, $0)) * 100 } ?? 0
        let reset = firstTimestamp(entry, ["resetTime", "reset_time", "resetsAt"])
        let token = firstString(entry, ["window", "period"])
        result.append(window(provider: .antigravity, id: model, label: firstString(entry, ["label", "name"]) ?? model, remaining: remaining, resetAt: reset, windowToken: token, modelId: model, observedAt: observedAt))
    }
    return result
}

private func firstTimestamp(_ root: [String: Any], _ keys: [String]) -> String? {
    for key in keys where root[key] != nil { if let timestamp = validTimestamp(root[key]) { return timestamp } }
    return nil
}

private extension LocalQuotaReader {
    static func makeFetcher() -> @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse) {
        return { request in
            let delegate = RedirectRefusingURLSessionDelegate()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = requestTimeout
            configuration.timeoutIntervalForResource = requestTimeout
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            defer { session.invalidateAndCancel() }
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw LocalReaderError.unavailable }
            if let length = http.value(forHTTPHeaderField: "Content-Length"), let count = Int(length), count > maxResponseBytes { throw LocalReaderError.unavailable }
            var data = Data()
            data.reserveCapacity(min(maxResponseBytes, 16_384))
            for try await byte in bytes {
                guard data.count < maxResponseBytes else { throw LocalReaderError.unavailable }
                data.append(byte)
            }
            return (data, http)
        }
    }

    /// Asks Claude Code to renew its own expired login.  `/usage` costs no
    /// model tokens and no quota, but starting a session makes Claude Code
    /// refresh and rewrite its own saved login.  Output is discarded unread,
    /// and a missing binary or any failure quietly does nothing.
    static func makeClaudeRenewer(homeDirectory: URL) -> @Sendable () async -> Void {
        let candidates = [
            homeDirectory.appendingPathComponent(".local/bin/claude").path,
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return {
            guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }
            _ = try? await BoundedQuotaProcess().run(
                path: path,
                arguments: ["-p", "--settings", "{\"disableAllHooks\":true}", "--strict-mcp-config",
                            "--no-session-persistence", "--output-format", "json", "/usage"],
                home: homeDirectory, timeout: claudeRenewTimeout, maxBytes: maxProcessOutputBytes)
        }
    }

    static func makeAntigravityRunner(homeDirectory: URL) -> @Sendable () async throws -> Data {
        let candidates = [
            homeDirectory.appendingPathComponent(".local/bin/antigravity-usage").path,
            "/opt/homebrew/bin/antigravity-usage",
            "/usr/local/bin/antigravity-usage",
        ]
        return {
            guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw LocalReaderError.unavailable }
            return try await BoundedQuotaProcess().run(
                path: path, arguments: ["quota", "--json", "--refresh"], home: homeDirectory,
                timeout: processTimeout, maxBytes: maxProcessOutputBytes)
        }
    }
}

private final class RedirectRefusingURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Limits how often CodeCaps asks Claude Code to renew its own login, and
/// makes overlapping refreshes share one run instead of spawning two.  The
/// default instance is process-wide; tests pass their own.
public final class ClaudeRenewalThrottle: @unchecked Sendable {
    public static let shared = ClaudeRenewalThrottle()

    public let minimumInterval: TimeInterval
    private let lock = NSLock()
    private var lastAttempt: Date?
    private var inFlight: Task<Void, Never>?

    public init(minimumInterval: TimeInterval = 15 * 60) {
        self.minimumInterval = minimumInterval
    }

    /// Runs `action` unless an attempt started less than `minimumInterval`
    /// ago.  A caller that arrives while an attempt is running waits for it.
    /// Returns whether a renewal ran (or was joined), so the caller knows a
    /// re-read can be worthwhile.  Failed attempts count toward the interval.
    func perform(now: Date, action: @escaping @Sendable () async -> Void) async -> Bool {
        let task: Task<Void, Never>
        var isOwner = false
        lock.lock()
        if let running = inFlight {
            task = running
        } else {
            if let last = lastAttempt {
                let elapsed = now.timeIntervalSince(last)
                if elapsed >= 0, elapsed < minimumInterval {
                    lock.unlock()
                    return false
                }
            }
            lastAttempt = now
            let created = Task { await action() }
            inFlight = created
            task = created
            isOwner = true
        }
        lock.unlock()
        await task.value
        if isOwner {
            lock.lock()
            inFlight = nil
            lock.unlock()
        }
        return true
    }
}
