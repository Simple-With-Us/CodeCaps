import Foundation
import Sentry

/// Native Sentry crash reporting and telemetry for the CodeCaps companion
/// (iOS phone app and Mac App Store companion).
///
/// DSN is read only from Info.plist (`SENTRY_DSN`).  There is no hardcoded
/// fallback — missing, empty, or an unsubstituted `$(SENTRY_DSN)` skips init
/// so a Simulator or CI archive cut without secrets stays inert.
///
/// Ship/CI injects Infisical `SENTRY_DSN` into the `SENTRY_DSN` xcodebuild
/// setting.  Do not put a live DSN in git, `project.yml`, or Info.plist.
/// Session Replay is iOS-only in sentry-cocoa; the Mac companion sends
/// crashes, hangs, traces and profiles.
enum SentryTelemetry {
    static func start() {
        guard let dsn = resolvedDSN() else { return }

        let isDebug: Bool = {
#if DEBUG
            return true
#else
            return false
#endif
        }()

        SentrySDK.start { options in
            options.dsn = dsn
            options.environment = isDebug ? "development" : "production"
            options.tracesSampleRate = 0.2
            // sentry-cocoa 9 removed transaction-based profilesSampleRate.
            options.configureProfiling = {
                $0.sessionSampleRate = 0.1
                $0.lifecycle = .trace
            }
            options.enableAppHangTracking = true
            options.appHangTimeoutInterval = 2.0
            options.enableCaptureFailedRequests = true
            options.failedRequestStatusCodes = [HttpStatusCodeRange(min: 500, max: 599)]
            options.sendDefaultPii = false
#if os(iOS)
            options.attachScreenshot = false
            options.attachViewHierarchy = false
            options.sessionReplay.sessionSampleRate = 0.1
            options.sessionReplay.onErrorSampleRate = 0.1
            options.sessionReplay.maskAllText = true
            options.sessionReplay.maskAllImages = true
#endif
            options.beforeSend = { event in
                sanitize(event)
            }
        }
    }

    /// DSN resolution only.  An unsubstituted `$(SENTRY_DSN)` counts as missing.
    static func resolvedDSN(
        plistValue: String? = Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String
    ) -> String? {
        guard let trimmed = plistValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    private static func sanitize(_ event: Event) -> Event? {
        guard let request = event.request, let url = request.url else { return event }
        var sanitized = url
        for param in ["token", "key", "secret", "auth", "password"] {
            sanitized = sanitized.replacingOccurrences(
                of: "([?&]\(param)=)[^&#\\s]+",
                with: "$1[REDACTED]",
                options: .regularExpression
            )
        }
        request.url = sanitized
        return event
    }
}
