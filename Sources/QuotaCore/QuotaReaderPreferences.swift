import Foundation

/// Per-device choices for optional local quota readers.  Missing entries stay
/// enabled for established readers. New Token Plan readers require explicit
/// opt-in because they invoke a signed-in CLI or use a stored provider key.
public struct QuotaReaderPreferences: Codable, Equatable, Sendable {
    public static let defaultsKey = "optionalQuotaReaders"
    public var enabledByReaderID: [String: Bool]

    public init(enabledByReaderID: [String: Bool] = [:]) {
        self.enabledByReaderID = enabledByReaderID
    }

    public func isEnabled(_ readerID: String) -> Bool {
        enabledByReaderID[readerID] ?? !["alibaba-token-plan", "mimo-token-plan"].contains(readerID)
    }

    public mutating func setEnabled(_ enabled: Bool, for readerID: String) {
        enabledByReaderID[readerID] = enabled
    }

    public static func load(from defaults: UserDefaults, key: String = defaultsKey) -> Self {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return saved
    }

    public func save(to defaults: UserDefaults, key: String = defaultsKey) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: key)
    }
}
