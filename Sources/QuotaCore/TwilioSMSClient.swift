import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Personal opt-ins are independent of local notification delivery.
public struct SMSAlertPreferences: Codable, Equatable, Sendable {
    public static let eligibleKinds: Set<String> = [
        "museCodeStandardSession", "museCodeBurn", "quotaExhaustion"
    ]
    public var enabledKinds: Set<String>

    public init(enabledKinds: Set<String> = []) {
        self.enabledKinds = enabledKinds.intersection(Self.eligibleKinds)
    }

    public subscript(kindID: String) -> Bool {
        get { Self.eligibleKinds.contains(kindID) && enabledKinds.contains(kindID) }
        set {
            if newValue && Self.eligibleKinds.contains(kindID) { enabledKinds.insert(kindID) }
            else { enabledKinds.remove(kindID) }
        }
    }

    public static func load(from defaults: UserDefaults, key: String) -> Self {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return Self(enabledKinds: saved.enabledKinds)
    }

    public func save(to defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: key)
    }
}

public struct TwilioSMSConfiguration: Codable, Equatable, Sendable {
    public var accountSID: String
    public var apiKeySID: String
    public var messagingServiceSID: String
    public var recipient: String

    public init(accountSID: String, apiKeySID: String, messagingServiceSID: String, recipient: String) {
        self.accountSID = accountSID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKeySID = apiKeySID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.messagingServiceSID = messagingServiceSID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.recipient = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func validate() throws {
        guard Self.isSID(accountSID, prefix: "AC"), Self.isSID(apiKeySID, prefix: "SK"),
              Self.isSID(messagingServiceSID, prefix: "MG"),
              recipient.range(of: #"\A\+[1-9][0-9]{1,14}\z"#, options: .regularExpression) != nil else {
            throw TwilioSMSFailure.invalidConfiguration
        }
    }

    private static func isSID(_ value: String, prefix: String) -> Bool {
        value.count == 34 && value.hasPrefix(prefix)
            && value.dropFirst(2).allSatisfy { "0123456789abcdefABCDEF".contains($0) }
    }
}

/// The whole per-user setup belongs in one build-scoped Keychain item.
public struct TwilioSMSCredentials: Codable, Equatable, Sendable {
    public var configuration: TwilioSMSConfiguration
    public var apiKeySecret: String

    public init(configuration: TwilioSMSConfiguration, apiKeySecret: String) {
        self.configuration = configuration
        self.apiKeySecret = apiKeySecret.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func validate() throws {
        try configuration.validate()
        guard !apiKeySecret.isEmpty, apiKeySecret.utf8.count <= 256,
              !apiKeySecret.contains(where: { $0.isWhitespace || $0.isNewline || $0 == ":" }) else {
            throw TwilioSMSFailure.invalidConfiguration
        }
    }
}

/// Errors never include Twilio response text, credentials, or the recipient.
public enum TwilioSMSFailure: Error, LocalizedError, Equatable, Sendable {
    case invalidConfiguration, authentication, rejected, rateLimited, serviceUnavailable
    case uncertain, invalidResponse, persistence, capacity

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration: return "Enter a valid Twilio SMS setup."
        case .authentication: return "Twilio rejected the saved API credentials."
        case .rejected: return "Twilio rejected this text message."
        case .rateLimited: return "Twilio is limiting text messages."
        case .serviceUnavailable: return "Twilio is temporarily unavailable."
        case .uncertain: return "Text submission could not be confirmed.\u{00A0} This alert will not be retried."
        case .invalidResponse: return "Twilio returned an unexpected response.\u{00A0} This alert will not be retried."
        case .persistence: return "Text alerts could not save their send history."
        case .capacity: return "Text alert send history is full."
        }
    }
}

public struct TwilioSMSClient: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport

    public init(transport: @escaping Transport = TwilioSMSClient.liveTransport) {
        self.transport = transport
    }

    /// Acceptance means Twilio created the message, never confirmed delivery.
    public func send(title: String, body: String, credentials: TwilioSMSCredentials) async throws {
        let request = try Self.request(title: title, body: body, credentials: credentials)
        let data: Data
        let response: HTTPURLResponse
        do { (data, response) = try await transport(request) }
        catch { throw TwilioSMSFailure.uncertain }
        switch response.statusCode {
        case 200..<300: break
        case 401, 403: throw TwilioSMSFailure.authentication
        case 429: throw TwilioSMSFailure.rateLimited
        case 500...599: throw TwilioSMSFailure.serviceUnavailable
        default: throw TwilioSMSFailure.rejected
        }
        struct Receipt: Decodable { let sid: String; let status: String }
        guard data.count <= 65_536,
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data),
              receipt.sid.count == 34, receipt.sid.hasPrefix("SM"),
              receipt.sid.dropFirst(2).allSatisfy({ "0123456789abcdefABCDEF".contains($0) }) else {
            throw TwilioSMSFailure.invalidResponse
        }
        guard ["accepted", "queued", "scheduled", "sending", "sent", "delivered"].contains(receipt.status) else {
            throw TwilioSMSFailure.rejected
        }
    }

    static func request(title: String, body: String, credentials: TwilioSMSCredentials) throws -> URLRequest {
        try credentials.validate()
        let config = credentials.configuration
        // The fixed host and SID validation prevent credential-bearing arbitrary endpoints.
        let url = URL(string: "https://api.twilio.com/2010-04-01/Accounts/\(config.accountSID)/Messages.json")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let authorization = Data("\(config.apiKeySID):\(credentials.apiKeySecret)".utf8).base64EncodedString()
        request.setValue("Basic " + authorization, forHTTPHeaderField: "Authorization")
        let message = String(("CodeCaps: " + title + "\n" + body).prefix(240))
        request.httpBody = Data([("To", config.recipient), ("MessagingServiceSid", config.messagingServiceSID), ("Body", message)]
            .map { Self.formEncode($0.0) + "=" + Self.formEncode($0.1) }.joined(separator: "&").utf8)
        return request
    }

    private static func formEncode(_ value: String) -> String {
        let hex = Array("0123456789ABCDEF".utf8)
        var encoded: [UInt8] = []
        encoded.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case 48...57, 65...90, 97...122, 45, 46, 95, 126:
                encoded.append(byte)
            default:
                encoded.append(37)
                encoded.append(hex[Int(byte >> 4)])
                encoded.append(hex[Int(byte & 0x0F)])
            }
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    public static let liveTransport: Transport = { request in
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: NoSMSRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TwilioSMSFailure.invalidResponse }
        return (data, response)
    }
}

/// A redirect must never forward the Basic authorization header to another host.
final class NoSMSRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
