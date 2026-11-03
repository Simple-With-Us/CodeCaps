import Foundation
import CryptoKit

public enum SMSAlertSendResult: Equatable, Sendable {
    case disabled, duplicate, accepted
    case failed(TwilioSMSFailure)
}

/// Callers supply persistence explicitly; tests never touch standard preferences.
public struct SMSAlertPersistence: Sendable {
    public var load: @Sendable () throws -> Data?
    public var save: @Sendable (Data) throws -> Void

    public init(load: @escaping @Sendable () throws -> Data?, save: @escaping @Sendable (Data) throws -> Void) {
        self.load = load
        self.save = save
    }

    public static func userDefaults(_ defaults: UserDefaults, key: String) -> Self {
        Self(load: { defaults.data(forKey: key) }, save: { data in
            defaults.set(data, forKey: key)
            guard defaults.synchronize() else { throw TwilioSMSFailure.persistence }
        })
    }
}

/// Single-flight reservations survive relaunch and remain after uncertain outcomes.
public actor SMSAlertCoordinator {
    private struct History: Codable {
        let version: Int
        var eventHashes: Set<String>
    }
    private let persistence: SMSAlertPersistence
    private let client: TwilioSMSClient
    private let maximumReservations: Int
    private var history: History?

    /// A full ledger fails closed instead of evicting IDs and risking repeat charges.
    public init(persistence: SMSAlertPersistence, client: TwilioSMSClient = TwilioSMSClient(),
                maximumReservations: Int = 16_384) {
        self.persistence = persistence
        self.client = client
        self.maximumReservations = min(16_384, max(1, maximumReservations))
    }

    public func send(eventID: String, kind: String, title: String, body: String,
                     preferences: SMSAlertPreferences, credentials: TwilioSMSCredentials?) async -> SMSAlertSendResult {
        guard preferences[kind] else { return .disabled }
        guard let credentials else { return .failed(.invalidConfiguration) }
        do { try credentials.validate() }
        catch { return .failed(.invalidConfiguration) }
        guard !eventID.isEmpty, eventID.utf8.count <= 4_096 else { return .failed(.persistence) }
        let eventHash = SHA256.hash(data: Data((kind + "\u{0}" + eventID).utf8))
            .map { String(format: "%02x", $0) }.joined()
        do {
            if history == nil {
                if let data = try persistence.load() {
                    guard data.count <= maximumReservations * 80 + 128 else { return .failed(.persistence) }
                    let loaded = try JSONDecoder().decode(History.self, from: data)
                    guard loaded.version == 1, loaded.eventHashes.count <= maximumReservations,
                          loaded.eventHashes.allSatisfy({ $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) } }) else {
                        return .failed(.persistence)
                    }
                    history = loaded
                } else { history = History(version: 1, eventHashes: []) }
            }
            guard var updated = history else { return .failed(.persistence) }
            guard !updated.eventHashes.contains(eventHash) else { return .duplicate }
            guard updated.eventHashes.count < maximumReservations else { return .failed(.capacity) }
            updated.eventHashes.insert(eventHash)
            // No actor suspension occurs until the reservation is durably saved.
            try persistence.save(JSONEncoder().encode(updated))
            history = updated
        } catch { return .failed(.persistence) }
        do {
            try await client.send(title: title, body: body, credentials: credentials)
            return .accepted
        } catch let failure as TwilioSMSFailure { return .failed(failure) }
        catch { return .failed(.uncertain) }
    }
}
