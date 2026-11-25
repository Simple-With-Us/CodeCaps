import Foundation

public enum MiMoTokenPlanRegion: String, Codable, CaseIterable, Sendable {
    case china = "cn", singapore = "sgp", europe = "ams"

    public var title: String {
        switch self {
        case .china: return "China"
        case .singapore: return "Singapore"
        case .europe: return "Europe"
        }
    }

    // Only Xiaomi's documented cluster hosts can receive the key.
    var quotaURL: URL {
        URL(string: "https://token-plan-\(rawValue).xiaomimimo.com/v1/platform/token_plan")!
    }
}

public struct MiMoTokenPlanCredential: Codable, Sendable {
    public let key: String
    public let region: MiMoTokenPlanRegion

    public init(key: String, region: MiMoTokenPlanRegion) {
        self.key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region
    }

    public var isValid: Bool {
        key.hasPrefix("tp-") && (4...512).contains(key.utf8.count)
            && key.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || $0 == 45 || $0 == 95
            }
    }
}

struct MiMoTokenPlanReader: LocalQuotaReading {
    let credential: @Sendable () async -> MiMoTokenPlanCredential?

    func read() async -> LocalQuotaResult {
        let id = "mimo-token-plan"
        guard let credential = await credential(), credential.isValid else {
            return LocalQuotaResult(issues: [id: "Save an individual MiMo Token Plan key in Sources & Fleet."])
        }
        var request = URLRequest(url: credential.region.quotaURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await BoundedHTTPFetch.data(for: request, timeout: 8, maxBytes: 32_768)
            if [401, 403].contains(response.statusCode) {
                return LocalQuotaResult(issues: [id: "MiMo rejected the plan key. Check its selected region and validity."])
            }
            if (200..<300).contains(response.statusCode),
               let window = TokenPlanQuotaParser.mimo(data, now: Date()) {
                return LocalQuotaResult(windows: [window])
            }
        } catch {}
        return LocalQuotaResult(issues: [id: "MiMo did not return a current Token Plan quota."])
    }
}

enum BailianQuotaPlan: Sendable {
    case tokenPlan, codingPlan

    var command: String {
        switch self {
        case .tokenPlan: "token-plan"
        case .codingPlan: "coding-plan"
        }
    }

    var id: String { "alibaba-" + command }
    var title: String {
        switch self {
        case .tokenPlan: "Alibaba Token Plan"
        case .codingPlan: "Alibaba Coding Plan"
        }
    }
}

struct BailianPlanQuotaReader: LocalQuotaReading {
    let plan: BailianQuotaPlan

    func read() async -> LocalQuotaResult {
        let id = plan.id
        let home = FileManager.default.homeDirectoryForCurrentUser
        let paths = [home.appendingPathComponent(".local/bin/bl").path, "/opt/homebrew/bin/bl", "/usr/local/bin/bl"]
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return LocalQuotaResult(issues: [id: "Install the official Bailian CLI and sign in to its console."])
        }
        do {
            let data = try await BoundedQuotaProcess().run(
                path: path, arguments: ["usage", plan.command, "--output", "json"],
                home: home, timeout: 15, maxBytes: 32_768)
            let now = Date()
            let windows = switch plan {
            case .tokenPlan: TokenPlanQuotaParser.alibaba(data, now: now)
            case .codingPlan: TokenPlanQuotaParser.alibabaCoding(data, now: now)
            }
            if !windows.isEmpty { return LocalQuotaResult(windows: windows) }
        } catch {}
        return LocalQuotaResult(issues: [id: "Bailian did not report a current \(plan.title) quota. Check its console login and subscription."])
    }
}

enum TokenPlanQuotaParser {
    private struct MiMoResponse: Decodable {
        let object: String
        let period: Period
        let quota: Quota

        struct Period: Decodable {
            let startAt: String
            let endAt: String
        }

        struct Quota: Decodable {
            let totalCredits: Int64
            let usedCredits: Int64
            let remainingCredits: Int64
        }
    }

    static func mimo(_ data: Data, now: Date) -> QuotaWindow? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let payload = try? decoder.decode(MiMoResponse.self, from: data), payload.object == "token_plan",
              let start = utcDate(payload.period.startAt), let end = utcDate(payload.period.endAt),
              start <= now, now < end else { return nil }
        let q = payload.quota
        guard q.totalCredits > 0, q.usedCredits >= 0, q.remainingCredits >= 0,
              q.remainingCredits == max(0, q.totalCredits - q.usedCredits) else { return nil }
        let remaining = 100 * Double(q.remainingCredits) / Double(q.totalCredits)
        let id = "mimo-token-plan"
        return QuotaWindow(
            id: id + ":cycle", provider: id, providerKey: id, providerLabel: "Xiaomi MiMo Token Plan",
            label: "Billing cycle", remainingPercent: remaining, absoluteRemaining: Double(q.remainingCredits),
            absoluteLimit: Double(q.totalCredits), quotaUnit: "credits", isExhausted: remaining == 0,
            resetAt: iso(end), window: "billing cycle", status: .derived(remainingPercent: remaining),
            occurredAt: iso(now), source: "mimo-token-plan-api", periodStart: iso(start))
    }

    static func alibaba(_ data: Data, now: Date) -> [QuotaWindow] {
        guard let payload = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              payload["hasQuotaData"]?.value != .boolean(false) else { return [] }
        let id = "alibaba-token-plan"
        let patterns = try? NSRegularExpression(pattern: "^per([1-9][0-9]{0,2})(Hour|Day|Week|Month)Percentage$")
        guard let patterns else { return [] }
        return payload.keys.sorted().compactMap { key in
            guard let match = patterns.firstMatch(in: key, range: NSRange(key.startIndex..<key.endIndex, in: key)),
                  let numberRange = Range(match.range(at: 1), in: key),
                  let unitRange = Range(match.range(at: 2), in: key),
                  let used = payload[key]?.number, used.isFinite, (0...1).contains(used) else { return nil }
            let count = String(key[numberRange])
            let unit = String(key[unitRange]).lowercased()
            let suffix = String(key.dropLast("Percentage".count))
            let reset: String?
            if let value = payload[suffix + "ResetTime"] {
                guard let ms = value.number, ms.isFinite, ms > 0, ms < 10_000_000_000_000 else { return nil }
                let date = Date(timeIntervalSince1970: ms / 1000)
                guard date > now else { return nil }
                reset = iso(date)
            } else {
                reset = nil
            }
            let label = count == "1" && unit == "month" ? "Monthly" : "\(count) \(unit)\(count == "1" ? "" : "s")"
            let remaining = 100 * (1 - used)
            return QuotaWindow(
                id: id + ":" + suffix, provider: id, providerKey: id, providerLabel: "Alibaba Token Plan",
                label: label, remainingPercent: remaining, isExhausted: remaining == 0,
                resetAt: reset, window: label.lowercased(), status: .derived(remainingPercent: remaining),
                occurredAt: iso(now), source: "bailian-cli")
        }
    }

    /// Bailian Coding Plan emits nested windows with request counts, unlike the
    /// Token Plan's flat fractional percentages. Missing windows do not become quota.
    static func alibabaCoding(_ data: Data, now: Date) -> [QuotaWindow] {
        guard let payload = try? JSONDecoder().decode([String: CodingPlanWindow].self, from: data) else { return [] }
        let plan = BailianQuotaPlan.codingPlan
        let kinds = [("per5Hour", "5 hours", "5h"), ("perWeek", "Weekly", "weekly"),
                     ("perBillMonth", "Monthly", "monthly")]
        return kinds.compactMap { key, label, period in
            guard let quota = payload[key]?.values,
                  let used = quota["usedQuota"]?.number, used.isFinite, used >= 0,
                  let total = quota["totalQuota"]?.number, total.isFinite, total > 0 else { return nil }
            let reset: String?
            if let raw = quota["resetTime"] {
                guard let ms = raw.number, ms.isFinite, ms > 0, ms < 10_000_000_000_000 else { return nil }
                let date = Date(timeIntervalSince1970: ms / 1_000)
                guard date > now else { return nil }
                reset = iso(date)
            } else {
                reset = nil
            }
            let balance = max(0, total - used)
            let remaining = 100 * (balance / total)
            return QuotaWindow(
                id: plan.id + ":" + key, provider: plan.id, providerKey: plan.id, providerLabel: plan.title,
                label: label, remainingPercent: remaining, absoluteRemaining: balance, absoluteLimit: total,
                quotaUnit: "requests", isExhausted: remaining == 0, resetAt: reset, window: period,
                status: .derived(remainingPercent: remaining), occurredAt: iso(now), source: "bailian-cli")
        }
    }

    private struct CodingPlanWindow: Decodable {
        let values: [String: JSONValue]?

        init(from decoder: Decoder) throws {
            values = try? decoder.singleValueContainer().decode([String: JSONValue].self)
        }
    }

    private struct JSONValue: Decodable {
        enum Value: Equatable { case boolean(Bool), number(Double), other }
        let value: Value

        var number: Double? {
            if case .number(let amount) = value { return amount }
            return nil
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let result = try? container.decode(Bool.self) { value = .boolean(result) }
            else if let result = try? container.decode(Double.self) { value = .number(result) }
            else { value = .other }
        }
    }

    private static func utcDate(_ raw: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.isLenient = false
        guard let date = formatter.date(from: raw), formatter.string(from: date) == raw else { return nil }
        return date
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}
