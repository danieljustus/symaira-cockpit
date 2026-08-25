import Foundation

/// One provider row returned to the existing CLI/MCP compatibility surface.
public struct AIUsageService: @unchecked Sendable {
    public struct ProviderResult: Sendable, Equatable, Codable {
        public let providerID: String
        public let snapshot: AIUsageSnapshot?
        /// A generic, secret-free error. The subprocess output is never exposed.
        public let error: String?

        public init(providerID: String, snapshot: AIUsageSnapshot?, error: String?) {
            self.providerID = providerID
            self.snapshot = snapshot
            self.error = error
        }
    }

    public let providers: [any AIUsageProvider]
    private let client: any SymBrainUsageClientProtocol

    /// The compatibility layer keeps the old provider catalog and result shape,
    /// while the only usage fetch is `symbrain usage --output json`.
    public init(
        providers: [any AIUsageProvider] = SymBrainUsageProvider.catalog(),
        client: any SymBrainUsageClientProtocol = SymBrainUsageClient()
    ) {
        self.providers = providers
        self.client = client
    }

    public var providerCatalog: [(id: String, displayName: String)] {
        providers.map { ($0.id, $0.displayName) }
    }

    /// Execute one symbrain report and adapt it to the legacy CLI/MCP result
    /// shape. A missing binary, non-zero exit, or malformed report is an
    /// unavailable result for every catalog entry, not a thrown UI error.
    public func usageAll() async -> [ProviderResult] {
        do {
            let report = try client.fetchReport()
            return reportResults(report)
        } catch {
            let message = "AI usage unavailable."
            return providers.map { ProviderResult(providerID: $0.id, snapshot: nil, error: message) }
        }
    }

    /// Compatibility helper for callers that previously asked for one provider.
    public func usage(for providerID: String) async throws -> AIUsageSnapshot {
        guard providers.contains(where: { $0.id == providerID }) else {
            throw AIUsageError.unknownProvider(providerID)
        }
        let result = await usageAll().first { $0.providerID == providerID }
        guard let snapshot = result?.snapshot else { throw AIUsageError.unavailable }
        return snapshot
    }

    /// The runtime command is deliberately uncached. The UI controls refresh
    /// cadence, and every CLI/MCP invocation should reflect the latest report.
    public func resetCache() {}

    /// Doctor now reports the same auth source/status used by the usage screen.
    public func credentialSources() -> [CredentialSourceReport] {
        providers.map {
            CredentialSourceReport(
                provider: $0.id,
                source: $0.credentialSource,
                opReference: nil,
                envKey: nil,
                keychainAccount: nil
            )
        }
    }

    private func reportResults(_ report: SymBrainUsageReport) -> [ProviderResult] {
        var results: [ProviderResult] = []
        results.reserveCapacity(providers.count)

        for provider in providers {
            guard let row = report.providers.first(where: { $0.id == provider.id }) else {
                results.append(ProviderResult(providerID: provider.id, snapshot: nil, error: "AI usage unavailable."))
                continue
            }

            if let provider = provider as? SymBrainUsageProvider {
                provider.update(from: row)
            }

            guard row.configured else {
                results.append(ProviderResult(
                    providerID: row.id,
                    snapshot: nil,
                    error: "not configured"
                ))
                continue
            }
            if !row.error.isEmpty {
                results.append(ProviderResult(
                    providerID: row.id,
                    snapshot: nil,
                    error: SecretRedactor.redact(row.error)
                ))
                continue
            }
            guard let rawSnapshot = row.snapshot else {
                results.append(ProviderResult(
                    providerID: row.id,
                    snapshot: nil,
                    error: "AI usage unavailable."
                ))
                continue
            }
            do {
                results.append(ProviderResult(
                    providerID: row.id,
                    snapshot: try rawSnapshot.aiUsageSnapshot(),
                    error: nil
                ))
            } catch {
                results.append(ProviderResult(
                    providerID: row.id,
                    snapshot: nil,
                    error: "AI usage unavailable."
                ))
            }
        }
        return results
    }
}
