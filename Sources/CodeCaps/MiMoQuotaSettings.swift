import Foundation
import SwiftUI
import QuotaCore

actor MiMoQuotaCredentialStore {
    static let shared = MiMoQuotaCredentialStore()
    private let account = "quota-api-key-v1"
    private let service = TokenStore.serviceName(suffix: "mimo-quota-api-key", bundleIdentifier: Bundle.main.bundleIdentifier)
    private lazy var cache = TokenCache(calls: .live, bounds: .init(), ownServices: [service], log: { _ in })

    func load() async -> MiMoTokenPlanCredential? {
        guard let raw = await cache.token(server: account, service: service),
              let credential = try? JSONDecoder().decode(MiMoTokenPlanCredential.self, from: Data(raw.utf8)),
              credential.isValid else { return nil }
        return credential
    }

    func save(_ credential: MiMoTokenPlanCredential) async throws {
        guard credential.isValid else { throw CredentialError.invalid }
        let raw = String(decoding: try JSONEncoder().encode(credential), as: UTF8.self)
        try await cache.save(raw, server: account, service: service)
    }

    enum CredentialError: Error { case invalid }

    func clear() async throws {
        try await cache.delete(server: account, service: service)
    }
}

@MainActor
struct MiMoQuotaSettings: View {
    @ObservedObject var model: MonitorModel
    @State private var draft = ""
    @State private var region = MiMoTokenPlanRegion.singapore
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("MiMo Token Plan region", selection: $region) {
                ForEach(MiMoTokenPlanRegion.allCases, id: \.self) { value in
                    Text(value.title).tag(value)
                }
            }
            SecureField("Individual Token Plan key", text: $draft)
            HStack {
                Button("Save MiMo Key") { save() }
                    .disabled(busy || !MiMoTokenPlanCredential(key: draft, region: region).isValid)
                Button("Remove MiMo Key") { clear() }
                    .disabled(busy)
            }
            if let message { Text(message).font(.caption) }
            Text("The key stays in this Mac’s Keychain. Choose the region shown on your MiMo Token Plan page.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task {
            if let saved = await MiMoQuotaCredentialStore.shared.load() { region = saved.region }
        }
    }

    private func save() {
        let credential = MiMoTokenPlanCredential(key: draft, region: region)
        guard credential.isValid else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await MiMoQuotaCredentialStore.shared.save(credential)
                draft = ""
                model.tokenPlanCredentialChanged(enabled: true)
                message = "MiMo key saved."
            } catch { message = "CodeCaps could not save the MiMo key in Keychain." }
        }
    }

    private func clear() {
        busy = true
        Task {
            defer { busy = false }
            do {
                try await MiMoQuotaCredentialStore.shared.clear()
                draft = ""
                model.tokenPlanCredentialChanged(enabled: false)
                message = "MiMo key removed."
            } catch { message = "CodeCaps could not remove the MiMo key from Keychain." }
        }
    }
}
