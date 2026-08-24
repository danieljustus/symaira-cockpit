import Testing
@testable import SymTuneCore

struct CredentialResolverTests {

    // MARK: - symvault resolution

    @Test func resolvesOpReferenceViaSymvault() throws {
        let resolver = DefaultCredentialResolver(
            symvault: MockSymVaultService(available: true, value: "vault-key-123"),
            env: [:]
        )
        let result = resolver.resolve(
            opReference: "op://my-item",
            envKey: "TEST_KEY",
            keychainService: nil,
            keychainAccount: nil
        )
        #expect(result == "vault-key-123")
        #expect(resolver.source(
            opReference: "op://my-item",
            envKey: "TEST_KEY",
            keychainService: nil,
            keychainAccount: nil
        ) == "symvault")
    }

    @Test func reportsSymvaultMissingWhenUnavailable() throws {
        let resolver = DefaultCredentialResolver(
            symvault: MockSymVaultService(available: false, value: nil),
            env: [:]
        )
        let result = resolver.resolve(
            opReference: "op://my-item",
            envKey: "TEST_KEY",
            keychainService: nil,
            keychainAccount: nil
        )
        #expect(result == nil)
        #expect(resolver.source(
            opReference: "op://my-item",
            envKey: "TEST_KEY",
            keychainService: nil,
            keychainAccount: nil
        ) == "symvault (missing)")
    }

    @Test func nonOpReferenceDoesNotUseSymvault() throws {
        let mock = MockSymVaultService(available: true, value: "should-not-be-used")
        let resolver = DefaultCredentialResolver(
            symvault: mock,
            env: ["MY_KEY": "env-value"]
        )
        let result = resolver.resolve(
            opReference: nil,
            envKey: "MY_KEY",
            keychainService: nil,
            keychainAccount: nil
        )
        #expect(result == "env-value")
        #expect(resolver.source(
            opReference: nil,
            envKey: "MY_KEY",
            keychainService: nil,
            keychainAccount: nil
        ) == "env")
        // symvault should never have been called
    }

    // MARK: - env fallback

    @Test func resolvesFromEnvVar() throws {
        let resolver = DefaultCredentialResolver(
            symvault: MockSymVaultService(available: false, value: nil),
            env: ["MY_API_KEY": "env-secret"]
        )
        let result = resolver.resolve(
            opReference: nil,
            envKey: "MY_API_KEY",
            keychainService: nil,
            keychainAccount: nil
        )
        #expect(result == "env-secret")
        #expect(resolver.source(
            opReference: nil,
            envKey: "MY_API_KEY",
            keychainService: nil,
            keychainAccount: nil
        ) == "env")
    }

    @Test func emptyEnvVarFallsThrough() throws {
        let resolver = DefaultCredentialResolver(
            symvault: MockSymVaultService(available: false, value: nil),
            env: ["MY_API_KEY": ""]
        )
        let result = resolver.resolve(
            opReference: nil,
            envKey: "MY_API_KEY",
            keychainService: "svc",
            keychainAccount: "acct"
        )
        // Falls through to keychain which will be nil (no real keychain in tests)
        #expect(result == nil)
        #expect(resolver.source(
            opReference: nil,
            envKey: "MY_API_KEY",
            keychainService: "svc",
            keychainAccount: "acct"
        ) == "none")
    }

    // MARK: - resolution chain order

    @Test func opReferenceTakesPrecedenceOverEnv() throws {
        let resolver = DefaultCredentialResolver(
            symvault: MockSymVaultService(available: true, value: "vault-wins"),
            env: ["MY_KEY": "env-loses"]
        )
        let result = resolver.resolve(
            opReference: "op://item",
            envKey: "MY_KEY",
            keychainService: nil,
            keychainAccount: nil
        )
        #expect(result == "vault-wins")
    }

    @Test func envTakesPrecedenceOverKeychain() throws {
        let resolver = DefaultCredentialResolver(
            symvault: MockSymVaultService(available: false, value: nil),
            keychainReader: { _, _ in "keychain-value" },
            env: ["MY_KEY": "env-wins"]
        )
        let result = resolver.resolve(
            opReference: nil,
            envKey: "MY_KEY",
            keychainService: "svc",
            keychainAccount: "acct"
        )
        #expect(result == "env-wins")
        #expect(resolver.source(
            opReference: nil,
            envKey: "MY_KEY",
            keychainService: "svc",
            keychainAccount: "acct"
        ) == "env")
    }

    // MARK: - nil opReference skips symvault

    @Test func nilOpReferenceWithNoEnvOrKeychain() throws {
        let resolver = DefaultCredentialResolver(
            symvault: MockSymVaultService(available: true, value: "should-not-use"),
            keychainReader: { _, _ in nil },
            env: [:]
        )
        let result = resolver.resolve(
            opReference: nil,
            envKey: "MISSING",
            keychainService: nil,
            keychainAccount: nil
        )
        #expect(result == nil)
        #expect(resolver.source(
            opReference: nil,
            envKey: "MISSING",
            keychainService: nil,
            keychainAccount: nil
        ) == "none")
    }
}

// MARK: - Mock symvault service

private final class MockSymVaultService: SymVaultServiceProtocol, @unchecked Sendable {
    let isAvailable: Bool
    private let value: String?

    init(available: Bool, value: String?) {
        self.isAvailable = available
        self.value = value
    }

    func get(reference: String) -> String? {
        if !isAvailable { return nil }
        return value
    }
}
