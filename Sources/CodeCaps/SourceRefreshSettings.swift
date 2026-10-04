import Foundation

enum SourceRefreshCadence: Int, CaseIterable, Identifiable {
    case one = 1
    case three = 3
    case five = 5
    case fifteen = 15

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue * 60) }
    var title: String { "Every \(rawValue) minute\(rawValue == 1 ? "" : "s")" }
}

enum SourceRefreshPreference {
    static let providerEnabled = "providerChecksEnabled"
    static let sessionEnabled = "sessionFileChecksEnabled"
    static let providerMinutes = "providerCheckMinutes"
    static let sessionMinutes = "sessionFileCheckMinutes"

    static func enabled(_ key: String, defaults: UserDefaults) -> Bool {
        defaults.object(forKey: key) as? Bool ?? true
    }

    static func cadence(_ key: String, fallback: SourceRefreshCadence,
                        defaults: UserDefaults) -> SourceRefreshCadence {
        SourceRefreshCadence(rawValue: defaults.integer(forKey: key)) ?? fallback
    }
}
