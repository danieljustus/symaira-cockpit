import Foundation

public extension TuneController {
    /// Cache-only API presentation, including known providers with no snapshot.
    /// No provider, credential or network operation is performed.
    func cachedAIUsageReport(providerIDs: Set<String>? = nil) -> [AIUsageService.ProviderResult] {
        let cached = aiUsageService.cachedResults(providerIDs: providerIDs)
        return aiUsageProviderCatalog.compactMap { provider in
            guard providerIDs?.contains(provider.id) ?? true else { return nil }
            return cached.first { $0.providerID == provider.id }
                ?? .init(providerID: provider.id, snapshot: nil, error: nil)
        }
    }
}
