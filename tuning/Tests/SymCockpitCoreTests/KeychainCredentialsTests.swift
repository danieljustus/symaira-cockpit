import XCTest
@testable import SymCockpitCore
import SymairaKeychain

final class KeychainCredentialsTests: XCTestCase {
    private let service = "com.symaira.symtune.test"
    private let account = "test-\(UUID().uuidString)"

    override func tearDown() {
        _ = KeychainCredentials.delete(service: service, account: account)
        super.tearDown()
    }

    /// Round-trips a value through the Keychain. Skips (not fails) when the
    /// test environment has no usable keyring (e.g. headless CI).
    func testWriteReadDeleteRoundTrip() throws {
        // Headless CI: SecItemAdd blocks forever in the securityd
        // authorization prompt instead of failing fast (observed on the
        // self-hosted runner, 0% CPU, stuck in xpc_connection_send_message
        // with reply sync). Skip like the PTY tests do.
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            throw XCTSkip("keychain authorization prompt hangs in headless CI")
        }
        let secret = "test-secret-\(UUID().uuidString)"
        let writeResult = KeychainCredentials.write(service: service, account: account, value: secret)
        // The login keychain needs no entitlement, so an interactive session
        // completes the round-trip. A locked or absent login keychain still
        // fails the write; then the environment decides, not the code (same
        // pattern as the appkit SymairaKeychainTests).
        guard writeResult.success else {
            throw XCTSkip("keychain write failed in this environment: \(writeResult.errorMessage ?? "unknown")")
        }

        XCTAssertEqual(KeychainCredentials.read(service: service, account: account), secret)

        // Overwrite replaces the previous value.
        let second = "test-secret-2-\(UUID().uuidString)"
        let overwriteResult = KeychainCredentials.write(service: service, account: account, value: second)
        guard overwriteResult.success else {
            throw XCTSkip("keychain overwrite failed in this environment: \(overwriteResult.errorMessage ?? "unknown")")
        }
        XCTAssertEqual(KeychainCredentials.read(service: service, account: account), second)

        XCTAssertTrue(KeychainCredentials.delete(service: service, account: account))
        XCTAssertNil(KeychainCredentials.read(service: service, account: account))
    }

    /// Cockpit ships without a keychain-access-groups entitlement; the
    /// data-protection keychain would reject every save with -34018 (#396).
    func testUsesLoginKeychainStorage() {
        XCTAssertEqual(KeychainCredentials.storage, .loginKeychain)
    }

    func testDeleteIsIdempotent() {
        XCTAssertTrue(KeychainCredentials.delete(service: service, account: account))
        XCTAssertTrue(KeychainCredentials.delete(service: service, account: account))
    }
}
