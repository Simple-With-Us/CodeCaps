import Foundation

/// Personal credentials and their explicit purpose are persisted only by the app's Keychain store.
public struct InfisicalBinding: Codable, Equatable, Sendable, Identifiable {
    public enum Authentication: String, Codable, CaseIterable, Hashable, Sendable {
        case serviceToken, machineIdentity
        public var title: String { self == .serviceToken ? "Service Token (Recommended)" : "Machine Identity" }
    }
    public enum Access: String, Codable, CaseIterable, Hashable, Sendable {
        case read, write
        public var title: String { self == .read ? "Read" : "Write" }
    }
    public var id: String
    public var label: String
    public var siteURL: URL
    public var projectId: String
    public var environment: String
    public var secretPath: String
    public var authentication: Authentication
    public var access: Access
    public var serviceToken: String
    public var clientId: String
    public var clientSecret: String

    public init(id: String = UUID().uuidString, label: String,
                siteURL: URL = URL(string: "https://app.infisical.com")!,
                projectId: String, environment: String = "prod", secretPath: String = "/",
                authentication: Authentication = .serviceToken, access: Access,
                serviceToken: String = "", clientId: String = "", clientSecret: String = "") {
        self.id = id; self.label = label; self.siteURL = siteURL
        self.projectId = projectId; self.environment = environment; self.secretPath = secretPath
        self.authentication = authentication; self.access = access
        self.serviceToken = serviceToken; self.clientId = clientId; self.clientSecret = clientSecret
    }

    public func validate() throws {
        guard !id.isEmpty, id.utf8.count <= 128, !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              label.utf8.count <= 160, !projectId.isEmpty, projectId.utf8.count <= 256,
              projectId.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-" )).contains($0) }),
              !environment.isEmpty, environment.utf8.count <= 128,
              environment.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-" )).contains($0) }),
              secretPath.hasPrefix("/"), secretPath.utf8.count <= 1_024,
              !secretPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !secretPath.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
              let site = URLComponents(url: siteURL, resolvingAgainstBaseURL: false),
              site.scheme == "https", site.host?.isEmpty == false,
              site.user == nil, site.password == nil, site.query == nil, site.fragment == nil else {
            throw InfisicalSettings.SettingsError.invalidDestination
        }
        switch authentication {
        case .serviceToken:
            let parts = serviceToken.split(separator: ".", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0] == "st", !parts[1].isEmpty, !parts[2].isEmpty,
                  serviceToken.utf8.count <= 16_384,
                  serviceToken.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
                throw InfisicalSettings.SettingsError.invalidDestination
            }
        case .machineIdentity:
            guard !clientId.isEmpty, clientId.utf8.count <= 512,
                  !clientSecret.isEmpty, clientSecret.utf8.count <= 16_384 else {
                throw InfisicalSettings.SettingsError.invalidDestination
            }
        }
    }

    public func matchesScope(of other: Self) -> Bool {
        siteURL == other.siteURL && projectId == other.projectId
            && environment == other.environment && secretPath == other.secretPath
    }
}

public struct InfisicalSetup: Codable, Equatable, Sendable {
    public var bindings: [InfisicalBinding]
    public var readBindingID: String?
    public var writeBindingID: String?

    public init(bindings: [InfisicalBinding] = [], readBindingID: String? = nil, writeBindingID: String? = nil) {
        self.bindings = bindings; self.readBindingID = readBindingID; self.writeBindingID = writeBindingID
    }

    public var configuration: InfisicalSettings.Configuration? {
        guard let readBindingID, let read = bindings.first(where: { $0.id == readBindingID }), read.access == .read else { return nil }
        let write = writeBindingID.flatMap { id in bindings.first { $0.id == id } }
        return .init(readBinding: read, writeBinding: write)
    }

    public func validate() throws {
        guard bindings.count <= 32, Set(bindings.map(\.id)).count == bindings.count else {
            throw InfisicalSettings.SettingsError.invalidDestination
        }
        for binding in bindings { try binding.validate() }
        if let writeBindingID {
            guard bindings.contains(where: { $0.id == writeBindingID && $0.access == .write }) else {
                throw InfisicalSettings.SettingsError.writeNotConfigured
            }
        }
        if readBindingID != nil {
            guard let configuration else { throw InfisicalSettings.SettingsError.invalidDestination }
            try configuration.validate()
        } else if writeBindingID != nil { throw InfisicalSettings.SettingsError.writeNotConfigured }
    }
}
