import Foundation

/// Reads grouped Antigravity quota through the CLI's quota-only command,
/// with the running language server as a fallback for older installations.
public struct AntigravitySummaryReader: Sendable {
    private let now: @Sendable () -> Date
    private let fetchSummary: @Sendable () async throws -> Data

    public init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @escaping @Sendable () -> Date = { Date() },
        fetchSummary: (@Sendable () async throws -> Data)? = nil
    ) {
        let home = homeDirectory.standardizedFileURL
        self.now = now
        self.fetchSummary = fetchSummary ?? Self.makeLocalFetcher(homeDirectory: home)
    }

    public func read() async -> LocalQuotaResult {
        do {
            let data = try await fetchSummary()
            guard data.count <= 1_048_576 else { throw SummaryError.tooLarge }
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SummaryError.malformed }
            let response = Self.summaryResponse(root)
            let groups = (response["groups"] as? [[String: Any]]) ?? []
            let observed = now()
            var windows: [QuotaWindow] = []
            for group in groups {
                guard let displayName = ["displayName", "name", "id"]
                    .compactMap({ group[$0] as? String })
                    .first(where: { name in
                        ["argon", "gemini", "claude", "gpt", "third"].contains {
                            name.localizedCaseInsensitiveContains($0)
                        }
                    }) else { continue }
                let family: String?
                let modelId: String?
                if displayName.localizedCaseInsensitiveContains("argon") {
                    family = "Gemini Models"
                    modelId = "argon"
                } else if displayName.localizedCaseInsensitiveContains("gemini") {
                    family = "Gemini Models"
                    modelId = nil
                } else if displayName.localizedCaseInsensitiveContains("claude") || displayName.localizedCaseInsensitiveContains("gpt") || displayName.localizedCaseInsensitiveContains("third") {
                    family = "Third-Party Models"
                    modelId = nil
                } else {
                    family = nil
                    modelId = nil
                }
                guard let family else { continue }
                for bucket in (group["buckets"] as? [[String: Any]]) ?? [] {
                    guard let bucketID = summaryString(bucket, keys: ["bucketId", "id"]), let period = period(bucket) else { continue }
                    // A fraction this reader cannot interpret is not a fraction
                    // it may offer as remaining quota, so a value outside
                    // 0...1 is refused the same way an omitted value is:  no
                    // remaining, exhausted.  The provider's payload is a 0...1
                    // fraction, so a number outside that range means the shape
                    // changed and nothing in it can be believed.
                    let fraction = (finiteNumber(bucket["remainingFraction"]) ?? finiteNumber(bucket["remaining_fraction"]))
                        .flatMap { $0 >= 0 && $0 <= 1 ? $0 : nil }
                    let reset = summaryString(bucket, keys: ["resetTime", "reset_time"])
                    let cadenceName = period == "5h" ? QuotaWindowVocabulary.fiveHour : QuotaWindowVocabulary.sevenDay
                    let label = modelId == "argon"
                        ? "Gemini 4 Argon · \(cadenceName)"
                        : "\(family) · \(cadenceName)"
                    // A bucket that reports no fraction means none remains —
                    // it does not mean the reading is unknown.  Owner 2026-09-04:
                    // an omitted remaining value (N/A in the provider's table)
                    // means the allowance is spent, so "treat as exhausted 0%,
                    // not 'unknown' and not 100%".  The rest of the fleet says
                    // the same thing: the Usage Monitor collector turns a
                    // missing fraction into `isExhausted` with 0% remaining,
                    // and BotFleet's `isAntigravityModelCapped` counts a
                    // missing percentage as capped while `remainingPercentDisplay`
                    // shows 0% for it.
                    //
                    // Reading it as unknown here is what let the Mac offer quota
                    // that was not there.  An unknown weekly window drops out of
                    // its pool's count, so the five-hour window drove the pool's
                    // headline instead, and the row showed a number the owner
                    // could not act on while the pool was at its cap.
                    windows.append(QuotaWindow(
                        id: "local-mac:antigravity-summary:\(bucketID)",
                        provider: "Antigravity",
                        providerKey: "google-antigravity",
                        providerLabel: "Antigravity",
                        via: "antigravity",
                        sourceApp: "local-mac",
                        modelId: modelId,
                        modelType: modelId,
                        label: label,
                        remainingPercent: fraction.map { $0 * 100 } ?? 0,
                        remainingUnknown: false,
                        isExhausted: fraction == nil,
                        resetAt: reset,
                        window: period,
                        occurredAt: iso8601(observed),
                        source: "Antigravity quota summary"
                    ))
                }
            }
            guard !windows.isEmpty else { throw SummaryError.malformed }
            return LocalQuotaResult(windows: windows)
        } catch is CancellationError { return LocalQuotaResult(issues: ["google-antigravity": "Antigravity quota refresh was cancelled."]) }
        catch SummaryError.tooLarge { return LocalQuotaResult(issues: ["google-antigravity": "Antigravity quota response is too large."]) }
        catch { return LocalQuotaResult(issues: ["google-antigravity": "Antigravity grouped quota is unavailable."]) }
    }

    private func period(_ bucket: [String: Any]) -> String? {
        let value = (bucket["window"] as? String)?.lowercased()
        if value == "5h" || value == "weekly" { return value }
        let id = summaryString(bucket, keys: ["bucketId", "id"])?.lowercased() ?? ""
        if id.hasSuffix("-5h") { return "5h" }
        if id.hasSuffix("-weekly") { return "weekly" }
        return nil
    }

    /// Print-mode slash commands return their structured payload under
    /// command.data; the language-server RPC returns it under response.
    private static func summaryResponse(_ root: [String: Any]) -> [String: Any] {
        if let command = root["command"] as? [String: Any] {
            if let status = root["status"] as? String,
               !["success", "ok"].contains(status.lowercased()) { return [:] }
            if let data = command["data"] as? [String: Any] { return data }
        }
        return (root["response"] as? [String: Any]) ?? root
    }

    private static func cliPath(homeDirectory: URL) -> String? {
        [homeDirectory.appendingPathComponent(".local/bin/agy").path,
         "/opt/homebrew/bin/agy", "/usr/local/bin/agy"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func makeLocalFetcher(homeDirectory: URL) -> @Sendable () async throws -> Data {
        {
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            func budget(_ maximum: TimeInterval) throws -> TimeInterval {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw SummaryError.unavailable }
                return min(maximum, remaining)
            }
            // /usage is handled by the CLI itself: it neither runs an agent
            // turn nor spends model quota, and uses the CLI's own sign-in.
            // Do not require the interactive CLI or IDE to be running.
            if let path = cliPath(homeDirectory: homeDirectory) {
                do {
                    let data = try await BoundedQuotaProcess().run(
                        path: path, arguments: ["-p", "/usage", "--output-format", "json"],
                        home: homeDirectory, timeout: try budget(15), maxBytes: 1_048_576)
                    if let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                       let groups = summaryResponse(root)["groups"] as? [[String: Any]], !groups.isEmpty {
                        return data
                    }
                } catch is CancellationError { throw CancellationError() }
                catch { /* An older CLI may not support structured /usage. */ }
            }
            let pids = try await BoundedQuotaProcess().run(
                path: "/usr/bin/pgrep", arguments: ["-f", "language_server|language-server|/agy( |$)"],
                home: homeDirectory, timeout: try budget(2), maxBytes: 16_384)
            var candidates = 0
            for line in String(decoding: pids, as: UTF8.self).split(whereSeparator: \.isNewline).reversed() {
                try Task.checkCancellation()
                guard candidates < 4, ProcessInfo.processInfo.systemUptime < deadline else { break }
                guard let pid = Int32(line.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
                      let commandData = try? await BoundedQuotaProcess().run(
                        path: "/bin/ps", arguments: ["-p", "\(pid)", "-o", "command="],
                        home: homeDirectory, timeout: try budget(2), maxBytes: 65_536) else { continue }
                let command = String(decoding: commandData, as: UTF8.self)
                let identity = command.lowercased()
                let cli = identity.contains("/antigravity-cli/") || identity.contains("/antigravity_cli/")
                    || identity.split(whereSeparator: \.isWhitespace).first?.hasSuffix("/agy") == true
                guard cli || identity.contains("/antigravity/") || identity.contains("antigravity.app/")
                    || identity.contains("antigravity ide.app/") || identity.contains("--app_data_dir antigravity") else { continue }
                let csrf = argument(command, names: ["--csrf_token", "--csrf-token"]) ?? ""
                guard (cli && csrf.isEmpty) || validHeader(csrf) else { continue }
                candidates += 1
                var ports: [Int] = []
                if let lsof = try? await BoundedQuotaProcess().run(
                    path: "/usr/sbin/lsof", arguments: ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", "\(pid)", "-Fn"],
                    home: homeDirectory, timeout: try budget(2), maxBytes: 16_384) {
                    ports = lsofPorts(String(decoding: lsof, as: UTF8.self))
                }
                for name in ["--https_server_port", "--extension_server_port"] {
                    if let port = argument(command, names: [name]).flatMap(Int.init), !ports.contains(port) { ports.append(port) }
                }
                for port in ports.filter({ (1...65535).contains($0) }).prefix(4) {
                    for scheme in ["https", "http"] {
                        try Task.checkCancellation()
                        guard ProcessInfo.processInfo.systemUptime < deadline else { throw SummaryError.unavailable }
                        let url = URL(string: "\(scheme)://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary")!
                        var request = URLRequest(url: url)
                        request.httpMethod = "POST"
                        request.httpBody = Data("{}".utf8)
                        request.timeoutInterval = try budget(3)
                        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                        request.setValue("application/json", forHTTPHeaderField: "Accept")
                        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
                        if !csrf.isEmpty { request.setValue(csrf, forHTTPHeaderField: "X-Codeium-Csrf-Token") }
                        do {
                            let data = try await Self.fetch(request)
                            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                            let response = summaryResponse(root)
                            if let groups = response["groups"] as? [[String: Any]], !groups.isEmpty { return data }
                        } catch is CancellationError { throw CancellationError() }
                        catch { continue }
                    }
                }
            }
            throw SummaryError.unavailable
        }
    }

    private static func fetch(_ request: URLRequest) async throws -> Data {
        do {
            let (data, response) = try await BoundedHTTPFetch.data(for: request, timeout: request.timeoutInterval, maxBytes: 1_048_576, delegate: LocalTLSDelegate())
            guard (200..<300).contains(response.statusCode) else { throw SummaryError.unavailable }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as BoundedHTTPFetch.Failure where failure == .tooLarge {
            throw SummaryError.tooLarge
        } catch {
            throw SummaryError.unavailable
        }
    }

    private enum SummaryError: Error { case unavailable, tooLarge, malformed }
}

private func summaryString(_ record: [String: Any], keys: [String]) -> String? {
    keys.compactMap { record[$0] as? String }
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
}

private func finiteNumber(_ value: Any?) -> Double? {
    if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite { return number.doubleValue }
    if let string = value as? String, let number = Double(string), number.isFinite { return number }
    return nil
}

private func iso8601(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
private func validHeader(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 4096 && !value.contains("\r") && !value.contains("\n") }
private func argument(_ command: String, names: [String]) -> String? {
    let tokens = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    for (index, item) in tokens.enumerated() {
        for name in names where item.hasPrefix(name + "=") { return String(item.dropFirst(name.count + 1)) }
        if names.contains(item), index + 1 < tokens.count { return tokens[index + 1] }
    }
    return nil
}
private func lsofPorts(_ output: String) -> [Int] {
    output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).compactMap { line in
        guard line.hasPrefix("n"), let value = line.split(separator: ":").last else { return nil }
        let port = value.prefix(while: { $0.isNumber })
        return Int(port)
    }
}

private final class LocalTLSDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.host == "127.0.0.1", challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust { completionHandler(.useCredential, URLCredential(trust: trust)) } else { completionHandler(.performDefaultHandling, nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
