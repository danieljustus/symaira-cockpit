import Foundation

// MARK: - Antigravity response parsing

/// Parsers for the three local language-server endpoints.
enum AntigravityParsing {
    /// Dispatch by endpoint name (used by the strategy's fallback chain).
    static func snapshot(forMethod method: String, data: Data, providerID: String, source: String) throws -> AIUsageSnapshot {
        switch method {
        case "RetrieveUserQuotaSummary":
            return try quotaSummarySnapshot(data: data, providerID: providerID, source: source)
        case "GetUserStatus":
            return try userStatusSnapshot(data: data, providerID: providerID, source: source)
        default:
            return try modelConfigsSnapshot(data: data, providerID: providerID, source: source)
        }
    }

    /// `RetrieveUserQuotaSummary`: quota groups with named buckets
    /// (e.g. "Gemini Models" / "Claude and GPT models", each with weekly and
    /// five-hour buckets). Each bucket's `remainingFraction` maps to a
    /// percent meter.
    static func quotaSummarySnapshot(data: Data, providerID: String, source: String) throws -> AIUsageSnapshot {
        let payload: AntigravityQuotaSummaryEnvelope
        do {
            payload = try JSONDecoder().decode(AntigravityQuotaSummaryEnvelope.self, from: data)
        } catch {
            throw AntigravityError.parseFailed("quota summary is not JSON")
        }
        guard payload.code.isOK else {
            throw AntigravityError.parseFailed("quota summary rejected: \(payload.message ?? "unknown code")")
        }
        let summary = payload.response ?? payload.summary ?? payload.rootPayload
        guard let summary, !summary.groups.isEmpty else {
            throw AntigravityError.parseFailed("missing quota groups")
        }

        var meters: [AIUsageMeter] = []
        for group in summary.groups {
            for bucket in group.buckets ?? [] {
                guard let remaining = bucket.remainingFraction, remaining >= 0, remaining <= 1 else { continue }
                let bucketLabel = bucket.displayLabel.isEmpty ? group.displayName : bucket.displayLabel
                meters.append(AIUsageMeter(
                    label: "\(group.displayName) — \(bucketLabel)",
                    // Whole percent: the raw fraction math carries binary
                    // floating-point noise (58.000…1).
                    used: Decimal(((1 - remaining) * 100).rounded()),
                    limit: 100,
                    unit: .percent,
                    resetsAt: bucket.resetTime.flatMap(AntigravityParsing.parseResetTime)
                ))
            }
        }
        guard !meters.isEmpty else {
            throw AntigravityError.parseFailed("quota summary has no usable buckets")
        }
        return AIUsageSnapshot(
            providerID: providerID,
            meters: meters,
            balance: nil,
            currency: nil,
            fetchedAt: Date(),
            source: source
        )
    }

    /// `GetUserStatus`: plan plus per-model `quotaInfo` buckets.
    static func userStatusSnapshot(data: Data, providerID: String, source: String) throws -> AIUsageSnapshot {
        let payload: AntigravityUserStatusResponse
        do {
            payload = try JSONDecoder().decode(AntigravityUserStatusResponse.self, from: data)
        } catch {
            throw AntigravityError.parseFailed("user status is not JSON")
        }
        guard payload.code.isOK else {
            throw AntigravityError.parseFailed("user status rejected: \(payload.message ?? "unknown code")")
        }
        let configs = payload.userStatus?.cascadeModelConfigData?.clientModelConfigs ?? []
        let meters = modelConfigMeters(configs)
        guard !meters.isEmpty else {
            throw AntigravityError.parseFailed("user status has no quota buckets")
        }
        return AIUsageSnapshot(
            providerID: providerID,
            meters: meters,
            balance: nil,
            currency: nil,
            fetchedAt: Date(),
            source: source
        )
    }

    /// `GetCommandModelConfigs`: per-model `quotaInfo` buckets.
    static func modelConfigsSnapshot(data: Data, providerID: String, source: String) throws -> AIUsageSnapshot {
        let payload: AntigravityModelConfigResponse
        do {
            payload = try JSONDecoder().decode(AntigravityModelConfigResponse.self, from: data)
        } catch {
            throw AntigravityError.parseFailed("model configs are not JSON")
        }
        guard payload.code.isOK else {
            throw AntigravityError.parseFailed("model configs rejected: \(payload.message ?? "unknown code")")
        }
        let meters = modelConfigMeters(payload.clientModelConfigs ?? [])
        guard !meters.isEmpty else {
            throw AntigravityError.parseFailed("model configs have no quota buckets")
        }
        return AIUsageSnapshot(
            providerID: providerID,
            meters: meters,
            balance: nil,
            currency: nil,
            fetchedAt: Date(),
            source: source
        )
    }

    private static func modelConfigMeters(_ configs: [AntigravityModelConfig]) -> [AIUsageMeter] {
        configs.compactMap { config in
            guard let quota = config.quotaInfo,
                  let remaining = quota.remainingFraction,
                  remaining >= 0, remaining <= 1
            else { return nil }
            return AIUsageMeter(
                label: config.displayLabel.isEmpty ? config.modelOrAlias.model : config.displayLabel,
                used: Decimal(((1 - remaining) * 100).rounded()),
                limit: 100,
                unit: .percent,
                resetsAt: quota.resetTime.flatMap(AntigravityParsing.parseResetTime)
            )
        }
    }

    /// Antigravity reset timestamps: ISO8601 with optional fractional
    /// seconds, falling back to plain ISO8601.
    static func parseResetTime(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: value)
    }
}

// MARK: - Response models

/// `code` arrives either as an integer (`0` = ok) or a string (`"ok"`).
enum AntigravityCode: Decodable {
    case int(Int)
    case string(String)

    var isOK: Bool {
        switch self {
        case .int(let value): return value == 0
        case .string(let value):
            let lower = value.lowercased()
            return lower == "ok" || lower == "success" || value == "0"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let int = try? container.decode(Int.self) {
            self = .int(int)
        } else if let string = try? container.decode(String.self) {
            self = .string(string)
        } else {
            self = .string("")
        }
    }
}

struct AntigravityQuotaSummaryEnvelope: Decodable {
    let code: AntigravityCode
    let message: String?
    let response: AntigravityQuotaSummaryPayload?
    let summary: AntigravityQuotaSummaryPayload?
    let groups: [AntigravityQuotaGroup]?

    var rootPayload: AntigravityQuotaSummaryPayload? {
        guard let groups else { return nil }
        return AntigravityQuotaSummaryPayload(description: nil, groups: groups)
    }
}

struct AntigravityQuotaSummaryPayload: Decodable {
    let description: String?
    let groups: [AntigravityQuotaGroup]
}

struct AntigravityQuotaGroup: Decodable {
    let displayName: String
    let description: String?
    let buckets: [AntigravityQuotaBucket]?
}

struct AntigravityQuotaBucket: Decodable {
    let bucketId: String
    let displayName: String?
    let remainingFraction: Double?
    let resetTime: String?
    let description: String?
    let disabled: Bool?

    var displayLabel: String {
        (displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AntigravityUserStatusResponse: Decodable {
    let code: AntigravityCode
    let message: String?
    let userStatus: AntigravityUserStatus?
}

struct AntigravityUserStatus: Decodable {
    let email: String?
    let cascadeModelConfigData: AntigravityModelConfigData?
}

struct AntigravityModelConfigData: Decodable {
    let clientModelConfigs: [AntigravityModelConfig]?
}

struct AntigravityModelConfigResponse: Decodable {
    let code: AntigravityCode
    let message: String?
    let clientModelConfigs: [AntigravityModelConfig]?
}

struct AntigravityModelConfig: Decodable {
    let label: String?
    let modelOrAlias: AntigravityModelAlias
    let quotaInfo: AntigravityQuotaInfo?

    var displayLabel: String {
        (label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct AntigravityModelAlias: Decodable {
    let model: String
}

struct AntigravityQuotaInfo: Decodable {
    let remainingFraction: Double?
    let resetTime: String?
}
