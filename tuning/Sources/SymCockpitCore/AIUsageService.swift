import Foundation

/// One provider row returned to the existing CLI/MCP compatibility surface.
public struct AIUsageService: @unchecked Sendable {
    public struct ProviderResult: Sendable, Equatable, Codable {
        public let providerID: String
        public let snapshot: AIUsageSnapshot?
        /// A generic, secret-free error. The subprocess output is never exposed.
        public let error: String?
        public let history: AIUsageRecordedHistory?

        public init(providerID: String, snapshot: AIUsageSnapshot?, error: String?, history: AIUsageRecordedHistory? = nil) {
            self.providerID = providerID
            self.snapshot = snapshot
            self.error = error
            self.history = history
        }
    }

    /// The error reported for a provider symbrain lists as unconfigured.
    public static let notConfiguredMessage = "not configured"

    public let providers: [any AIUsageProvider]
    private let client: any SymBrainUsageClientProtocol
    private let cache: AIUsageSnapshotCache?

    /// Inject a cache explicitly; tests and embedded callers remain disk-free.
    public init(
        providers: [any AIUsageProvider] = SymBrainUsageProvider.catalog(),
        client: any SymBrainUsageClientProtocol = SymBrainUsageClient(),
        cache: AIUsageSnapshotCache? = nil
    ) {
        self.providers = providers
        self.client = client
        self.cache = cache
    }

    public var providerCatalog: [(id: String, displayName: String)] {
        providers.map { ($0.id, $0.displayName) }
    }

    /// An explicit empty selection performs no subprocess or credential work.
    /// Failed refreshes carry the last snapshot AND an error, never a fake zero.
    public func usageAll(providerIDs: Set<String>? = nil, force: Bool = true, grokHistoryEnabled: Bool = false,
                         opencodeHistoryEnabled: Bool = false, claudeHistoryEnabled: Bool = false,
                         claudeHistoryOnly: Bool = false, codexHistoryEnabled: Bool = false,
                         codexHistoryOnly: Bool = false) async -> [ProviderResult] {
        let selected = providers.filter { providerIDs?.contains($0.id) ?? true }
        guard !selected.isEmpty else { return [] }
        let cached = cachedResults(providerIDs: providerIDs)
        let historyIDs = Set([grokHistoryEnabled ? "grok" : nil, opencodeHistoryEnabled ? "opencode" : nil,
                              claudeHistoryEnabled ? "claude" : nil, codexHistoryEnabled ? "codex" : nil].compactMap { $0 })
            .intersection(providerIDs ?? [])
        if !force, historyIDs.isEmpty, cached.count == selected.count,
           cached.allSatisfy({ $0.error == nil && ($0.snapshot.map { AIUsageSnapshotCache.isFresh($0) } ?? false) }) {
            return cached
        }
        do {
            let report: SymBrainUsageReport
            if let providerIDs {
                report = try client.fetchReport(providerIDs: providerIDs, grokHistoryEnabled: grokHistoryEnabled,
                                                opencodeHistoryEnabled: opencodeHistoryEnabled,
                                                claudeHistoryEnabled: historyIDs.contains("claude"),
                                                claudeHistoryOnly: historyIDs.contains("claude") && claudeHistoryOnly,
                                                codexHistoryEnabled: historyIDs.contains("codex"),
                                                codexHistoryOnly: historyIDs.contains("codex") && codexHistoryOnly)
            } else {
                report = try client.fetchReport()
            }
            return reportResults(report).filter { providerIDs?.contains($0.providerID) ?? true }.map { raw in
                let result = ProviderResult(providerID: raw.providerID, snapshot: raw.snapshot, error: raw.error,
                    history: historyIDs.contains(raw.providerID) ? raw.history : nil)
                if let snapshot = result.snapshot {
                    try? cache?.save(snapshot)
                    return result
                }
                // Removing credentials must not keep showing the prior account.
                if result.error == Self.notConfiguredMessage {
                    cache?.remove(providerID: result.providerID)
                    return result
                }
                cache?.markRefreshFailed(providerID: result.providerID)
                return ProviderResult(providerID: result.providerID,
                                      snapshot: cache?.load(providerID: result.providerID), error: result.error, history: result.history)
            }
        } catch {
            let message = (error as? SymBrainUsageError)?.errorDescription ?? "AI usage unavailable."
            return selected.map { provider in
                cache?.markRefreshFailed(providerID: provider.id)
                return ProviderResult(providerID: provider.id, snapshot: cache?.load(providerID: provider.id), error: message)
            }
        }
    }

    /// Immediate launch presentation, followed by an asynchronous refresh.
    public func cachedResults(providerIDs: Set<String>? = nil) -> [ProviderResult] {
        providers.compactMap { provider in
            guard providerIDs?.contains(provider.id) ?? true,
                  let snapshot = cache?.load(providerID: provider.id) else { return nil }
            return ProviderResult(providerID: provider.id, snapshot: snapshot,
                                  error: cache?.lastRefreshFailed(providerID: provider.id) == true ? "Last refresh failed" : nil)
        }
    }

    /// Compatibility helper for callers that previously asked for one provider.
    public func usage(for providerID: String) async throws -> AIUsageSnapshot {
        guard providers.contains(where: { $0.id == providerID }) else {
            throw AIUsageError.unknownProvider(providerID)
        }
        let result = await usageAll(providerIDs: [providerID]).first
        guard let snapshot = result?.snapshot, result?.error == nil else { throw AIUsageError.unavailable }
        return snapshot
    }

    /// Credential changes invalidate account-bound snapshots on every surface.
    public func resetCache() {
        for provider in providers { cache?.remove(providerID: provider.id) }
    }

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
                    error: Self.notConfiguredMessage
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
            guard let rawSnapshot = row.snapshot, rawSnapshot.providerID == row.id else {
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
        return results.map { result in
            ProviderResult(providerID: result.providerID, snapshot: result.snapshot, error: result.error,
                history: report.providers.first { $0.id == result.providerID }?.history)
        }
    }
}
