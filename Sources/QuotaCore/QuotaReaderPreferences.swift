import Foundation

/// Per-device choices for optional local quota readers.  Missing entries stay
/// enabled so existing installations and readers added by a later app version
/// keep the current automatic-read behavior until the owner changes it.
public struct QuotaReaderPreferences: Codable, Equatable, Sendable {
    public static let defaultsKey = "optionalQuotaReaders"
    public var enabledByReaderID: [String: Bool]

    public init(enabledByReaderID: [String: Bool] = [:]) {
        self.enabledByReaderID = enabledByReaderID
    }

    public func isEnabled(_ readerID: String) -> Bool {
        enabledByReaderID[readerID] ?? true
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
