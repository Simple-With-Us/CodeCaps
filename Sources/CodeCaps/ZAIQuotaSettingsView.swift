import Combine
import Foundation
import QuotaCore
import SwiftUI

@MainActor
struct ZAIQuotaCredentialAccess {
    var save: (ZCodeQuotaCredential) async throws -> Void
    var clear: () async throws -> Void
    var reauthorize: () async -> ZCodeQuotaCredential?

    static let live = Self(save: { try await ZAIQuotaCredentialStore.shared.save($0) },
                           clear: { try await ZAIQuotaCredentialStore.shared.clear() },
                           reauthorize: { await ZAIQuotaCredentialStore.shared.readAllowingInteraction() })
}

@MainActor
final class ZAIQuotaSetupController: ObservableObject {
    @Published private(set) var hasSavedKey: Bool
    @Published private(set) var savedRegion: ZCodeQuotaRegion?
    @Published private(set) var isWorking = false
    @Published private(set) var status: String?
    var changed: (() -> Void)?
    private let defaults: UserDefaults
    private let access: ZAIQuotaCredentialAccess

    init(defaults: UserDefaults, access: ZAIQuotaCredentialAccess? = nil) {
        self.defaults = defaults
        self.access = access ?? .live
        hasSavedKey = defaults.bool(forKey: "zaiQuotaHasSavedKey")
        savedRegion = defaults.string(forKey: "zaiQuotaRegion").flatMap(ZCodeQuotaRegion.init(rawValue:))
    }

    @discardableResult
    func save(apiKey: String, region: ZCodeQuotaRegion) async -> Bool {
        guard !isWorking else { return false }
        let credential = ZCodeQuotaCredential(region: region, apiKey: apiKey)
        guard credential.isValid else { status = "Enter a valid Coding Plan API key."; return false }
        isWorking = true
        defer { isWorking = false }
        do {
            try await access.save(credential)
            remember(region)
            status = "Coding Plan API key saved."
            changed?()
            return true
        } catch { status = "Keychain could not save the Coding Plan API key."; return false }
    }

    func reauthorize() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        guard let credential = await access.reauthorize(), credential.isValid else {
            status = "The saved Coding Plan API key is unavailable in Keychain."
            return
        }
        remember(credential.region)
        status = "Saved Coding Plan API key authorized."
        changed?()
    }

    func forget() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await access.clear()
            hasSavedKey = false
            savedRegion = nil
            defaults.removeObject(forKey: "zaiQuotaHasSavedKey")
            defaults.removeObject(forKey: "zaiQuotaRegion")
            status = "Coding Plan API key forgotten."
            changed?()
        } catch { status = "Keychain could not forget the Coding Plan API key." }
    }

    private func remember(_ region: ZCodeQuotaRegion) {
        hasSavedKey = true
        savedRegion = region
        defaults.set(true, forKey: "zaiQuotaHasSavedKey")
        defaults.set(region.rawValue, forKey: "zaiQuotaRegion")
    }
}

@MainActor
struct ZAIQuotaSettingsView: View {
    @ObservedObject var controller: ZAIQuotaSetupController
    @State private var apiKey = ""
    @State private var region: ZCodeQuotaRegion = .zAI

    var body: some View {
        DisclosureGroup("Z.ai Coding Plan Key") {
            Picker("Region", selection: $region) {
                ForEach(ZCodeQuotaRegion.allCases) { region in Text(region.title).tag(region) }
            }
            SecureField("Coding Plan API Key", text: $apiKey)
            HStack {
                Button("Save Key") {
                    Task { if await controller.save(apiKey: apiKey, region: region) { apiKey = "" } }
                }
                .disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Re-Authorize Saved Key") { Task { await controller.reauthorize() } }
                Button("Forget Key") {
                    Task {
                        await controller.forget()
                        if !controller.hasSavedKey { apiKey = "" }
                    }
                }
                .disabled(!controller.hasSavedKey)
                if controller.isWorking { ProgressView().controlSize(.small) }
            }
            if let status = controller.status { Text(status).font(.caption).foregroundStyle(.secondary) }
            Text("Enter an existing Coding Plan API key for the selected region." + sentenceGap
                 + "The key and region are saved together in this build’s Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(controller.isWorking)
        .onAppear { region = controller.savedRegion ?? .zAI }
        .onChange(of: controller.savedRegion) { _, value in region = value ?? .zAI }
    }
}
