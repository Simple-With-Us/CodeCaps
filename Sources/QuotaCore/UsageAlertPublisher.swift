import Foundation

/// Alert signals travel separately from the strict v2 quota telemetry envelope.
public actor UsageAlertPublisher {
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }

    public static func endpoint(for quotaEndpoint: URL) -> URL? {
        guard var parts = URLComponents(url: quotaEndpoint, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.host != nil,
              parts.user == nil, parts.password == nil else { return nil }
        parts.path = "/api/codecaps/push/alerts"
        parts.query = nil
        parts.fragment = nil
        return parts.url
    }

    public func publish(_ alerts: [LocalQuotaSnapshot.AlertPayload], quotaEndpoint: URL,
                        token: String, now: Date = Date()) async throws {
        guard let url = Self.endpoint(for: quotaEndpoint), !token.isEmpty else {
            throw QuotaPublisherError.invalidEndpoint
        }
        let formatter = ISO8601DateFormatter()
        let fresh = alerts.filter {
            guard UsageAlertKind(rawValue: $0.kind) != nil,
                  let date = formatter.date(from: $0.occurredAt) else { return false }
            let age = now.timeIntervalSince(date)
            return age >= -60 && age <= 15 * 60
        }
        guard !fresh.isEmpty else { return }
        struct Envelope: Encodable { let alerts: [LocalQuotaSnapshot.AlertPayload] }
        for offset in stride(from: 0, to: fresh.count, by: 50) {
            try Task.checkCancellation()
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(Envelope(alerts: Array(fresh[offset..<min(offset + 50, fresh.count)])))
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw QuotaPublisherError.transport("Invalid response.") }
            guard (200..<300).contains(http.statusCode) else { throw QuotaPublisherError.httpStatus(http.statusCode, nil) }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["ok"] as? Bool == true,
                  (json["failed"] as? Int ?? 0) == 0 else {
                throw QuotaPublisherError.serverError("Push alerts were not acknowledged.")
            }
        }
    }
}
