import Foundation

/// Stable categories shared by Mac, companion, and remote notification payloads.
public enum UsageAlertKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case anomaly, runaway, vendorReset, quotaReset, quotaExhaustion

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .anomaly: return "Usage Anomalies"
        case .runaway: return "Runaway Usage"
        case .vendorReset: return "Vendor Quota Resets"
        case .quotaReset: return "Scheduled Quota Resets"
        case .quotaExhaustion: return "Quota Exhaustion"
        }
    }
    public var detail: String {
        switch self {
        case .anomaly: return "Usage exceeds your recent average."
        case .runaway: return "Usage exceeds your recent peak."
        case .vendorReset: return "A provider restores quota before its scheduled reset."
        case .quotaReset: return "A quota window resets on schedule."
        case .quotaExhaustion: return "A quota window reaches its limit."
        }
    }
}

/// Personal notification choices stay on the device, outside Infisical.
public struct UsageAlertOption: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var notification: Bool
    public var popup: Bool
    public var sound: ResetAlarmSound

    public init(enabled: Bool = false, notification: Bool = true,
                popup: Bool = false, sound: ResetAlarmSound = .systemDefault) {
        self.enabled = enabled
        self.notification = notification
        self.popup = popup
        self.sound = sound
    }
}

public struct UsageAlertPreferences: Codable, Equatable, Sendable {
    public var options: [String: UsageAlertOption]

    public init(options: [String: UsageAlertOption] = [:]) {
        self.options = options
    }

    public subscript(kind: UsageAlertKind) -> UsageAlertOption {
        get { options[kind.rawValue] ?? UsageAlertOption() }
        set { options[kind.rawValue] = newValue }
    }

    /// Preserve existing reset and runaway opt-ins when adopting category settings.
    public static func load(from defaults: UserDefaults, key: String,
                            resetEnabled: Bool, resetSound: ResetAlarmSound,
                            runawayEnabled: Bool = false) -> Self {
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode(Self.self, from: data) {
            return saved
        }
        var result = Self()
        for kind in UsageAlertKind.allCases {
            let enabled: Bool
            switch kind {
            case .quotaReset, .vendorReset: enabled = resetEnabled
            case .anomaly, .runaway: enabled = runawayEnabled
            case .quotaExhaustion: enabled = false
            }
            result[kind] = UsageAlertOption(enabled: enabled, sound: resetSound)
        }
        return result
    }

    public func save(to defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: key)
    }
}
