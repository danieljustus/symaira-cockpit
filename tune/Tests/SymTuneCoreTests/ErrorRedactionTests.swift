import XCTest
import SymTuneCore

/// Issue #312: the CLI's catch-all error printer (`handleNonTuneError`)
/// must redact credential-shaped text before it reaches stderr. These
/// tests exercise `redactedErrorLine(for:debug:)`, the pure function
/// `handleNonTuneError` delegates to, so the redaction can be verified
/// without spawning the built binary or capturing process stderr.
final class ErrorRedactionTests: XCTestCase {

    private struct FakeError: Error, CustomNSError, LocalizedError {
        let secret: String

        var errorDescription: String? { "upstream rejected token \(secret)" }

        // CustomNSError machinery so `String(reflecting:)` (used in
        // SYMTUNE_DEBUG mode) also embeds the secret, matching how a real
        // NSError-bridged failure (e.g. a network error) can echo request
        // details back into its debug description.
        static var errorDomain: String { "ErrorRedactionTests.FakeError" }
        var errorCode: Int { 1 }
        var errorUserInfo: [String: Any] {
            [NSLocalizedDescriptionKey: "upstream rejected token \(secret)"]
        }
    }

    /// Built via concatenation (not a real-format literal) so this string
    /// can't be mistaken for a live credential, while still matching
    /// SecretRedactor's `sk-...` pattern.
    private var fakeToken: String { "sk-" + "abcdEFGH12345678ijkl" }

    func testRedactedErrorLineHidesCredentialInNonDebugMode() {
        let error = FakeError(secret: fakeToken)
        let line = redactedErrorLine(for: error, debug: false)

        XCTAssertFalse(line.contains(fakeToken), "credential must not appear verbatim in stderr output: \(line)")
        XCTAssertTrue(line.contains(SecretRedactor.placeholder), "redaction must be visible, not silent truncation")
    }

    func testRedactedErrorLineHidesCredentialInDebugMode() {
        let error = FakeError(secret: fakeToken)
        let line = redactedErrorLine(for: error, debug: true)

        XCTAssertFalse(line.contains(fakeToken), "credential must not appear verbatim in stderr output: \(line)")
        XCTAssertTrue(line.contains(SecretRedactor.placeholder), "redaction must be visible, not silent truncation")
    }

    func testRedactedErrorLineIsUnaffectedWhenNoSecretPresent() {
        struct PlainError: Error, LocalizedError {
            var errorDescription: String? { "disk full" }
        }
        let line = redactedErrorLine(for: PlainError(), debug: false)
        XCTAssertTrue(line.contains("disk full"))
        XCTAssertFalse(line.contains(SecretRedactor.placeholder))
    }
}
