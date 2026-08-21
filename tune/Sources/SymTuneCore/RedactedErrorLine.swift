import Foundation

/// Builds the stderr line for a non-TuneError, as JSON-encoded ``ErrorReport``
/// when possible.
///
/// `SecretRedactor` is the last line of defense at this output boundary:
/// both the debug-mode `String(reflecting:)` dump and the plain
/// `localizedDescription` can echo credential material from an underlying
/// error (e.g. a network error that embeds request headers), so both are
/// redacted before they're encoded into the report or returned as a
/// fallback string. Lives in SymTuneCore so it can be unit-tested without
/// linking the `symtune` executable into the test bundle (which would drag
/// `Sources/symtune/*` into the coverage report).
public func redactedErrorLine(for error: Error, debug: Bool) -> String {
    let rawMessage = debug ? String(reflecting: error) : error.localizedDescription
    let message = SecretRedactor.redact(rawMessage)
    let localized = SecretRedactor.redact(error.localizedDescription)
    let report = ErrorReport(
        error: "\(type(of: error))",
        message: message,
        localized: localized
    )
    if let json = try? JSONEncoder().encode(report),
       let string = String(data: json, encoding: .utf8) {
        return string
    }
    return SecretRedactor.redact(String(reflecting: error))
}

/// Structured error report emitted to stderr for non-``TuneError`` failures.
public struct ErrorReport: Codable {
    public let error: String
    public let message: String
    public let localized: String

    public init(error: String, message: String, localized: String) {
        self.error = error
        self.message = message
        self.localized = localized
    }
}
