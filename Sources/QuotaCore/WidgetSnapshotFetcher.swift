import Foundation

/// Performs the optional iOS widget refresh without exposing a bearer token to
/// a redirected origin or allowing an unbounded request to stall a timeline.
public enum WidgetSnapshotFetcher {
    public enum FetchError: Error, Equatable {
        case invalidHTTPSURL
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
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else {
            throw FetchError.invalidHTTPSURL
        }

        var config = configuration
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.httpMethod = "GET"
        if !bearerToken.isEmpty {
            request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        }

        return try await BoundedHTTPSRequest(
            origin: url,
            maximumResponseBytes: maximumResponseBytes
        ).perform(request, configuration: config)
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
              destination.scheme?.lowercased() == "https",
              destination.user == nil, destination.password == nil,
              Self.hasSameOrigin(origin, destination) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func hasSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsPort = lhs.port ?? 443
        let rhsPort = rhs.port ?? 443
        return lhs.scheme?.lowercased() == "https"
            && rhs.scheme?.lowercased() == "https"
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && lhsPort == rhsPort
    }
}
