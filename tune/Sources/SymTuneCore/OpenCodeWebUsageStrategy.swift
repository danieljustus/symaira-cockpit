import Foundation

// MARK: - Web strategy

/// Fetches OpenCode Go quota from the opencode.ai web dashboard.
///
/// `GET`/`POST https://opencode.ai/_server` with server-function IDs and the
/// opencode.ai session cookie. Responses are `text/javascript` with
/// serialized objects — parsed as JSON when possible, else via regex.
public struct OpenCodeWebStrategy: AIUsageStrategy, Sendable {
    public let source = "web"

    private static let baseURL = URL(string: "https://opencode.ai")!
    private static let serverURL = URL(string: "https://opencode.ai/_server")!
    private static let workspacesServerID = "def39973159c7f0483d8793a822b8dbb10d067e12c65455fcb4608459ba0234f"
    private static let subscriptionServerID = "7abeebee372f304e050aaaf92be863f4a86490e382f8c79db68fd94040d691b4"
    private static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private let cookieHeader: String
    private let workspaceOverride: String?
    private let network: any NetworkServiceProtocol

    public init(
        cookieHeader: String,
        workspaceOverride: String?,
        network: any NetworkServiceProtocol
    ) {
        self.cookieHeader = cookieHeader
        self.workspaceOverride = workspaceOverride
        self.network = network
    }

    public func fetch() async throws -> AIUsageSnapshot {
        let workspaceID: String
        if let override = Self.normalizeWorkspaceID(workspaceOverride) {
            workspaceID = override
        } else {
            workspaceID = try await fetchWorkspaceID()
        }
        let text = try await fetchSubscriptionInfo(workspaceID: workspaceID)
        return try Self.parseSubscription(text: text, now: Date())
    }

    /// Accepts a raw `wrk_…` ID, a full `https://opencode.ai/workspace/…`
    /// URL, or any text containing a `wrk_…` ID.
    static func normalizeWorkspaceID(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("wrk_"), trimmed.count > 4 {
            return trimmed
        }
        if let url = URL(string: trimmed) {
            let parts = url.pathComponents
            if let index = parts.firstIndex(of: "workspace"), parts.count > index + 1 {
                let candidate = parts[index + 1]
                if candidate.hasPrefix("wrk_"), candidate.count > 4 {
                    return candidate
                }
            }
        }
        if let match = trimmed.range(of: #"wrk_[A-Za-z0-9]+"#, options: .regularExpression) {
            return String(trimmed[match])
        }
        return nil
    }

    // MARK: Server calls

    private func fetchWorkspaceID() async throws -> String {
        let text = try await serverText(
            serverID: Self.workspacesServerID,
            args: nil,
            method: "GET",
            referer: Self.baseURL
        )
        try Self.throwIfSignedOut(text: text)
        if let id = Self.parseWorkspaceID(text: text) {
            return id
        }
        let fallback = try await serverText(
            serverID: Self.workspacesServerID,
            args: [],
            method: "POST",
            referer: Self.baseURL
        )
        try Self.throwIfSignedOut(text: fallback)
        if let id = Self.parseWorkspaceID(text: fallback) {
            return id
        }
        throw OpenCodeError.parseFailed("Missing workspace id.")
    }

    private func fetchSubscriptionInfo(workspaceID: String) async throws -> String {
        let referer = URL(string: "https://opencode.ai/workspace/\(workspaceID)/billing") ?? Self.baseURL
        let text = try await serverText(
            serverID: Self.subscriptionServerID,
            args: [workspaceID],
            method: "GET",
            referer: referer
        )
        try Self.throwIfSignedOut(text: text)
        if (try? Self.parseSubscription(text: text, now: Date())) != nil {
            return text
        }
        let fallback = try await serverText(
            serverID: Self.subscriptionServerID,
            args: [workspaceID],
            method: "POST",
            referer: referer
        )
        try Self.throwIfSignedOut(text: fallback)
        return fallback
    }

    private func serverText(
        serverID: String,
        args: [Any]?,
        method: String,
        referer: URL
    ) async throws -> String {
        let url: URL
        var request: URLRequest
        if method.uppercased() == "GET" {
            var components = URLComponents(url: Self.serverURL, resolvingAgainstBaseURL: false)!
            var queryItems = [URLQueryItem(name: "id", value: serverID)]
            if let args, !args.isEmpty,
               let data = try? JSONSerialization.data(withJSONObject: args),
               let encoded = String(bytes: data, encoding: .utf8) {
                queryItems.append(URLQueryItem(name: "args", value: encoded))
            }
            components.queryItems = queryItems
            url = components.url ?? Self.serverURL
            request = URLRequest(url: url)
            request.httpMethod = "GET"
        } else {
            url = Self.serverURL
            request = URLRequest(url: url)
            request.httpMethod = "POST"
            if let args {
                request.httpBody = try JSONSerialization.data(withJSONObject: args)
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
        }
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.setValue(serverID, forHTTPHeaderField: "X-Server-Id")
        request.setValue("server-fn:\(UUID().uuidString)", forHTTPHeaderField: "X-Server-Instance")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.baseURL.absoluteString, forHTTPHeaderField: "Origin")
        request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("text/javascript, application/json;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await network.fetchData(from: request)
        } catch {
            throw OpenCodeError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpenCodeError.network("invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(bytes: data, encoding: .utf8) ?? ""
            if http.statusCode == 401 || http.statusCode == 403 || Self.looksSignedOut(text: body) {
                throw OpenCodeError.invalidCredentials
            }
            throw OpenCodeError.apiError("HTTP \(http.statusCode)")
        }
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw OpenCodeError.parseFailed("Response was not UTF-8")
        }
        return text
    }

    private static func throwIfSignedOut(text: String) throws {
        if looksSignedOut(text: text) {
            throw OpenCodeError.invalidCredentials
        }
    }

    /// Crude signed-out detection: sign-in prompts or auth errors in the
    /// serialized payload mean the cookie is stale.
    static func looksSignedOut(text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("sign in") || lower.contains("unauthorized") || lower.contains("not authenticated")
    }

    // MARK: Parsing

    static func parseWorkspaceID(text: String) -> String? {
        let pattern = #"wrk_[A-Za-z0-9]+"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                  in: text,
                  range: NSRange(text.startIndex..., in: text)
              ),
              let range = Range(match.range, in: text)
        else { return nil }
        return String(text[range])
    }

    /// JSON first (serialized objects may be valid JSON), regex fallback for
    /// JS-literal payloads with unquoted keys.
    static func parseSubscription(text: String, now: Date) throws -> AIUsageSnapshot {
        if let snapshot = parseSubscriptionJSON(text: text, now: now) {
            return snapshot
        }
        return try parseSubscriptionRegex(text: text, now: now)
    }

    private static func parseSubscriptionJSON(text: String, now: Date) -> AIUsageSnapshot? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        var windows: [(percent: Double, resetInSec: Double?)] = []
        collectUsageWindows(in: object, into: &windows)
        guard let rolling = windows.first else { return nil }
        return makeSnapshot(rolling: rolling, weekly: windows.count > 1 ? windows[1] : nil, now: now)
    }

    /// Recursively collects dicts that carry a usage-percent field plus a
    /// reset field. Named windows (`rollingUsage`, `weeklyUsage`) are
    /// traversed in a fixed order because `Dictionary` iteration order is
    /// unspecified; the first collected window is the rolling one.
    private static func collectUsageWindows(in object: Any, into windows: inout [(percent: Double, resetInSec: Double?)]) {
        guard let dict = object as? [String: Any] else {
            if let array = object as? [Any] {
                for value in array {
                    collectUsageWindows(in: value, into: &windows)
                }
            }
            return
        }
        let named = ["rollingUsage", "weeklyUsage", "usage", "billing", "data", "result"].compactMap { dict[$0] }
        if !named.isEmpty {
            for value in named {
                collectUsageWindows(in: value, into: &windows)
            }
            return
        }
        if let percent = usagePercent(in: dict) {
            windows.append((percent: percent, resetInSec: resetSeconds(in: dict)))
        }
        for value in dict.values {
            collectUsageWindows(in: value, into: &windows)
        }
    }

    private static func usagePercent(in dict: [String: Any]) -> Double? {
        for key in ["usagePercent", "usedPercent", "percentUsed", "percent", "usage_percent", "utilization", "usage"] {
            if let value = dict[key] as? NSNumber {
                return value.doubleValue
            }
        }
        return nil
    }

    private static func resetSeconds(in dict: [String: Any]) -> Double? {
        for key in ["resetInSec", "resetInSeconds", "reset_sec", "resetsInSec", "resetIn", "resetSec"] {
            if let value = dict[key] as? NSNumber {
                return value.doubleValue
            }
        }
        return nil
    }

    private static func parseSubscriptionRegex(text: String, now: Date) throws -> AIUsageSnapshot {
        let percentPattern = #"(usagePercent|usedPercent|percentUsed|percent)\s*:\s*([0-9]+(?:\.[0-9]+)?)"#
        let resetPattern = #"(resetInSec|resetSeconds|resetIn)\s*:\s*([0-9]+)"#
        guard let rollingPercent = extractDouble(pattern: #"rollingUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text)
                ?? extractDouble(pattern: percentPattern, text: text),
              let rollingReset = extractInt(pattern: #"rollingUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text)
                ?? extractInt(pattern: resetPattern, text: text)
        else {
            throw OpenCodeError.parseFailed("Missing usage fields.")
        }
        let weeklyPercent = extractDouble(pattern: #"weeklyUsage[^}]*?usagePercent\s*:\s*([0-9]+(?:\.[0-9]+)?)"#, text: text)
        let weeklyReset = extractInt(pattern: #"weeklyUsage[^}]*?resetInSec\s*:\s*([0-9]+)"#, text: text)
        let weekly: (percent: Double, resetInSec: Double?)? = weeklyPercent.map { ($0, weeklyReset.map(Double.init)) }
        return makeSnapshot(rolling: (rollingPercent, Double(rollingReset)), weekly: weekly, now: now)
    }

    private static func extractDouble(pattern: String, text: String) -> Double? {
        extract(pattern: pattern, text: text).flatMap(Double.init)
    }

    private static func extractInt(pattern: String, text: String) -> Int? {
        extract(pattern: pattern, text: text).flatMap(Int.init)
    }

    private static func extract(pattern: String, text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    private static func makeSnapshot(
        rolling: (percent: Double, resetInSec: Double?),
        weekly: (percent: Double, resetInSec: Double?)?,
        now: Date
    ) -> AIUsageSnapshot {
        var meters: [AIUsageMeter] = []
        meters.append(AIUsageMeter(
            label: "5h window",
            used: Decimal(min(100, max(0, rolling.percent))),
            limit: 100,
            unit: .percent,
            resetsAt: rolling.resetInSec.map { now.addingTimeInterval($0) }
        ))
        if let weekly {
            meters.append(AIUsageMeter(
                label: "This week",
                used: Decimal(min(100, max(0, weekly.percent))),
                limit: 100,
                unit: .percent,
                resetsAt: weekly.resetInSec.map { now.addingTimeInterval($0) }
            ))
        }
        return AIUsageSnapshot(
            providerID: "opencode",
            meters: meters,
            balance: nil,
            currency: nil,
            fetchedAt: now,
            source: "web"
        )
    }
}
