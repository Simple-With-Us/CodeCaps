import Foundation

/// Performs the optional iOS widget refresh without exposing a bearer token to
/// a redirected origin or allowing an unbounded request to stall a timeline.
public enum WidgetSnapshotFetcher {
    public enum FetchError: Error, Equatable {
        case invalidHTTPSURL
        case invalidToken
        case nonHTTPResponse
        case unacceptableStatus(Int)
        case responseTooLarge
    }

    private static let maximumResponseBytes = 1 * 1_024 * 1_024
    private static let requestTimeout: TimeInterval = 10
    private static let resourceTimeout: TimeInterval = 15

    public static func fetch(
        endpoint: String,
        bearerToken: String,
        configuration: URLSessionConfiguration = .ephemeral
    ) async throws -> Data {
        guard let url = URL(string: endpoint),
              Self.isAllowedEndpoint(url) else {
            throw FetchError.invalidHTTPSURL
        }
        let token = Self.sanitizedToken(bearerToken)
        guard !token.contains("\r"), !token.contains("\n") else {
            throw FetchError.invalidToken
        }

        var config = configuration
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        if !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        return try await BoundedHTTPSRequest(
            origin: url,
            maximumResponseBytes: maximumResponseBytes
        ).perform(request, configuration: config)
    }

    /// HTTPS anywhere, or HTTP only on a loopback host (the same rule
    /// `QuotaClient.isAllowedEndpoint` applies).  Userinfo, query and
    /// fragment are refused so a pasted endpoint cannot smuggle a second
    /// authority or credentials past the check.
    static func isAllowedEndpoint(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return false }
        if scheme == "https" { return true }
        let loopback = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
        return scheme == "http" && loopback
    }

    /// Local copy of the token cleanup in `TokenHygiene.swift`: this file is
    /// compiled on its own into the widget and companion targets, which do
    /// not link that file.
    static func sanitizedToken(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.count >= 2, let first = value.first, let last = value.last,
              first == last, first == "\"" || first == "'" {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }
}

private final class BoundedHTTPSRequest: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let origin: URL
    private let maximumResponseBytes: Int
    private var responseData = Data()
    private var responseError: Error?
    private var continuation: CheckedContinuation<Data, Error>?
    private var session: URLSession?

    init(origin: URL, maximumResponseBytes: Int) {
        self.origin = origin
        self.maximumResponseBytes = maximumResponseBytes
    }

    func perform(_ request: URLRequest, configuration: URLSessionConfiguration) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            responseError = WidgetSnapshotFetcher.FetchError.nonHTTPResponse
            completionHandler(.cancel)
            return
        }
        guard (200...299).contains(response.statusCode) else {
            responseError = WidgetSnapshotFetcher.FetchError.unacceptableStatus(response.statusCode)
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(maximumResponseBytes) {
            responseError = WidgetSnapshotFetcher.FetchError.responseTooLarge
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard responseError == nil else { return }
        guard data.count <= maximumResponseBytes - responseData.count else {
            responseError = WidgetSnapshotFetcher.FetchError.responseTooLarge
            dataTask.cancel()
            return
        }
        responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let continuation = self.continuation
        self.continuation = nil
        self.session?.finishTasksAndInvalidate()
        self.session = nil
        if let responseError {
            continuation?.resume(throwing: responseError)
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: responseData)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let destination = request.url,
              destination.user == nil, destination.password == nil,
              Self.hasSameOrigin(origin, destination) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func hasSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsScheme = lhs.scheme?.lowercased()
        let rhsScheme = rhs.scheme?.lowercased()
        let defaultPort = lhsScheme == "https" ? 443 : 80
        return lhsScheme != nil
            && lhsScheme == rhsScheme
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? defaultPort) == (rhs.port ?? defaultPort)
    }
}
