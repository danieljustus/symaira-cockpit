import XCTest
@testable import SymTuneCore

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
        XCTAssertEqual(writeResult.success, true, "keychain write failed: \(writeResult.errorMessage ?? "unknown")")
        if !writeResult.success {
            throw XCTSkip("keychain unavailable in this environment")
        }

        XCTAssertEqual(KeychainCredentials.read(service: service, account: account), secret)

        // Overwrite replaces the previous value.
        let second = "test-secret-2-\(UUID().uuidString)"
        let overwriteResult = KeychainCredentials.write(service: service, account: account, value: second)
        XCTAssertTrue(overwriteResult.success, "overwrite failed: \(overwriteResult.errorMessage ?? "unknown")")
        XCTAssertEqual(KeychainCredentials.read(service: service, account: account), second)

        XCTAssertTrue(KeychainCredentials.delete(service: service, account: account))
        XCTAssertNil(KeychainCredentials.read(service: service, account: account))
    }

    func testDeleteIsIdempotent() {
        XCTAssertTrue(KeychainCredentials.delete(service: service, account: account))
        XCTAssertTrue(KeychainCredentials.delete(service: service, account: account))
    }
}
