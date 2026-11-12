import Foundation

/// Tracks in-flight idempotent quota pull GETs so sentry-cocoa automatic
/// `HTTPClientError` events for retried 502/503/504 responses can be dropped,
/// leaving room for a single handled warning when retries are exhausted.
public enum QuotaClientExhaustedTransientRead: @unchecked Sendable {
  /// Called after retriable quota pull errors are exhausted.  QuotaCore stays
  /// Sentry-free; CodeCaps wires this to Sentry.
  public static var onExhausted: (@Sendable (URL, QuotaClientError) -> Void)?
}

enum QuotaClientRetryTiming {
  static var sleep: @Sendable (TimeInterval) async throws -> Void = { duration in
    let nanos = UInt64(max(0, duration) * 1_000_000_000)
    try await Task.sleep(nanoseconds: nanos)
  }
}

public enum IdempotentGETRetryFilter {
  private struct Session {
    var suppressAutomaticFailedRequestCapture: Bool
  }

  private static let lock = NSLock()
  private static var sessions: [String: Session] = [:]

  static let maxExtraRetries = 2
  static let maximumBackoffSeconds: TimeInterval = 5
  static let defaultBackoffSeconds: TimeInterval = 0.35

  public static func beginFetch(endpoint: URL) {
    lock.lock()
    sessions[endpoint.absoluteString] = Session(suppressAutomaticFailedRequestCapture: true)
    lock.unlock()
  }

  public static func endFetch(endpoint: URL) {
    lock.lock()
    sessions.removeValue(forKey: endpoint.absoluteString)
    lock.unlock()
  }

  public static func allowAutomaticFailedRequestCapture(endpoint: URL) {
    endFetch(endpoint: endpoint)
  }

  public static func notifyExhausted(endpoint: URL, error: QuotaClientError) {
    QuotaClientExhaustedTransientRead.onExhausted?(endpoint, error)
    // sentry-cocoa may deliver the final automatic failed-request capture
    // after this fetch returns; keep suppression briefly so it is still dropped.
    Task {
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      endFetch(endpoint: endpoint)
    }
  }

  /// Whether sentry-cocoa's automatic failed-request capture for an idempotent
  /// quota GET should be dropped (per-attempt 502/503/504 while this client
  /// still owns the fetch).
  public static func shouldSuppressAutomaticFailedRequest(
    url: String?,
    httpMethod: String?,
    exceptionTypes: [String],
    exceptionValues: [String]
  ) -> Bool {
    guard exceptionTypes.contains("HTTPClientError"),
          httpMethod?.uppercased() == "GET",
          let url,
          let parsed = URL(string: url),
          QuotaClient.isAllowedEndpoint(parsed),
          let status = parseHTTPClientErrorStatus(from: exceptionValues),
          isRetriableHTTPStatus(status)
    else { return false }

    lock.lock()
    let suppress = sessions[url]?.suppressAutomaticFailedRequestCapture ?? false
    lock.unlock()
    return suppress
  }

  public static func isRetriableHTTPStatus(_ status: Int) -> Bool {
    status == 502 || status == 503 || status == 504
  }

  static func isRetriableTransport(_ error: URLError) -> Bool {
    switch error.code {
    case .timedOut,
         .networkConnectionLost,
         .notConnectedToInternet,
         .cannotConnectToHost,
         .cannotFindHost,
         .dnsLookupFailed,
         .secureConnectionFailed,
         .dataNotAllowed:
      return true
    default:
      return false
    }
  }

  static func isTransientPullFailure(_ error: Error) -> Bool {
    switch error {
    case let client as QuotaClientError:
      switch client {
      case .timedOut, .transport:
        return true
      case let .httpStatus(status):
        return isRetriableHTTPStatus(status)
      case .invalidEndpoint, .invalidToken, .unauthorized, .responseTooLarge, .malformedResponse:
        return false
      }
    case let urlError as URLError:
      return isRetriableTransport(urlError)
    default:
      return false
    }
  }

  /// After `QuotaClient` exhausts retries, hide the pull error banner only for
  /// gateway-style 5xx responses (the CODECAPS-3 class).  Transport and timeout
  /// failures still surface so a dead endpoint does not look healthy.
  public static func preservesLastGoodFleetOnPullFailure(_ error: Error) -> Bool {
    guard let client = error as? QuotaClientError,
          case let .httpStatus(status) = client else { return false }
    return isRetriableHTTPStatus(status)
  }

  public static func backoffDelay(attemptIndex: Int, retryAfter header: String?) -> TimeInterval {
    if let header {
      let trimmed = header.trimmingCharacters(in: .whitespaces)
      if let seconds = TimeInterval(trimmed) {
        return min(max(0, seconds), maximumBackoffSeconds)
      }
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
      if let date = formatter.date(from: trimmed) {
        return min(max(0, date.timeIntervalSinceNow), maximumBackoffSeconds)
      }
    }
    let scaled = defaultBackoffSeconds * Double(attemptIndex)
    return min(scaled, maximumBackoffSeconds)
  }

  public static func parseHTTPClientErrorStatus(from exceptionValues: [String]) -> Int? {
    for value in exceptionValues {
      if let status = firstHTTPStatus(in: value) { return status }
    }
    return nil
  }

  public static func firstHTTPStatus(in text: String) -> Int? {
    let pattern = #"status code:\s*(\d{3})"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text),
          let status = Int(text[range]) else { return nil }
    return status
  }
}

extension QuotaClientError {
  public static func isTransientPullFailure(_ error: Error) -> Bool {
    IdempotentGETRetryFilter.isTransientPullFailure(error)
  }
}
