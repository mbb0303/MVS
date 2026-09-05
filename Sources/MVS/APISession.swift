import Foundation

enum APISession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration, delegate: SameOriginRedirects(), delegateQueue: nil)
    }()
}

private final class SameOriginRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let original = task.originalRequest?.url, let next = request.url,
              next.scheme == "https", original.host == next.host, original.port == next.port else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
