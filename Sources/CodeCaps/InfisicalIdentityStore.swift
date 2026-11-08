import Foundation
import Security
import QuotaCore

/// The app's own versioned Infisical binding record, scoped per build.
/// Machine identities and full service tokens never use preferences or logs.
/// Injected calls keep tests away from the real Keychain.
enum InfisicalIdentityStore {
    struct Identity: Codable, Equatable, Sendable {
        var clientId: String
        var clientSecret: String
        var projectId: String

        var configuration: InfisicalSettings.Configuration {
            InfisicalSettings.Configuration(projectId: projectId,
                                            environment: InfisicalSettings.defaultEnvironment(),
                                            clientId: clientId, clientSecret: clientSecret)
        }
    }

    /// One Keychain item holds the entire explicitly entered setup.
    private struct Record: Codable {
        var version = 1
        var identity: Identity?
        var setup: InfisicalSetup?
    }

    /// Test seam: the live implementation shells out to the Security
    /// framework; tests replace the whole struct with an in-memory fake.
    /// The closures are plain (non-`@Sendable`) function types on purpose, so
    /// test fakes can capture their fixtures without Sendable checking noise.
    struct KeychainCalls {
        var read: (_ service: String, _ account: String) throws -> String?
        var save: (_ service: String, _ account: String, _ value: String) throws -> Void
        var delete: (_ service: String, _ account: String) throws -> Void

        static let live = KeychainCalls(
            read: { try SecItem.read(service: $0, account: $1) },
            save: { try SecItem.save(service: $0, account: $1, value: $2) },
            delete: { try SecItem.delete(service: $0, account: $1) }
        )
    }

    static var calls = KeychainCalls.live

    enum StoreError: Error, LocalizedError {
        case keychain(status: OSStatus)
        case invalidRecord

        var errorDescription: String? {
            switch self {
            case .invalidRecord:
                return "The saved Infisical setup could not be read or encoded."
            case .keychain(let status):
                return "The Keychain refused the Infisical identity (OSStatus \(status))."
            }
        }
    }

    /// This build's Keychain service, derived from its bundle identifier the
    /// same way `TokenStore` scopes its own items: a `.dev` build keeps its
    /// own identity and can never overwrite or forget the owner's.
    static func serviceName(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> String {
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let base = trimmed.isEmpty ? TokenStore.defaultBundleIdentifier : trimmed
        return base + ".infisical-identity"
    }

    private static let setupAccount = "setup-v1"

    /// V1 identities become read-only bindings in memory; no startup write migrates credentials.
    static func loadSetup(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> InfisicalSetup? {
        let raw: String?
        do { raw = try calls.read(serviceName(bundleIdentifier: bundleIdentifier), setupAccount) }
        catch { return nil }
        guard let raw, raw.utf8.count <= 1_048_576, let data = raw.data(using: .utf8),
              let record = try? JSONDecoder().decode(Record.self, from: data) else { return nil }
        let setup: InfisicalSetup
        if record.version == 1, let identity = record.identity {
            let read = identity.configuration.readBinding
            setup = InfisicalSetup(bindings: [read], readBindingID: read.id)
        } else if record.version == 2, let saved = record.setup { setup = saved }
        else { return nil }
        guard (try? setup.validate()) != nil else { return nil }
        return setup
    }

    static func saveSetup(_ setup: InfisicalSetup,
                          bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws {
        try setup.validate()
        try write(Record(version: 2, identity: nil, setup: setup), service: serviceName(bundleIdentifier: bundleIdentifier))
    }

    /// Compatibility for callers inspecting the selected machine-auth read identity.
    static func load(bundleIdentifier: String? = Bundle.main.bundleIdentifier) -> Identity? {
        guard let binding = loadSetup(bundleIdentifier: bundleIdentifier)?.configuration?.readBinding,
              binding.authentication == .machineIdentity else { return nil }
        return Identity(clientId: binding.clientId, clientSecret: binding.clientSecret, projectId: binding.projectId)
    }

    static func save(_ identity: Identity, bundleIdentifier: String? = Bundle.main.bundleIdentifier) throws {
        let read = identity.configuration.readBinding
        try saveSetup(InfisicalSetup(bindings: [read], readBindingID: read.id), bundleIdentifier: bundleIdentifier)
    }

    static func delete(
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) throws {
        let service = serviceName(bundleIdentifier: bundleIdentifier)
        try calls.delete(service, setupAccount)
    }

    private static func write(_ record: Record, service: String) throws {
        let data = try JSONEncoder().encode(record)
        guard let raw = String(data: data, encoding: .utf8) else { throw StoreError.invalidRecord }
        try calls.save(service, setupAccount, raw)
    }
}

extension Notification.Name {
    /// Posted (on the main thread) after the owner saves or forgets the
    /// Infisical client identity, so the app delegate can (re)start the
    /// background refresh cycle without a relaunch.
    static let infisicalIdentityChanged = Notification.Name("CodeCapsInfisicalIdentityChanged")
}

// MARK: - Security framework calls

private enum SecItem {
    static func read(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw InfisicalIdentityStore.StoreError.keychain(status: status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw InfisicalIdentityStore.StoreError.invalidRecord
        }
        return value
    }

    static func save(service: String, account: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw InfisicalIdentityStore.StoreError.keychain(status: errSecParam)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        } else if status == errSecItemNotFound {
            var attributes = query
            attributes[kSecValueData as String] = data
            // This Mac only: the identity never leaves the Keychain.
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else {
            throw InfisicalIdentityStore.StoreError.keychain(status: status)
        }
    }

    static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw InfisicalIdentityStore.StoreError.keychain(status: status)
        }
    }
}
