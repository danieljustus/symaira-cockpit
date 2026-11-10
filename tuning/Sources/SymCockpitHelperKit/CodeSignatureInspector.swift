import Foundation
import Security

/// Reads and checks code signatures through the Security framework.
public enum CodeSignatureInspector {
    /// Team identifier of the running process, or nil when it is unsigned or
    /// ad-hoc signed.
    public static func ownTeamIdentifier() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        return teamIdentifier(of: staticCode)
    }

    /// Team identifier of the code at `url` (an app bundle or executable).
    public static func teamIdentifier(at url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return nil }
        return teamIdentifier(of: staticCode)
    }

    private static func teamIdentifier(of staticCode: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info
        ) == errSecSuccess,
            let dictionary = info as? [String: Any]
        else { return nil }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// Whether `requirement` is syntactically valid requirement language.
    public static func isWellFormed(requirement: String) -> Bool {
        var compiled: SecRequirement?
        return SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess
            && compiled != nil
    }
}

/// Checks the running process against a requirement.
public struct SelfCodeRequirementValidator: CodeRequirementValidating {
    public init() {}

    public func satisfies(requirement: String) -> Bool {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
              let compiled
        else { return false }
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], compiled) == errSecSuccess
    }
}

/// Checks code on disk (e.g. the helper embedded in the app) against a
/// requirement, strictly and including nested code.
public struct StaticCodeRequirementValidator: Sendable {
    public let url: URL

    public init(url: URL) { self.url = url }

    public func satisfies(requirement: String) -> Bool {
        var compiled: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &compiled) == errSecSuccess,
              let compiled
        else { return false }
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return false }
        return SecStaticCodeCheckValidityWithErrors(
            staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate),
            compiled, nil
        ) == errSecSuccess
    }
}
