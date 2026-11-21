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

#if os(iOS) && DEBUG
/// Debug-only support for scripts/test-widget-homescreen.sh.  When the probe
/// launches the companion with -CCWidgetProbeTouchGroupContainer, resolve the
/// App Group container once at startup (which asks the system to create it)
/// and record the outcome in the app's data container, so the probe can tell
/// "the entitlement was not honored" apart from "the app never asked".
enum WidgetProbeHooks {
    static func touchGroupContainerIfRequested() {
        guard ProcessInfo.processInfo.arguments.contains("-CCWidgetProbeTouchGroupContainer") else { return }
        let fm = FileManager.default
        // Same identifier as the model, via its nonisolated alias (kody).
        let resolved = fm.containerURL(forSecurityApplicationGroupIdentifier: CompanionQuotaModel.codeCapsAppGroupId)
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        try? fm.createDirectory(at: documents, withIntermediateDirectories: true)
        let marker = documents.appendingPathComponent("cc-widget-probe-group-container.txt")
        try? (resolved?.path ?? "NIL").write(to: marker, atomically: true, encoding: .utf8)
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
        #if os(iOS) && DEBUG
        WidgetProbeHooks.touchGroupContainerIfRequested()
        #endif
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
