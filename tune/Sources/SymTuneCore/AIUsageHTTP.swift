import Foundation

// MARK: - Shared error

/// Shared error for the AI usage providers' HTTP layer.
///
/// The response body is deliberately **never** carried in any error: a
/// gateway error page can echo the request headers back (including a
/// provider's API key), so surfacing only a status code / generic
/// description is the safe default (issue #316).
public enum AIUsageHTTPError: Error, LocalizedError, Sendable {
    case network(String)
    case invalidResponse
    case httpStatus(Int)
    case unparseable

    public var errorDescription: String? {
        switch self {
        case .network(let detail):
            return "AI usage request failed: \(detail)"
        case .invalidResponse:
            return "AI usage provider returned an invalid response."
        case .httpStatus(let code):
            return "AI usage request failed with HTTP \(code)."
        case .unparseable:
            return "AI usage provider returned an unreadable response."
        }
    }
}

// MARK: - Shared HTTP layer

/// Shared HTTP execution + status mapping + decoding for the AI usage
/// providers (issue #316).
///
/// Each provider keeps responsibility for building its own request (URL,
/// method, auth/custom headers, body) and for turning the decoded payload
/// into meters. This helper owns the cross-cutting policy, written once:
///
/// - **Header defaults** — attaches `Accept: application/json` when the
///   request does not already set it.
/// - **Status mapping** — `401`/`403` → `AIUsageError.notConfigured`,
///   `429` → `AIUsageError.rateLimited` (with `Retry-After` parsing), and
///   every other non-2xx → `AIUsageHTTPError.httpStatus`.
/// - **Body-free errors** — the response body is never placed in an error
///   (a gateway error page can echo the request headers, including a key).
/// - **Decoding** — `convertFromSnakeCase` keys (with ISO8601 dates).
public enum AIUsageHTTP {
    /// Performs `request` via `network`, maps the HTTP status, and decodes
    /// the 2xx body as `T`. Request construction (URL, method, auth headers)
    /// stays with the caller.
    public static func json<T: Decodable>(
        _ request: URLRequest,
        as type: T.Type,
        providerID: String,
        network: any NetworkServiceProtocol
    ) async throws -> T {
        var request = request
        // Common default headers (idempotent; providers may already set it).
        if request.value(forHTTPHeaderField: "Accept") == nil {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await network.fetchData(from: request)
        } catch {
            throw AIUsageHTTPError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AIUsageHTTPError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            switch http.statusCode {
            case 401, 403:
                throw AIUsageError.notConfigured(providerID)
            case 429:
                throw AIUsageError.rateLimited(providerID, retryAfter: retryAfterSeconds(from: http))
            default:
                throw AIUsageHTTPError.httpStatus(http.statusCode)
            }
        }

        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(T.self, from: data)
        } catch {
            throw AIUsageHTTPError.unparseable
        }
    }

    /// Parses the `Retry-After` header's delta-seconds form (e.g. `"30"`);
    /// `nil` when the header is absent or not a plain integer/decimal — the
    /// HTTP-date form is not handled since 429 responses conventionally use
    /// delta-seconds.
    private static func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        return TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
