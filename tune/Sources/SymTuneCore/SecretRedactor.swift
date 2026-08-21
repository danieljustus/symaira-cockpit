import Foundation

/// Redacts credential-shaped substrings from free text (error descriptions,
/// logs) so token material can never reach logs, history, or the UI.
///
/// The credential rules for every provider: auth files and Keychain are only
/// read, never written; no token material in `HistoryService`, logs, debug
/// output, or crash logs. This redactor is the last line of defense at the
/// service boundary — anything leaving `AIUsageService` passes through it.
public enum SecretRedactor {
    /// The redaction marker replacing every match.
    public static let placeholder = "<redacted>"

    /// Credential-shaped patterns. Deliberately broad: keys with dashes,
    /// bearer headers, `key=...` assignments and JWT-shaped segments.
    /// Compiled with `try?` + `compactMap`: a broken pattern must never crash
    /// the service, it simply stops matching.
    private static let patterns: [NSRegularExpression] = [
        // sk-... (OpenAI/OpenRouter-style), ghp_/github_pat_ (GitHub),
        // glpat- (GitLab), xox[baprs]- (Slack), AIza... (Google)
        #"(sk-[A-Za-z0-9_-]{8,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{8,}|xox[baprs]-[A-Za-z0-9-]{8,}|AIza[0-9A-Za-z_-]{20,})"#,
        // Authorization / Bearer headers and quoted secrets. Both the
        // `Bearer <token>` (space-separated) and `key=<token>` shapes.
        #"(?i)(authorization|bearer|api[_-]?key|token)\s*[:=]\s*("[^"]+"|'[^']+'|[A-Za-z0-9._-]{12,})"#,
        #"(?i)\bbearer\s+[A-Za-z0-9._-]{12,}"#,
        // Redaction markers already applied elsewhere («redacted:sk-…»).
        #"«redacted:[^»]*»"#,
        // JWT-shaped segments
        #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    /// Replace every credential-shaped substring with `<redacted>`.
    public static func redact(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            result = pattern.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: placeholder
            )
        }
        return result
    }
}
