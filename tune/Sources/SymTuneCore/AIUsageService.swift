import Foundation

/// Aggregator over all AI usage providers.
///
/// - stale-while-revalidate: fresh snapshots are served from cache, stale ones
///   are served immediately while a background refresh runs;
/// - network errors degrade to "stale with timestamp" instead of an empty
///   display;
/// - rate limits are respected with backoff (429 → no refetch until expiry);
/// - providers run concurrently and one hanging provider cannot block the
///   others (per-provider timeout);
/// - everything that leaves this service is secret-redacted.
public final class AIUsageService: @unchecked Sendable {
    /// Result of one provider in an aggregate read: snapshot or redacted error.
    public struct ProviderResult: Sendable, Equatable, Codable {
        public let providerID: String
        public let snapshot: AIUsageSnapshot?
        /// Redacted error description; `nil` on success.
        public let error: String?

        public init(providerID: String, snapshot: AIUsageSnapshot?, error: String?) {
            self.providerID = providerID
            self.snapshot = snapshot
            self.error = error
        }
    }

    private final class CacheEntry: @unchecked Sendable {
        var snapshot: AIUsageSnapshot?
        var rateLimitedUntil: Date?
    }

    /// All registered providers — exposed so the preferences UI can render
    /// per-provider credential inputs/state (issue #360).
    public let providers: [any AIUsageProvider]

    /// Known providers as (id, displayName) pairs — the catalog the UI uses
    /// to render per-provider toggles and labels without hardcoding names.
    public var providerCatalog: [(id: String, displayName: String)] {
        providers.map { ($0.id, $0.displayName) }
    }
    private let refreshInterval: TimeInterval
    private let providerTimeout: TimeInterval
    private let lock = NSLock()
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<AIUsageSnapshot, Error>] = [:]

    /// - Parameters:
    ///   - providers: all providers to aggregate.
    ///   - refreshInterval: default 300s (5 min).
    ///   - providerTimeout: per-provider fetch timeout, default 10s.
    public init(
        providers: [any AIUsageProvider],
        refreshInterval: TimeInterval = 300,
        providerTimeout: TimeInterval = 10
    ) {
        self.providers = providers
        self.refreshInterval = refreshInterval
        self.providerTimeout = providerTimeout
    }

    private func provider(for id: String) throws -> any AIUsageProvider {
        guard let provider = providers.first(where: { $0.id == id }) else {
            throw AIUsageError.unknownProvider(id)
        }
        return provider
    }

    /// Snapshot for one provider with stale-while-revalidate semantics.
    /// Unconfigured providers throw ``AIUsageError/notConfigured(_:)``
    /// without touching credentials or the network.
    public func usage(for providerID: String) async throws -> AIUsageSnapshot {
        let provider = try provider(for: providerID)
        guard provider.isConfigured else {
            throw AIUsageError.notConfigured(providerID)
        }

        var cached: AIUsageSnapshot?
        var rateLimitedUntil: Date?
        lock.withLock {
            let entry = cache[providerID] ?? {
                let entry = CacheEntry()
                cache[providerID] = entry
                return entry
            }()
            cached = entry.snapshot
            rateLimitedUntil = entry.rateLimitedUntil
        }

        // Rate-limit backoff: serve stale without touching the provider.
        if let rateLimitedUntil, rateLimitedUntil > Date() {
            if let cached { return cached }
            throw AIUsageError.rateLimited(providerID, retryAfter: rateLimitedUntil.timeIntervalSinceNow)
        }

        if let cached {
            if Date().timeIntervalSince(cached.fetchedAt) < refreshInterval {
                // Fresh: serve from cache without refetching.
                return cached
            }
            // Stale: serve immediately, refresh in the background. A failed
            // background refresh degrades to the stale snapshot instead of an
            // empty display.
            Task { try? await refresh(provider) }
            return cached
        }

        do {
            return try await refresh(provider)
        } catch {
            // Nothing leaves this service unredacted — a provider that leaks a
            // token in its error message must not reach logs, history, or the UI.
            throw AIUsageError.redacted(SecretRedactor.redact(error.localizedDescription))
        }
    }

    /// Snapshots for all providers, run concurrently. One failing or hanging
    /// provider is isolated in its own result and cannot block the others.
    public func usageAll() async -> [ProviderResult] {
        await withTaskGroup(of: ProviderResult.self) { group in
            for provider in providers {
                group.addTask { [weak self] in
                    guard let self else {
                        return ProviderResult(providerID: provider.id, snapshot: nil, error: "service unavailable")
                    }
                    do {
                        let snapshot = try await self.usage(for: provider.id)
                        return ProviderResult(providerID: provider.id, snapshot: snapshot, error: nil)
                    } catch {
                        return ProviderResult(
                            providerID: provider.id,
                            snapshot: nil,
                            error: SecretRedactor.redact(error.localizedDescription)
                        )
                    }
                }
            }
            var results: [ProviderResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    /// Clear all cached snapshots (e.g. after credentials change).
    public func resetCache() {
        lock.withLock {
            cache.removeAll()
            inFlight.removeAll()
        }
    }

    // MARK: - Refresh

    private func refresh(_ provider: any AIUsageProvider) async throws -> AIUsageSnapshot {
        // Single-flight: check + register the in-flight task under one lock
        // hold so concurrent callers share the same fetch instead of
        // double-fetching (the old check-then-register had a TOCTOU window
        // that made the rate-limit backoff test flaky on slow runners).
        // The rate limit is re-checked under the same hold: a refresh that
        // was queued just before a 429 landed must not fetch afterwards.
        enum Decision {
            case shared(Task<AIUsageSnapshot, Error>)
            case fresh(Task<AIUsageSnapshot, Error>)
            case rateLimited(Date)
        }
        let decision = lock.withLock { () -> Decision in
            if let existing = inFlight[provider.id] {
                return .shared(existing)
            }
            if let rateLimitedUntil = cache[provider.id]?.rateLimitedUntil,
               rateLimitedUntil > Date() {
                return .rateLimited(rateLimitedUntil)
            }
            let newTask = Task {
                try await Self.withTimeout(seconds: providerTimeout) {
                    try await provider.fetch()
                }
            }
            inFlight[provider.id] = newTask
            return .fresh(newTask)
        }

        let task: Task<AIUsageSnapshot, Error>
        switch decision {
        case .shared(let existing):
            task = existing
        case .fresh(let newTask):
            task = newTask
        case .rateLimited(let until):
            throw AIUsageError.rateLimited(provider.id, retryAfter: until.timeIntervalSinceNow)
        }

        defer {
            lock.withLock { inFlight[provider.id] = nil }
        }
        do {
            let snapshot = try await task.value
            lock.withLock {
                cache[provider.id]?.snapshot = snapshot
                cache[provider.id]?.rateLimitedUntil = nil
            }
            return snapshot
        } catch let error as AIUsageError {
            if case .rateLimited(_, let retryAfter) = error {
                lock.withLock {
                    cache[provider.id]?.rateLimitedUntil = Date().addingTimeInterval(retryAfter ?? 60)
                }
            }
            throw error
        }
    }

    /// Bound an operation with a timeout; the winner (result or timeout) is
    /// returned and the loser is cancelled.
    private static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw AIUsageError.timedOut("exceeded \(Int(seconds.rounded()))s")
            }
            guard let result = try await group.next() else {
                throw AIUsageError.timedOut("no result")
            }
            group.cancelAll()
            return result
        }
    }
}
