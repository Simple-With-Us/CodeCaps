import Foundation
import QuotaCore

/// One narrowly scoped cache reuses the existing bounded, prompt-free Keychain path.
actor TwilioCredentialStore {
    static let shared = TwilioCredentialStore()
    private let service: String
    private let cache: TokenCache
    private let account = "sms-setup-v1"

    init(calls: KeychainCalls = .live, bundleIdentifier: String? = Bundle.main.bundleIdentifier,
         bounds: TokenCache.Bounds = .init()) {
        let service = Self.serviceName(bundleIdentifier: bundleIdentifier)
        self.service = service
        self.cache = TokenCache(calls: calls, bounds: bounds, ownServices: [service], log: { _ in })
    }

    nonisolated static func serviceName(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        TokenStore.serviceName(suffix: "twilio-sms", bundleIdentifier: bundleIdentifier)
    }

    func load() async -> TwilioSMSCredentials? {
        decode(await cache.token(server: account, service: service))
    }

    /// Only an explicit settings action may allow a Keychain authorization panel.
    func readAllowingInteraction() async -> TwilioSMSCredentials? {
        decode(await cache.readAllowingInteraction(server: account, service: service))
    }

    func save(_ credentials: TwilioSMSCredentials) async throws {
        try credentials.validate()
        guard let encoded = try? JSONEncoder().encode(credentials),
              let raw = String(data: encoded, encoding: .utf8) else { throw StoreFailure.invalidRecord }
        do { try await cache.save(raw, server: account, service: service) }
        catch { throw StoreFailure.keychain }
    }

    func clear() async throws {
        do { try await cache.delete(server: account, service: service) }
        catch { throw StoreFailure.keychain }
    }

    private func decode(_ raw: String?) -> TwilioSMSCredentials? {
        guard let raw, let data = raw.data(using: .utf8),
              let credentials = try? JSONDecoder().decode(TwilioSMSCredentials.self, from: data),
              (try? credentials.validate()) != nil else { return nil }
        return credentials
    }

    enum StoreFailure: Error, LocalizedError {
        case invalidRecord, keychain
        var errorDescription: String? {
            switch self {
            case .invalidRecord: return "The Twilio setup could not be encoded."
            case .keychain: return "Keychain could not update the saved Twilio setup."
            }
        }
    }
}
