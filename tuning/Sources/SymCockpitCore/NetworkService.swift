import Foundation

/// Protocol abstracting network operations for testability.
public protocol NetworkServiceProtocol: Sendable {
    /// Fetches data from a URL.
    func fetchData(from url: URL) async throws -> (Data, URLResponse)

    /// Fetches data for a full request (method, headers, body).
    func fetchData(from request: URLRequest) async throws -> (Data, URLResponse)
}

public extension NetworkServiceProtocol {
    /// Default implementation so existing conformers keep compiling: builds a
    /// plain GET request and delegates to the URL-based method.
    func fetchData(from request: URLRequest) async throws -> (Data, URLResponse) {
        try await fetchData(from: request.url!)
    }
}

/// Production implementation using URLSession.
public struct URLSessionNetworkService: NetworkServiceProtocol {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchData(from url: URL) async throws -> (Data, URLResponse) {
        try await session.data(from: url)
    }

    public func fetchData(from request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}
