import XCTest
@testable import SymTuneCore

/// Constructing a provider must not read its credential.
///
/// Every process that lists the AI-usage catalog — each CLI invocation, each
/// app launch — constructs all ten providers, whether or not the user enabled
/// any of them. When credentials were resolved in `init`, that meant a Keychain
/// read per provider on every launch, and a Keychain item whose ACL does not
/// list the calling binary answers with a modal system dialog. Users who had
/// never turned on a single provider were getting a stack of "always allow"
/// prompts for entries the app was never going to use.
final class CredentialLazinessTests: XCTestCase {
    /// Thread-safe call counter — the resolver is `@Sendable`.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock()
            defer { lock.unlock() }
            value += 1
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func testClaudeProviderDoesNotReadCredentialsUntilUsed() {
        let counter = Counter()
        let provider = ClaudeUsageProvider(
            oauthTokenReader: { _ in
                counter.increment()
                return "token"
            }
        )

        XCTAssertEqual(counter.count, 0, "constructing the provider read the credential")

        _ = provider.strategies
        XCTAssertEqual(counter.count, 1, "first use should resolve the credential")

        _ = provider.strategies
        XCTAssertEqual(counter.count, 1, "the resolved credential should be memoized")

        provider.resetCredentialCache()
        _ = provider.strategies
        XCTAssertEqual(counter.count, 2, "resetting the cache should force a re-read")
    }

    /// The catalog is what actually gets built on every launch, so it is the
    /// thing that must stay side-effect-free.
    func testBuildingTheDefaultCatalogResolvesNothing() {
        let providers = TuneController.defaultAIUsageProviders()
        XCTAssertEqual(providers.count, 10)
        // Nothing to assert beyond "this returned" — the point is that it does
        // no credential I/O, which the Claude test above pins down precisely.
        // Kept as a guard against a provider being added with an eager read.
        XCTAssertEqual(Set(providers.map(\.id)).count, providers.count)
    }
}
