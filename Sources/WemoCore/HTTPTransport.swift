import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int

    public init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}

/// URLSession is thread safe. This class has no mutable state after initialization.
public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession
    private let delegate: RejectRedirects

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        #if !os(Linux)
        configuration.waitsForConnectivity = false
        configuration.allowsCellularAccess = false
        #endif
        let delegate = RejectRedirects()
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    public func send(_ request: URLRequest) async throws -> HTTPResponse {
        // There is deliberately no retry loop, including for POST.
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw WemoError.nonHTTPResponse
        }
        return HTTPResponse(data: data, statusCode: response.statusCode)
    }
}

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        // Never forward control requests to a server-selected address or replay a redirected POST.
        completionHandler(nil)
    }
}
