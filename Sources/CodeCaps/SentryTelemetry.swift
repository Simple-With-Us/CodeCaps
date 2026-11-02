import Foundation
import Sentry

/// Native Sentry crash reporting and telemetry for the CodeCaps Mac menu-bar app.
///
/// DSN resolution order: the `SENTRY_DSN` environment variable first (so a
/// rehearsal can point a build at another project without rebuilding), then
/// the bundled Info.plist `SENTRY_DSN` key, which `script/build_and_run.sh`
/// bakes in from the same-named build environment variable on release builds.
/// There is no hardcoded fallback — missing or empty everywhere skips init,
/// so dev builds and CI archives cut without a DSN stay inert instead of
/// phoning the wrong project.
///
/// Session Replay and screenshots are iOS-only in sentry-cocoa, so the Mac
/// app sends crashes, hangs, traces and profiles only.  `sendDefaultPii` is
/// off and credential-like query parameters are redacted on-device before an
/// event leaves the Mac.
enum SentryTelemetry {
    static func start(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let dsn = resolvedDSN(environment: environment) else { return }
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
            options.beforeSend = { event in
                if isThirdPartyFailedRequest(
                    url: event.request?.url,
                    exceptionTypes: event.exceptions?.map(\.type) ?? []
                ) { return nil }
                return sanitize(event)
            }
        }
    }

    /// DSN resolution only, factored out so tests can pin it without starting
    /// the SDK.  An unsubstituted `$(SENTRY_DSN)` build-setting expansion
    /// counts as missing.
    static func resolvedDSN(
        environment: [String: String],
        plistValue: String? = Bundle.main.object(forInfoDictionaryKey: "SENTRY_DSN") as? String
    ) -> String? {
        if let fromEnv = usableDSN(environment["SENTRY_DSN"]) {
            return fromEnv
        }
        return usableDSN(plistValue)
    }

    static func usableDSN(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              !trimmed.hasPrefix("$(") else { return nil }
        return trimmed
    }

    /// Provider APIs the quota readers call.  A 5xx from one of them is that
    /// provider's outage, which CodeCaps already shows as a missing reading, so
    /// it is not reported as a CodeCaps error.  Our own hosts, including a
    /// user-configured Usage Monitor endpoint, are still captured.  BOTFLEET-2Z
    /// was about 960 of these from api2.cursor.sh alone.
    static let thirdPartyProviderHostSuffixes: [String] = [
        "cursor.sh", "cursor.com", "anthropic.com", "openai.com", "chatgpt.com",
        "x.ai", "grok.com", "minimax.io", "minimaxi.com"
    ]

    /// Whether an event is sentry-cocoa's automatic failed-request capture of a
    /// third-party provider API.  Pure, so tests can pin it without the SDK.
    static func isThirdPartyFailedRequest(url: String?, exceptionTypes: [String]) -> Bool {
        guard exceptionTypes.contains("HTTPClientError"),
              let url, let host = URL(string: url)?.host?.lowercased() else { return false }
        return thirdPartyProviderHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
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
