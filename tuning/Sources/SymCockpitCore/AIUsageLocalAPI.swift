import Foundation

/// Cockpit's own, snake_case API; not OpenUsage wire compatibility.
/// GET /v1/limits[/exact-provider-id]: {schema, generated_at, providers, errors}.
/// Providers are keyed by ID and contain fetched_at, stale, and resources keyed by ID.
/// GET /v1/usage[/exact-provider-id] uses the same envelope with a `snapshots` array
/// containing provider_id, fetched_at, stale, and normalized `meters` arrays.
/// Missing values are omitted, never synthesized as zero. Currency units retain
/// their supplied code. Failures preserve cached timestamps and expose only a code.
/// Resource IDs encode the exact UTF-8 meter label, not a lossy slug. Duplicate
/// labels sort by scalar content and receive occurrence suffixes. shortcut: labels
/// (and duplicate ordinals) are identity until Brain supplies stable resource IDs;
/// a renamed label or changed duplicate ordering can therefore change an ID.
public enum AIUsageLocalAPI {
    public struct Response: Sendable {
        public let status: Int
        public let body: Data

        public func httpData() -> Data {
            let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden",
                          404: "Not Found", 405: "Method Not Allowed", 408: "Request Timeout",
                          413: "Content Too Large", 431: "Request Header Fields Too Large",
                          500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "Error"
            var header = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\n"
            header += "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
            header += "X-Content-Type-Options: nosniff\r\nCross-Origin-Resource-Policy: same-origin\r\n"
            if status == 405 { header += "Allow: GET, OPTIONS\r\n" }
            return Data((header + "\r\n").utf8) + body
        }
    }

    struct Resource: Encodable {
        let resourceId: String
        let label: String
        let kind: String
        let unit: String
        let used: Decimal?
        let limit: Decimal?
        let remaining: Decimal?
        let utilization: Decimal?
        let available: Decimal?
        let resetsAt: Date?
    }

    struct Provider: Encodable {
        let fetchedAt: Date
        let stale: Bool
        let resources: [String: Resource]
    }

    struct Failure: Encodable {
        let providerId: String
        let code: String
    }

    struct Limits: Encodable {
        let schema = "symaira.cockpit.limits.v1"
        let generatedAt: Date
        let providers: [String: Provider]
        let errors: [Failure]
    }

    struct Snapshot: Encodable {
        let providerId: String
        let fetchedAt: Date
        let stale: Bool
        let meters: [Resource]
    }

    struct Usage: Encodable {
        let schema = "symaira.cockpit.usage.v1"
        let generatedAt: Date
        let snapshots: [Snapshot]
        let errors: [Failure]
    }

    public static func error(_ status: Int, _ code: String) -> Response {
        // Codes are internal constants, not request or provider text.
        Response(status: status, body: Data("{\"error\":\"\(code)\"}".utf8))
    }

    /// Validate the entire header before reading the cache. No Origin, even
    /// `null` or a loopback origin, is allowed. Sec-Fetch headers reject browser
    /// navigations that might omit Origin. Host must name this exact listener.
    public static func route(
        header: Data, port: UInt16, now: Date = Date(),
        snapshots: () -> [AIUsageService.ProviderResult]
    ) -> Response {
        guard header.count <= 8192 else { return error(431, "headers_too_large") }
        guard let text = String(data: header, encoding: .utf8), text.hasSuffix("\r\n\r\n"),
              text.utf8.allSatisfy({ $0 == 13 || $0 == 10 || (32...126).contains($0) }) else {
            return error(400, "bad_request")
        }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard request.count == 3, request[2] == "HTTP/1.1" else { return error(400, "bad_request") }
        var fields: [String: String] = [:]
        for line in lines.dropFirst().dropLast(2) {
            guard let colon = line.firstIndex(of: ":") else { return error(400, "bad_request") }
            let name = String(line[..<colon]).lowercased()
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || $0 == 45 }),
                  fields[name] == nil else { return error(400, "bad_request") }
            fields[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard fields["origin"] == nil, !fields.keys.contains(where: { $0.hasPrefix("sec-fetch-") }),
              fields["host"] == "127.0.0.1:\(port)" else { return error(403, "forbidden") }
        guard fields["transfer-encoding"] == nil,
              fields["content-length"] == nil || fields["content-length"] == "0" else {
            return error(413, "body_not_allowed")
        }
        guard request[0] == "GET" || request[0] == "OPTIONS" else {
            return error(405, "method_not_allowed")
        }
        let parts = request[1].split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3 || parts.count == 4, parts[0].isEmpty, parts[1] == "v1",
              parts[2] == "limits" || parts[2] == "usage" else { return error(404, "not_found") }
        var filter: String?
        if parts.count == 4 {
            guard let decoded = String(parts[3]).removingPercentEncoding, !decoded.isEmpty,
                  !decoded.contains("/"), !decoded.contains("?"), !decoded.contains("#") else {
                return error(400, "bad_provider_id")
            }
            filter = decoded
        }
        if request[0] == "OPTIONS" { return Response(status: 204, body: Data()) }
        let rows = snapshots()
        guard rows.count <= 64, rows.allSatisfy({ row in
            !row.providerID.isEmpty && row.providerID.utf8.count <= 128
                && row.providerID.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
                && (row.snapshot.map { snapshot in
                snapshot.meters.count <= 128 && snapshot.meters.allSatisfy {
                    $0.label.utf8.count <= 256 && $0.unit.unitLabel.utf8.count <= 32
                } && (snapshot.currency?.utf8.count ?? 0) <= 32
            } ?? true)
        }) else { return error(503, "snapshot_too_large") }
        if let filter, !rows.contains(where: { $0.providerID == filter }) {
            return error(404, "provider_not_found")
        }
        var providers: [String: Provider] = [:]
        var failures: [Failure] = []
        // First catalog row wins if the cache accidentally supplies duplicate IDs.
        var seen = Set<String>()
        for row in rows where filter == nil || row.providerID == filter {
            guard seen.insert(row.providerID).inserted else { continue }
            if row.error != nil { failures.append(Failure(providerId: row.providerID, code: "usage_unavailable")) }
            guard let snapshot = row.snapshot, snapshot.providerID == row.providerID else { continue }
            providers[row.providerID] = Provider(
                fetchedAt: snapshot.fetchedAt,
                stale: row.error != nil || now.timeIntervalSince(snapshot.fetchedAt) >= AIUsageSnapshotCache.freshness,
                resources: resources(snapshot)
            )
        }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        do {
            let body: Data
            if parts[2] == "limits" {
                body = try encoder.encode(Limits(generatedAt: now, providers: providers, errors: failures))
            } else {
                let values = providers.keys.sorted().compactMap { id -> Snapshot? in
                    guard let provider = providers[id] else { return nil }
                    return Snapshot(providerId: id, fetchedAt: provider.fetchedAt, stale: provider.stale,
                                    meters: provider.resources.keys.sorted().compactMap { provider.resources[$0] })
                }
                body = try encoder.encode(Usage(generatedAt: now, snapshots: values, errors: failures))
            }
            guard body.count <= 1_048_576 else { return error(503, "snapshot_too_large") }
            return Response(status: 200, body: body)
        } catch { return Self.error(500, "encoding_failed") }
    }

    private static func resources(_ snapshot: AIUsageSnapshot) -> [String: Resource] {
        var result: [String: Resource] = [:]
        var occurrences: [String: Int] = [:]
        let sorted = snapshot.meters.sorted { left, right in
            let lhs = [left.label, left.unit.unitLabel, left.used?.description ?? "", left.limit?.description ?? "",
                       left.resetsAt?.timeIntervalSince1970.description ?? ""]
            let rhs = [right.label, right.unit.unitLabel, right.used?.description ?? "", right.limit?.description ?? "",
                       right.resetsAt?.timeIntervalSince1970.description ?? ""]
            return lhs.lexicographicallyPrecedes(rhs)
        }
        for meter in sorted {
            let base = Data(SecretRedactor.redact(meter.label).utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            occurrences[base, default: 0] += 1
            let id = "meter_\(base)~\(occurrences[base, default: 1])"
            let used = meter.used.flatMap { $0.isNaN ? nil : $0 }
            let limit = meter.limit.flatMap { $0.isNaN ? nil : $0 }
            guard used != nil || limit != nil else { continue }
            let bounded = used != nil && limit != nil && used! >= 0 && limit! > 0
            result[id] = Resource(
                resourceId: id, label: SecretRedactor.redact(meter.label), kind: "consumption",
                unit: meter.unit == .percent ? "percent" : SecretRedactor.redact(meter.unit.unitLabel),
                used: used, limit: limit,
                remaining: bounded ? max(0, limit! - used!) : nil,
                utilization: bounded ? min(1, used! / limit!) : nil,
                available: nil, resetsAt: meter.resetsAt
            )
        }
        if let balance = snapshot.balance, !balance.isNaN {
            result["balance"] = Resource(resourceId: "balance", label: "Balance", kind: "balance",
                                         unit: SecretRedactor.redact(snapshot.currency ?? "unknown"), used: nil, limit: nil,
                                         remaining: nil, utilization: nil, available: balance, resetsAt: nil)
        }
        return result
    }
}
