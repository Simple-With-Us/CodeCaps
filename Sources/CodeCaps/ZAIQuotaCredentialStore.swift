import Foundation
import QuotaCore

/// Region and key share one build-scoped record, separate from all provider logins.
actor ZAIQuotaCredentialStore {
    static let shared = ZAIQuotaCredentialStore()
    private let service: String
    private let account = "quota-api-key-v1"
    private let cache: TokenCache

    init(calls: KeychainCalls = .live, bundleIdentifier: String? = Bundle.main.bundleIdentifier,
         bounds: TokenCache.Bounds = .init()) {
        let service = Self.serviceName(bundleIdentifier: bundleIdentifier)
        self.service = service
        cache = TokenCache(calls: calls, bounds: bounds, ownServices: [service], log: { _ in })
    }

    nonisolated static func serviceName(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> String {
        TokenStore.serviceName(suffix: "zai-quota-api-key", bundleIdentifier: bundleIdentifier)
    }

    func load() async -> ZCodeQuotaCredential? {
        decode(await cache.token(server: account, service: service))
    }

    func readAllowingInteraction() async -> ZCodeQuotaCredential? {
        decode(await cache.readAllowingInteraction(server: account, service: service))
    }

    func save(_ credential: ZCodeQuotaCredential) async throws {
        guard credential.isValid, let data = try? JSONEncoder().encode(credential),
              let raw = String(data: data, encoding: .utf8) else { throw Failure.invalid }
        do { try await cache.save(raw, server: account, service: service) }
        catch { throw Failure.keychain }
    }

    func clear() async throws {
        do { try await cache.delete(server: account, service: service) }
        catch { throw Failure.keychain }
    }

    private func decode(_ raw: String?) -> ZCodeQuotaCredential? {
        guard let raw, let data = raw.data(using: .utf8),
              let credential = try? JSONDecoder().decode(ZCodeQuotaCredential.self, from: data),
              credential.isValid else { return nil }
        return credential
    }

    enum Failure: Error { case invalid, keychain }
}
