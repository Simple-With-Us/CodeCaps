import Foundation

/// The one bounded HTTP round trip behind the local readers' production transports.
///
/// Each reader used to stream `URLSession.AsyncBytes` one byte at a time into
/// a `Data` value. The payloads are kilobytes, so the per-byte suspension and
/// resume overhead bought nothing over a single `data(for:)`.
///
/// The contract is unchanged: an ephemeral session with no cookies, no cache
/// and no redirects; the caller's timeout; a hard byte cap; cooperative
/// cancellation still surfaces as `CancellationError` so readers keep their
/// "refresh was cancelled" wording. Redirects are refused, and a 3xx that
/// proves one was refused is a transport failure — every reader already maps
/// non-2xx to unavailable, so nothing downstream changes.
///
/// `QuotaClient` keeps its own chunked collector on purpose: it fetches from a
/// user-configured endpoint, while these readers only ever talk to vendor
/// endpoints and loopback, so a post-read size check plus the timeout is
/// enough here.
enum BoundedHTTPFetch {
    /// A fetch that never produced a usable body.
    enum Failure: Error, Equatable, Sendable {
        /// The body exceeded `maxBytes`.
        case tooLarge
        /// No HTTP response, a refused redirect, a timeout, or a connect failure.
        case transport
    }

    /// Performs `request` and returns its body with the HTTP response.
    ///
    /// - Throws: `Failure.tooLarge`, `Failure.transport`, or `CancellationError`.
    static func data(
        for request: URLRequest,
        timeout: TimeInterval,
        maxBytes: Int,
        delegate: (any URLSessionDelegate)? = nil,
        protocolClasses: [AnyClass]? = nil
    ) async throws -> (Data, HTTPURLResponse) {
        var request = request
        request.timeoutInterval = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        let session = URLSession(configuration: configuration, delegate: delegate ?? sharedNoRedirects, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw Failure.transport }
            // A redirect was refused to get here (see `NoRedirects`), so a
            // 3xx is proof of one, not a usable answer.
            if (300..<400).contains(http.statusCode) { throw Failure.transport }
            guard data.count <= maxBytes else { throw Failure.tooLarge }
            return (data, http)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure.transport
        }
    }

    private static let sharedNoRedirects: NoRedirects = NoRedirects()
}

/// The redirect-refusing task delegate. One shared type replaces the four
/// identical private delegates the readers each carried.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
