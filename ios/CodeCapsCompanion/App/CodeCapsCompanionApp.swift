import SwiftUI
import UserNotifications

#if os(iOS)
final class CodeCapsNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .badge, .list])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
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

    var body: some Scene {
        WindowGroup {
            CompanionContentView(model: model)
        }
    }
}
