import Foundation

/// A typed extension point for adding another asynchronous local quota reader.
public protocol LocalQuotaReading: Sendable {
    func read() async -> LocalQuotaResult
}

extension LocalQuotaReader: LocalQuotaReading {}
extension CursorQuotaReader: LocalQuotaReading {}
extension CopilotQuotaReader: LocalQuotaReading {}
extension GrokBotQuotaReader: LocalQuotaReading {}
extension GbuQuotaReader: LocalQuotaReading {}
extension KimiQuotaReader: LocalQuotaReading {}
extension ZCodeQuotaReader: LocalQuotaReading {}

/// A registered reader and the non-secret configuration metadata used to
/// describe it in the app.  The factory keeps credential reads inside the
/// selected reader and is never invoked for a disabled optional reader.
public struct LocalQuotaReaderRegistration: Sendable {
    public let id: String
    public let label: String
    public let configurationMetadata: [String: String]
    public let isOptional: Bool
    private let makeReader: @Sendable () -> any LocalQuotaReading

    public init(id: String, label: String, configurationMetadata: [String: String] = [:],
                isOptional: Bool = false,
                makeReader: @escaping @Sendable () -> any LocalQuotaReading) {
        self.id = id
        self.label = label
        self.configurationMetadata = configurationMetadata
        self.isOptional = isOptional
        self.makeReader = makeReader
    }

    fileprivate func read() async -> LocalQuotaResult {
        await makeReader().read()
    }
}

/// Concurrent, deterministic aggregator for local quota readers.  Results are
/// merged in registration order to preserve the existing issue precedence.
public struct LocalQuotaReaderRegistry: Sendable {
    public let registrations: [LocalQuotaReaderRegistration]

    public init(registrations: [LocalQuotaReaderRegistration]) {
        self.registrations = registrations
    }

    public var optionalRegistrations: [LocalQuotaReaderRegistration] {
        registrations.filter(\.isOptional)
    }

    public func read(preferences: QuotaReaderPreferences = .init()) async -> LocalQuotaResult {
        let selected = registrations.enumerated().filter { _, registration in
            !registration.isOptional || preferences.isEnabled(registration.id)
        }
        let results = await withTaskGroup(of: (Int, LocalQuotaResult).self,
                                          returning: [(Int, LocalQuotaResult)].self) { group in
            for (index, registration) in selected {
                group.addTask { (index, await registration.read()) }
            }
            var collected: [(Int, LocalQuotaResult)] = []
            for await result in group { collected.append(result) }
            return collected.sorted { $0.0 < $1.0 }
        }
        var windows: [QuotaWindow] = []
        var issues: [String: String] = [:]
        var consentNeeded: Set<String> = []
        for (_, result) in results {
            windows.append(contentsOf: result.windows)
            issues.merge(result.issues) { _, next in next }
            consentNeeded.formUnion(result.consentNeeded)
        }
        return LocalQuotaResult(windows: windows, issues: issues, consentNeeded: consentNeeded)
    }

    /// The concrete built-ins stay explicit while the typed registration seam
    /// allows future providers without a dynamic code loader.
    public static let builtIn = configured(zCodeCredentialProvider: { nil })

    /// The optional Z.ai factory resolves its own saved key only when selected.
    public static func configured(
        zCodeCredentialProvider: @escaping @Sendable () async -> ZCodeQuotaCredential?
    ) -> LocalQuotaReaderRegistry {
        LocalQuotaReaderRegistry(registrations: [
            LocalQuotaReaderRegistration(id: "local-primary", label: "Built-In Provider Sessions",
                                         configurationMetadata: ["providers": "anthropic,openai,grok,minimax,google-antigravity"]) {
                LocalQuotaReader()
            },
            LocalQuotaReaderRegistration(id: "cursor", label: "Cursor", configurationMetadata: ["providerKey": "cursor"]) {
                CursorQuotaReader()
            },
            LocalQuotaReaderRegistration(id: "github-copilot", label: "GitHub Copilot", configurationMetadata: ["providerKey": "github-copilot"]) {
                CopilotQuotaReader()
            },
            LocalQuotaReaderRegistration(id: "grok-bot", label: "Grok Bot", configurationMetadata: ["providerKey": "grok-bot"]) {
                GrokBotQuotaReader()
            },
            LocalQuotaReaderRegistration(id: "gbu", label: "Grok Build Usage", configurationMetadata: ["providerKey": "grok-bot"]) {
                GbuQuotaReader()
            },
            LocalQuotaReaderRegistration(id: "kimi", label: "Kimi", configurationMetadata: ["providerKey": "kimi"], isOptional: true) {
                KimiQuotaReader()
            },
            LocalQuotaReaderRegistration(id: "zcode", label: "Z.ai / ZCode", configurationMetadata: ["providerKey": "zcode"], isOptional: true) {
                ZCodeQuotaReader(credential: zCodeCredentialProvider)
            },
        ])
    }
}
