import Foundation
import Security

/// The companion and its iOS widget use one App Group Keychain item.  The
/// transport seam lets tests exercise migration without touching Keychain.
struct CompanionReadTokenStore {
    static let legacyKey = "companionSyncToken"
    static let service = "com.simplewithus.codecaps.companion.read-token"
    static let account = "sync"

    enum ReadState: Equatable {
        case token(String)
        case legacy(String, OSStatus)
        case missing
        case unavailable(OSStatus)

        var token: String? {
            switch self {
            case .token(let value), .legacy(let value, _): return value
            case .missing, .unavailable: return nil
            }
        }
    }

    struct Calls {
        var read: (String) -> (OSStatus, Data?)
        var write: (String, Data) -> OSStatus
        var remove: (String) -> OSStatus

        static let live = Calls(
            read: { group in
                var query = CompanionReadTokenStore.query(group: group)
                query[kSecReturnData as String] = true
                query[kSecMatchLimit as String] = kSecMatchLimitOne
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return (status, result as? Data)
            },
            write: { group, data in
                let query = CompanionReadTokenStore.query(group: group)
                let attributes: [String: Any] = [
                    kSecValueData as String: data,
                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
                ]
                let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                if update != errSecItemNotFound { return update }
                var added = query
                attributes.forEach { added[$0.key] = $0.value }
                let add = SecItemAdd(added as CFDictionary, nil)
                // Another process may have inserted the item between update and add.
                return add == errSecDuplicateItem
                    ? SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
                    : add
            },
            remove: { group in
                SecItemDelete(CompanionReadTokenStore.query(group: group) as CFDictionary)
            }
        )
    }

    let accessGroup: String
    var calls: Calls = .live

    /// Reads Keychain first.  Legacy preferences remain usable if migration
    /// cannot finish; no preference value is removed on a failed write.
    func loadAndMigrate(shared: UserDefaults, standard: UserDefaults) -> ReadState {
        switch readKeychain() {
        case .token(let token):
            clearLegacy(shared: shared, standard: standard)
            return .token(token)
        case .missing:
            guard let legacy = legacyToken(shared: shared, standard: standard) else { return .missing }
            let status = save(legacy, shared: shared, standard: standard)
            return status == errSecSuccess ? .token(legacy) : .legacy(legacy, status)
        case .unavailable(let status):
            guard let legacy = legacyToken(shared: shared, standard: standard) else {
                return .unavailable(status)
            }
            return .legacy(legacy, status)
        case .legacy:
            // readKeychain never returns a legacy value.
            return .missing
        }
    }

    /// The widget never migrates a credential itself.  An older install can
    /// still pull with its shared preference until the companion migrates it.
    func readForWidget(shared: UserDefaults) -> ReadState {
        let state = readKeychain()
        if case .token = state { return state }
        if let legacy = shared.string(forKey: Self.legacyKey), !legacy.isEmpty {
            switch state {
            case .missing: return .legacy(legacy, errSecItemNotFound)
            case .unavailable(let status): return .legacy(legacy, status)
            case .token, .legacy: break
            }
        }
        return state
    }

    @discardableResult
    func save(_ token: String, shared: UserDefaults, standard: UserDefaults) -> OSStatus {
        let status: OSStatus
        if token.isEmpty {
            let removed = calls.remove(accessGroup)
            status = removed == errSecItemNotFound ? errSecSuccess : removed
        } else {
            status = calls.write(accessGroup, Data(token.utf8))
        }
        if status == errSecSuccess { clearLegacy(shared: shared, standard: standard) }
        return status
    }

    private func readKeychain() -> ReadState {
        let (status, data) = calls.read(accessGroup)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess else { return .unavailable(status) }
        guard let data, let token = String(data: data, encoding: .utf8), !token.isEmpty else {
            return .unavailable(errSecDecode)
        }
        return .token(token)
    }

    private func legacyToken(shared: UserDefaults, standard: UserDefaults) -> String? {
        [shared, standard].compactMap { $0.string(forKey: Self.legacyKey) }
            .first { !$0.isEmpty }
    }

    private func clearLegacy(shared: UserDefaults, standard: UserDefaults) {
        shared.removeObject(forKey: Self.legacyKey)
        standard.removeObject(forKey: Self.legacyKey)
    }

    private static func query(group: String) -> [String: Any] {
        var value: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: group
        ]
        #if os(macOS)
        // macOS uses App Group Keychain sharing only in its data-protection Keychain.
        value[kSecUseDataProtectionKeychain as String] = true
        #endif
        return value
    }
}
