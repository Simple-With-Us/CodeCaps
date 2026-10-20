import SwiftUI
import UserNotifications

#if os(iOS)
final class CodeCapsNotificationDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        RemotePushRegistration.shared.receivedDeviceToken(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        RemotePushRegistration.shared.registrationFailed()
    }
}
#endif

/// App entry point for the CodeCaps iOS companion application.
@main
struct CodeCapsCompanionApp: App {
    #if os(iOS)
    @UIApplicationDelegateAdaptor(CodeCapsNotificationDelegate.self) private var appDelegate
    #endif

    @StateObject private var model = CompanionQuotaModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        SentryTelemetry.start()
    }

    var body: some Scene {
        WindowGroup {
            CompanionContentView(model: model)
                #if os(iOS)
                .task {
                    RemotePushRegistration.shared.configure(endpoint: model.syncEndpoint, preferences: model.alertPreferences)
                    let delivered = await UNUserNotificationCenter.current().deliveredNotifications()
                    for notification in delivered { RemotePushRegistration.shared.recordReceived(notification: notification) }
                    RemotePushRegistration.shared.registerWithApple()
                }
                .onChange(of: model.syncEndpoint) { _, endpoint in
                    RemotePushRegistration.shared.configure(endpoint: endpoint, preferences: model.alertPreferences)
                }
                .onChange(of: model.alertPreferences) { _, preferences in
                    RemotePushRegistration.shared.configure(endpoint: model.syncEndpoint, preferences: preferences)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { RemotePushRegistration.shared.registerWithApple() }
                }
                #endif
        }
    }
}
