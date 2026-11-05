import Combine
import Foundation
import QuotaCore

/// The injected boundary keeps controller tests off the real Keychain.
@MainActor
struct SMSCredentialAccess {
    var load: () async -> TwilioSMSCredentials?
    var save: (TwilioSMSCredentials) async throws -> Void
    var clear: () async throws -> Void
    var reauthorize: () async -> TwilioSMSCredentials?

    static let live = Self(load: { await TwilioCredentialStore.shared.load() },
                           save: { try await TwilioCredentialStore.shared.save($0) },
                           clear: { try await TwilioCredentialStore.shared.clear() },
                           reauthorize: { await TwilioCredentialStore.shared.readAllowingInteraction() })
}

@MainActor
final class SMSAlertController: ObservableObject {
    enum Keys {
        static let preferences = "smsAlertPreferences"
        static let configuration = "twilioSMSConfiguration"
        static let hasSetup = "twilioSMSHasSetup"
        static let history = "smsAlertSendHistory"
    }

    @Published var preferences: SMSAlertPreferences {
        didSet { preferences.save(to: defaults, key: Keys.preferences) }
    }
    @Published private(set) var configuration: TwilioSMSConfiguration?
    @Published private(set) var hasSavedSetup: Bool
    @Published private(set) var status: String?
    @Published private(set) var isWorking = false
    private let defaults: UserDefaults
    private let credentialAccess: SMSCredentialAccess
    private let coordinator: SMSAlertCoordinator
    private var setupRevision: UInt64 = 0
    private var deliveryTasks: [UUID: Task<Void, Never>] = [:]

    init(defaults: UserDefaults, credentialAccess: SMSCredentialAccess? = nil,
         coordinator: SMSAlertCoordinator? = nil) {
        self.defaults = defaults
        self.credentialAccess = credentialAccess ?? .live
        self.coordinator = coordinator ?? SMSAlertCoordinator(persistence: .userDefaults(defaults, key: Keys.history))
        self.preferences = .load(from: defaults, key: Keys.preferences)
        self.hasSavedSetup = defaults.bool(forKey: Keys.hasSetup)
        if let data = defaults.data(forKey: Keys.configuration) {
            self.configuration = try? JSONDecoder().decode(TwilioSMSConfiguration.self, from: data)
        }
    }

    /// Called only for a newly detected event, never while reading exported history.
    @discardableResult
    func deliver(kind: String, title: String, body: String, eventID: String) -> Task<Void, Never>? {
        guard preferences[kind], hasSavedSetup else { return nil }
        let revision = setupRevision
        let deliveryID = UUID()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.deliveryTasks.removeValue(forKey: deliveryID) }
            guard !Task.isCancelled else { return }
            let credentials = await self.credentialAccess.load()
            guard !Task.isCancelled, revision == self.setupRevision,
                  self.preferences[kind], self.hasSavedSetup else { return }
            let result = await self.coordinator.send(eventID: eventID, kind: kind, title: title, body: body,
                                                      preferences: self.preferences, credentials: credentials)
            guard !Task.isCancelled, revision == self.setupRevision else { return }
            switch result {
            case .accepted: self.status = "Text accepted by Twilio."
            case .failed(let failure): self.status = failure.localizedDescription
            case .disabled, .duplicate: break
            }
        }
        deliveryTasks[deliveryID] = task
        return task
    }

    @discardableResult
    func saveSetup(configuration: TwilioSMSConfiguration, apiKeySecret: String) async -> Bool {
        guard !isWorking else { return false }
        isWorking = true
        invalidateDeliveries()
        defer { isWorking = false }
        do {
            var secret = apiKeySecret.trimmingCharacters(in: .whitespacesAndNewlines)
            if secret.isEmpty {
                guard let existing = await credentialAccess.load(),
                      existing.configuration.accountSID == configuration.accountSID,
                      existing.configuration.apiKeySID == configuration.apiKeySID else {
                    status = "Enter the secret for this Twilio API key."
                    return false
                }
                secret = existing.apiKeySecret
            }
            let credentials = TwilioSMSCredentials(configuration: configuration, apiKeySecret: secret)
            try credentials.validate()
            try await credentialAccess.save(credentials)
            remember(configuration)
            status = "Twilio setup saved."
            return true
        } catch let failure as TwilioSMSFailure { status = failure.localizedDescription }
        catch { status = "Keychain could not save the Twilio setup." }
        return false
    }

    func forgetSetup() async {
        guard !isWorking else { return }
        isWorking = true
        invalidateDeliveries()
        defer { isWorking = false }
        do {
            try await credentialAccess.clear()
            hasSavedSetup = false
            configuration = nil
            defaults.removeObject(forKey: Keys.configuration)
            defaults.removeObject(forKey: Keys.hasSetup)
            // Reservations remain after Forget, preventing an old event from being sent again.
            status = "Twilio setup forgotten."
        } catch { status = "Keychain could not forget the Twilio setup." }
    }

    /// Invoked only from the explicit settings button.
    func reauthorizeSavedSetup() async {
        guard !isWorking else { return }
        isWorking = true
        invalidateDeliveries()
        defer { isWorking = false }
        guard let credentials = await credentialAccess.reauthorize(),
              (try? credentials.validate()) != nil else {
            status = "The saved Twilio setup is unavailable in Keychain."
            return
        }
        remember(credentials.configuration)
        status = "Saved Twilio setup authorized."
    }

    private func invalidateDeliveries() {
        setupRevision &+= 1
        let active = Array(deliveryTasks.values)
        deliveryTasks.removeAll()
        active.forEach { $0.cancel() }
    }

    private func remember(_ config: TwilioSMSConfiguration) {
        configuration = config
        hasSavedSetup = true
        defaults.set(true, forKey: Keys.hasSetup)
        defaults.set(try? JSONEncoder().encode(config), forKey: Keys.configuration)
    }
}
