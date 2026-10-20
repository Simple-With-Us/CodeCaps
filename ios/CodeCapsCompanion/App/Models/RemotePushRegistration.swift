import Foundation
import CoreFoundation
import Security
import SwiftUI
import UserNotifications
#if os(iOS)
import UIKit

/// Opt-in remote enrollment is independent of the quota read credential.
@MainActor
final class RemotePushRegistration: NSObject, ObservableObject, URLSessionTaskDelegate {
    static let shared = RemotePushRegistration()
    @Published private(set) var enabled: Bool
    @Published private(set) var status = "Remote push is off."
    @Published private(set) var hasCredential = false
    @Published private(set) var hasError = false
    private var endpoint = ""
    private var preferences = UsageAlertPreferences()
    private var token: String?
    private var revision = 0
    private var task: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    private override init() {
        enabled = UserDefaults.standard.bool(forKey: "remotePushEnabled")
        super.init()
        hasCredential = credential() != nil
        token = credential(account: "deviceToken")
        if enabled { status = "Waiting to register for remote push." }
        else if defaults.string(forKey: "remotePushEnrolledURL") != nil {
            status = "Push is off on this device; retry to remove its server enrollment."
            hasError = true
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func configure(endpoint: String, preferences: UsageAlertPreferences) {
        guard self.endpoint != endpoint || self.preferences != preferences else { return }
        self.endpoint = endpoint
        self.preferences = preferences
        if enabled { enroll() }
    }

    func saveCredential(_ value: String) {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let result = save(value.trimmingCharacters(in: .whitespacesAndNewlines), account: "registration")
        hasCredential = credential() != nil
        if result != errSecSuccess { fail("Could not save the push registration credential in Keychain."); return }
        if enabled { enroll() }
    }

    func setEnabled(_ value: Bool) {
        revision += 1
        task?.cancel()
        if value {
            guard enabled || defaults.string(forKey: "remotePushEnrolledURL") == nil else {
                fail("Finish server removal before enabling remote push again." + sentenceGap + "Use Retry Server Removal.")
                return
            }
            guard hasCredential else { fail("Save the server's push registration credential first."); return }
            guard registrationURL() != nil else { fail("Set an HTTPS quota sync endpoint first."); return }
        }
        enabled = value
        defaults.set(value, forKey: "remotePushEnabled")
        if value {
            registerWithApple()
        } else {
            UIApplication.shared.unregisterForRemoteNotifications()
            status = "Removing this device from remote push."
            let generation = revision
            task = Task { await removeEnrollment(generation: generation) }
        }
    }

    func registerWithApple() {
        guard enabled else { return }
        let generation = revision
        task?.cancel()
        task = Task {
            guard !Task.isCancelled, generation == revision, enabled else { return }
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                guard !Task.isCancelled, generation == revision, enabled else { return }
                guard granted else { fail("Notifications are off in iOS Settings."); return }
                hasError = false
                status = "Registering this device with Apple."
                UIApplication.shared.registerForRemoteNotifications()
            } catch { if !Task.isCancelled, generation == revision, enabled { fail("Apple notification authorization failed.") } }
        }
    }

    func receivedDeviceToken(_ data: Data) {
        guard enabled else { return }
        let value = data.map { String(format: "%02x", $0) }.joined()
        guard save(value, account: "deviceToken") == errSecSuccess else {
            fail("Could not save the Apple device registration in Keychain."); return
        }
        token = value
        enroll()
    }

    func registrationFailed() {
        guard enabled else { return }
        fail("Apple push registration failed." + sentenceGap + "Retry when this device is online.")
    }

    func recordReceived(notification: UNNotification) {
        guard notification.request.trigger is UNPushNotificationTrigger,
              let id = notification.request.content.userInfo["alertId"] as? String else { return }
        var ids = defaults.stringArray(forKey: "announcedAlertIds") ?? []
        if !ids.contains(id) { ids.append(id) }
        defaults.set(Array(ids.suffix(200)), forKey: "announcedAlertIds")
    }

    func presentationOptions(for notification: UNNotification) -> UNNotificationPresentationOptions {
        guard notification.request.trigger is UNPushNotificationTrigger else {
            return [.banner, .sound, .list]
        }
        let id = notification.request.content.userInfo["alertId"] as? String
        let alreadyAnnounced = id.map { (defaults.stringArray(forKey: "announcedAlertIds") ?? []).contains($0) } ?? false
        recordReceived(notification: notification)
        guard !alreadyAnnounced, enabled,
              let raw = notification.request.content.userInfo["kind"] as? String,
              let kind = UsageAlertKind(rawValue: raw) else { return [] }
        let option = preferences[kind]
        guard option.enabled && option.notification else { return [] }
        var result: UNNotificationPresentationOptions = [.banner, .list]
        if option.sound.isAudible { result.insert(.sound) }
        return result
    }

    private func registrationURL() -> URL? {
        guard var parts = URLComponents(string: endpoint), parts.scheme?.lowercased() == "https",
              parts.host != nil, parts.user == nil, parts.password == nil else { return nil }
        parts.path = "/api/codecaps/push/devices"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    private func installationId() -> String? {
        let stored = persistentValue(account: "installationId")
        guard stored.status == errSecSuccess || stored.status == errSecItemNotFound else {
            fail("Keychain could not read the push installation identity; server enrollment was not changed.")
            return nil
        }
        if let id = stored.value {
            guard UUID(uuidString: id) != nil else {
                fail("The saved push installation identity is invalid; server enrollment was not changed.")
                return nil
            }
            return id
        }
        let legacy = defaults.string(forKey: "remotePushInstallationId").flatMap(UUID.init(uuidString:))
        let id = (legacy ?? UUID()).uuidString.lowercased()
        guard save(id, account: "installationId") == errSecSuccess else {
            fail("Keychain could not save the push installation identity; server enrollment was not changed.")
            return nil
        }
        defaults.set(id, forKey: "remotePushInstallationId")
        return id
    }

    private func persistedGeneration() -> Int? {
        let stored = persistentValue(account: "generation")
        guard stored.status == errSecSuccess || stored.status == errSecItemNotFound else {
            fail("Keychain could not read the push generation; server enrollment was not changed.")
            return nil
        }
        let saved = stored.value.flatMap(Int.init)
        guard stored.value == nil || saved != nil else {
            fail("The saved push generation is invalid; server enrollment was not changed.")
            return nil
        }
        let legacy = defaults.integer(forKey: "remotePushGeneration")
        let current = saved ?? 0
        guard legacy >= 0, current >= 0,
              max(legacy, current) <= 9_000_000_000_000_000 else {
            fail("The push registration generation is invalid; server enrollment was not changed.")
            return nil
        }
        return max(legacy, current)
    }

    private func saveGeneration(_ generation: Int) -> Bool {
        guard save(String(generation), account: "generation") == errSecSuccess else {
            fail("Keychain could not save the push generation." + sentenceGap + "Remote push registration is not confirmed.")
            return false
        }
        defaults.set(generation, forKey: "remotePushGeneration")
        return true
    }

    private func adoptServerGeneration(_ generation: Int) -> Bool {
        guard generation >= 0, generation <= 9_000_000_000_000_000,
              let current = persistedGeneration() else { return false }
        return generation <= current || saveGeneration(generation)
    }

    /// Persist before dispatch so a later opt-out supersedes any in-flight enrollment.
    private func nextGeneration() -> Int? {
        guard let current = persistedGeneration() else { return nil }
        guard current < 9_000_000_000_000_000 else {
            fail("The push registration generation is invalid; server enrollment was not changed.")
            return nil
        }
        let next = current + 1
        guard saveGeneration(next) else { return nil }
        return next
    }

    private func enroll() {
        revision += 1
        task?.cancel()
        guard enabled, let token else { if enabled { registerWithApple() }; return }
        guard let url = registrationURL(), let credential = credential() else {
            fail("Remote push needs an HTTPS sync endpoint and a separate registration credential."); return
        }
        guard let installationId = installationId(), let payloadGeneration = nextGeneration() else { return }
        let generation = revision
        status = "Saving remote push choices."
        hasError = false
        let preferenceData = try? JSONEncoder().encode(preferences)
        let preferenceObject = preferenceData.flatMap { try? JSONSerialization.jsonObject(with: $0) }
        #if DEBUG
        let environment = "sandbox"
        #else
        let environment = "production"
        #endif
        let body: [String: Any] = ["installationId": installationId, "deviceToken": token, "generation": payloadGeneration,
            "environment": environment, "preferences": preferenceObject ?? ["options": [:]]]
        task = Task {
            guard !Task.isCancelled, generation == revision, enabled else { return }
            do {
                // Remove enrollment at an old server before moving the device to a new one.
                if let old = defaults.string(forKey: "remotePushEnrolledURL"), old != url.absoluteString {
                    fail("Disable remote push before changing its server.")
                    return
                }
                var request = URLRequest(url: url, timeoutInterval: 15)
                request.httpMethod = "POST"
                request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                // Persist the attempted server before sending: an interrupted response
                // cannot prove the server did not enroll this device.
                defaults.set(url.absoluteString, forKey: "remotePushEnrolledURL")
                let (data, response) = try await session.data(for: request)
                guard !Task.isCancelled, generation == revision, enabled else { return }
                if let http = response as? HTTPURLResponse, http.statusCode == 503 {
                    fail("Apple registration succeeded; the server's push service is unavailable (503)." + sentenceGap + "Check its APNs configuration and retry.")
                    return
                }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["ok"] as? Bool == true else {
                    fail("The server did not accept push registration." + sentenceGap + "Check its setup and registration credential."); return
                }
                guard let device = result["device"] as? [String: Any],
                      let serverGeneration = Self.responseGeneration(device["generation"]) else {
                    fail("The server returned an invalid push enrollment acknowledgment.")
                    return
                }
                guard adoptServerGeneration(serverGeneration) else { return }
                guard result["applied"] as? Bool == true, device["isActive"] as? Bool == true,
                      serverGeneration == payloadGeneration else {
                    fail("The server did not apply these push choices." + sentenceGap + "Retry registration to supersede its saved generation.")
                    return
                }
                defaults.set(url.absoluteString, forKey: "remotePushEnrolledURL")
                status = "Remote push registered."
                hasError = false
            } catch { if !Task.isCancelled, generation == revision { fail("Apple registration succeeded; remote push choices were not saved." + sentenceGap + "Retry when the server is reachable.") } }
        }
    }

    private func removeEnrollment(generation: Int) async {
        guard !Task.isCancelled, generation == revision, !enabled else { return }
        guard let enrolled = defaults.string(forKey: "remotePushEnrolledURL") else {
            status = "Remote push is off."
            hasError = false
            return
        }
        guard let parts = URLComponents(string: enrolled), parts.scheme?.lowercased() == "https",
              parts.host != nil, parts.user == nil, parts.password == nil, let url = parts.url,
              let credential = credential() else {
            fail("Push is off on this device; save the server credential and retry server removal.")
            return
        }
        guard let installationId = installationId(), let payloadGeneration = nextGeneration() else { return }
        do {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "DELETE"
            request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["installationId": installationId, "generation": payloadGeneration])
            let (data, response) = try await session.data(for: request)
            guard generation == revision, !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let result = try JSONSerialization.jsonObject(with: data) as? [String: Any], result["ok"] as? Bool == true else {
                fail("Push is off on this device; server removal failed." + sentenceGap + "Retry to remove its enrollment."); return
            }
            guard let serverGeneration = Self.responseGeneration(result["generation"]) else {
                fail("The server returned an invalid push removal acknowledgment." + sentenceGap + "Retry Server Removal.")
                return
            }
            guard adoptServerGeneration(serverGeneration) else { return }
            guard result["applied"] as? Bool == true, result["removed"] is Bool,
                  serverGeneration == payloadGeneration else {
                fail("A newer server enrollment superseded this removal." + sentenceGap + "Retry Server Removal.")
                return
            }
            defaults.removeObject(forKey: "remotePushEnrolledURL")
            status = "Remote push is off."
            hasError = false
        } catch { if !Task.isCancelled, generation == revision { fail("Push is off on this device; retry to remove its server enrollment.") } }
    }

    private func fail(_ message: String) { status = message; hasError = true }

    private static func responseGeneration(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue <= 9_000_000_000_000_000,
              number.doubleValue.rounded(.towardZero) == number.doubleValue else { return nil }
        return Int(number.int64Value)
    }

    private func persistentValue(account: String) -> (value: String?, status: OSStatus) {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        guard status == errSecSuccess else { return (nil, status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            return (nil, errSecDecode)
        }
        return (value, status)
    }

    private func query(account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.simplewithus.codecaps.push",
         kSecAttrAccount as String: account]
    }
    private func credential(account: String = "registration") -> String? {
        var q = query(account: account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    private func save(_ value: String, account: String) -> OSStatus {
        let q = query(account: account)
        let attrs: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let result = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
        guard result == errSecItemNotFound else { return result }
        return SecItemAdd(q.merging(attrs) { _, new in new } as CFDictionary, nil)
    }
}

struct RemotePushSettingsView: View {
    @ObservedObject private var push = RemotePushRegistration.shared
    @State private var credential = ""

    var body: some View {
        Section {
            SecureField("Push Registration Credential", text: $credential)
                .textContentType(.password)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            Button("Save Push Credential") { push.saveCredential(credential); credential = "" }
                .disabled(credential.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Toggle("Enable Remote Push", isOn: Binding(get: { push.enabled }, set: { push.setEnabled($0) }))
            Button(push.enabled ? "Retry Push Registration" : "Retry Server Removal") {
                if push.enabled { push.registerWithApple() } else { push.setEnabled(false) }
            }
            Text(push.status).font(.caption).foregroundStyle(push.hasError ? Color.orange : Color.secondary)
        } header: {
            Text("Remote Push")
        } footer: {
            Text("Receive selected alerts while CodeCaps is closed." + sentenceGap + "The sync server needs CodeCaps push support and its separate registration credential.")
        }
    }
}
#endif
