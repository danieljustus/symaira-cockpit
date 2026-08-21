import Foundation

// MARK: - Antigravity provider

/// Antigravity usage provider.
///
/// Quota is read from the **local language-server probe** while the
/// Antigravity app or `agy` CLI is running — Antigravity is never started by
/// this provider, and nothing is scraped from any UI. When no local quota
/// server is reachable the strategy reports the provider as *not available*
/// (``AntigravityError/notRunning``), never as a hard failure with fake
/// numbers.
///
/// Google Cloud Code OAuth is intentionally **not** implemented here: the
/// local probe covers the documented acceptance criteria, and the OAuth path
/// would need Google credentials this tool does not manage.
public struct AntigravityUsageProvider: AIUsageProvider, Sendable {
    public let id = "antigravity"
    public let displayName = "Antigravity"

    /// The provider is always *present*; whether a quota is available
    /// depends on the running language server, not on configuration.
    public var isConfigured: Bool { true }

    public var strategies: [any AIUsageStrategy] {
        [AntigravityLocalProbeStrategy(
            processProbe: processProbe,
            transport: transport
        )]
    }

    private let processProbe: any AntigravityProcessProbe
    private let transport: any AntigravityLocalTransport

    /// - Parameters:
    ///   - processProbe: `ps`/`lsof` seam (test seam; defaults to real
    ///     subprocesses).
    ///   - transport: localhost HTTPS seam (test seam; defaults to a
    ///     self-signed-tolerant localhost client).
    public init(
        processProbe: (any AntigravityProcessProbe)? = nil,
        transport: (any AntigravityLocalTransport)? = nil
    ) {
        self.processProbe = processProbe ?? ShellProcessProbe()
        self.transport = transport ?? LoopbackLocalTransport()
    }

    // MARK: - Credential descriptor (issue #360)

    public var credentialDescriptor: AIUsageCredentialDescriptor? {
        AIUsageCredentialDescriptor(
            authKind: .externalToken(resolver: .init(read: { Self.readExternalAuthState() })),
            sourceLabel: "Local Antigravity language server probe"
        )
    }

    /// Reads the Antigravity auth state for the preferences UI.
    static func readExternalAuthState() -> ExternalAuthState {
        let probe = ShellProcessProbe()
        if probe.isAntigravityRunning() {
            return ExternalAuthState(
                status: .available,
                detail: "Antigravity is running",
                source: "local"
            )
        }
        return ExternalAuthState(
            status: .missing,
            detail: "Antigravity is not running — start the Antigravity app or agy CLI",
            source: nil
        )
    }
}

// MARK: - Errors

enum AntigravityError: Error, LocalizedError {
    /// No language server is running (or reachable) — the provider is
    /// *not available*, not broken.
    case notRunning
    case probeFailed(String)
    case httpStatus(Int)
    case parseFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Antigravity is not running — no local quota server found."
        case .probeFailed(let detail):
            return "Antigravity probe failed: \(detail)"
        case .httpStatus(let code):
            return "Antigravity local server returned HTTP \(code)."
        case .parseFailed(let detail):
            return "Antigravity returned an unreadable response: \(detail)"
        }
    }
}

// MARK: - Process probe (ps/lsof seams)

/// Runs the two shell probes needed for port discovery. Injectable for
/// tests; the production implementation shells out to `ps` and `lsof`.
public protocol AntigravityProcessProbe: Sendable {
    /// `ps -ax -o pid=,command=` output, or `nil` when the call failed.
    func processList() -> String?
    /// `lsof -nP -iTCP -sTCP:LISTEN -a -p <pid>` output, or `nil` on failure.
    func listeningPorts(pid: Int) -> String?
    /// Whether the Antigravity language server process is running.
    /// Used by the preferences UI to show auth state (issue #360).
    func isAntigravityRunning() -> Bool
}

/// Production probe backed by `ps` and `lsof` subprocesses.
public struct ShellProcessProbe: AntigravityProcessProbe {
    public init() {}

    public func processList() -> String? {
        Self.run("/bin/ps", ["-ax", "-o", "pid=,command="])
    }

    public func listeningPorts(pid: Int) -> String? {
        Self.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", String(pid)])
    }

    public func isAntigravityRunning() -> Bool {
        guard let list = processList() else { return false }
        return list.contains("agy") || list.contains("Antigravity")
    }

    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(bytes: data, encoding: .utf8)
    }
}

// MARK: - Local transport

/// HTTPS transport for the Antigravity local language server, which serves a
/// self-signed certificate. The production client trusts the certificate
/// **only for loopback hosts**; tests inject scripted responses.
public protocol AntigravityLocalTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, URLResponse)
}

public struct LoopbackLocalTransport: AntigravityLocalTransport {
    private final class LoopbackTrustDelegate: NSObject, URLSessionDelegate {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let host = challenge.protectionSpace.host.isEmpty ? nil : challenge.protectionSpace.host,
                  isLoopback(host)
            else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            if let trust = challenge.protectionSpace.serverTrust {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        }

        private func isLoopback(_ host: String) -> Bool {
            host == "127.0.0.1" || host == "localhost" || host == "::1"
        }
    }

    private let session: URLSession

    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 6
        let delegate = LoopbackTrustDelegate()
        // The delegate is retained by the session.
        self.session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        _ = delegate
    }

    public func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        try await session.data(for: request)
    }
}

// MARK: - Strategy

/// Probes a running Antigravity language server for quota.
///
/// Flow: `ps` → language-server candidates (with `--csrf_token` when
/// present) → `lsof` listening ports per candidate → `GetUnleashData`
/// connect probe → `RetrieveUserQuotaSummary`, falling back to
/// `GetUserStatus`, then `GetCommandModelConfigs`.
public struct AntigravityLocalProbeStrategy: AIUsageStrategy, Sendable {
    public let source = "local"

    private let processProbe: any AntigravityProcessProbe
    private let transport: any AntigravityLocalTransport

    public init(
        processProbe: any AntigravityProcessProbe,
        transport: any AntigravityLocalTransport
    ) {
        self.processProbe = processProbe
        self.transport = transport
    }

    private static let servicePath = "exa.language_server_pb.LanguageServerService"

    public func fetch() async throws -> AIUsageSnapshot {
        let candidates = try Self.parseCandidates(processList: processProbe.processList() ?? "")
        guard !candidates.isEmpty else {
            throw AntigravityError.notRunning
        }

        var lastError: Error = AntigravityError.notRunning
        for candidate in candidates {
            let ports = Self.parsePorts(portList: processProbe.listeningPorts(pid: candidate.pid) ?? "")
            for port in ports {
                do {
                    return try await fetchFromPort(port: port, csrfToken: candidate.csrfToken)
                } catch {
                    lastError = error
                }
            }
        }
        throw lastError
    }

    // MARK: Candidate discovery (testable parsers)

    /// One discovered language-server process.
    struct ServerCandidate: Sendable, Equatable {
        let pid: Int
        let csrfToken: String?
    }

    /// Extracts Antigravity language-server processes from `ps` output.
    /// Recognizes the app/IDE `language_server*` binaries (scoped to
    /// Antigravity by `--app_data_dir antigravity` or an antigravity path)
    /// and the `agy` CLI binary (which needs no CSRF token).
    static func parseCandidates(processList: String) -> [ServerCandidate] {
        var candidates: [ServerCandidate] = []
        for line in processList.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, let pid = Int(parts[0]) else { continue }
            let command = parts[1]
            let lower = command.lowercased()

            let isAppOrIDEServer = (lower.contains("language_server") || lower.contains("language-server"))
                && (lower.contains("antigravity")
                    || lower.contains("--app_data_dir") && command.contains("antigravity"))
            let isCLI = lower.contains("/agy") || lower.contains("antigravity-cli")
                || lower.contains("antigravity_cli")
            guard isAppOrIDEServer || isCLI else { continue }

            var csrfToken: String?
            if let tokenRange = command.range(of: "--csrf_token") {
                let after = command[tokenRange.upperBound...]
                let token = after.split(separator: " ", maxSplits: 1)
                if let first = token.first.map(String.init), !first.isEmpty {
                    csrfToken = first
                }
            }
            candidates.append(ServerCandidate(pid: pid, csrfToken: csrfToken))
        }
        return candidates
    }

    /// Extracts listening TCP ports from `lsof -iTCP -sTCP:LISTEN` output.
    /// The NAME column (`TCP 127.0.0.1:34567 (LISTEN)`) contains spaces, so
    /// the whole line is scanned for `:port` tokens.
    static func parsePorts(portList: String) -> [Int] {
        var ports: [Int] = []
        let pattern = #":([0-9]{1,5})(?:\s|$)"#
        for line in portList.split(separator: "\n") {
            // Only LISTENing sockets qualify (defensive even though lsof is
            // already invoked with -sTCP:LISTEN).
            guard line.contains("(LISTEN)") else { continue }
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: String(line), range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line),
                  let port = Int(line[range])
            else { continue }
            if !ports.contains(port) {
                ports.append(port)
            }
        }
        return ports
    }

    // MARK: Quota fetch

    private func fetchFromPort(port: Int, csrfToken: String?) async throws -> AIUsageSnapshot {
        let base = URL(string: "https://127.0.0.1:\(port)")!
        var connectRequest = URLRequest(url: base.appendingPathComponent("\(Self.servicePath)/GetUnleashData"))
        connectRequest.httpMethod = "POST"
        if let csrfToken {
            connectRequest.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }
        connectRequest.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")

        let (_, connectResponse) = try await transport.send(connectRequest)
        guard let http = connectResponse as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AntigravityError.probeFailed("connect probe failed on port \(port)")
        }

        // Quota chain: RetrieveUserQuotaSummary → GetUserStatus →
        // GetCommandModelConfigs. Any failure (HTTP or parse) falls through
        // to the next endpoint; the last error is rethrown when all fail.
        var chainError: Error = AntigravityError.parseFailed("all quota endpoints failed")
        for method in ["RetrieveUserQuotaSummary", "GetUserStatus", "GetCommandModelConfigs"] {
            do {
                let data = try await postJSON(base: base, method: method, csrfToken: csrfToken)
                if let snapshot = try? AntigravityParsing.snapshot(
                    forMethod: method,
                    data: data,
                    providerID: "antigravity",
                    source: source
                ) {
                    return snapshot
                }
                chainError = AntigravityError.parseFailed("\(method) returned unreadable data")
            } catch {
                chainError = error
            }
        }
        throw chainError
    }

    private func postJSON(base: URL, method: String, csrfToken: String?) async throws -> Data {
        var request = URLRequest(url: base.appendingPathComponent("\(Self.servicePath)/\(method)"))
        request.httpMethod = "POST"
        if let csrfToken {
            request.setValue(csrfToken, forHTTPHeaderField: "X-Codeium-Csrf-Token")
        }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = "{}".data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.send(request)
        } catch {
            throw AntigravityError.probeFailed(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw AntigravityError.probeFailed("invalid response")
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 429 {
                throw AIUsageError.rateLimited("antigravity", retryAfter: retryAfterSeconds(from: http))
            }
            throw AntigravityError.httpStatus(http.statusCode)
        }
        return data
    }
}

// MARK: - Rate limit parsing

/// Parses the `Retry-After` header's delta-seconds form (e.g. `"30"`);
/// `nil` when the header is absent or not a plain integer/decimal — the
/// HTTP-date form is not handled since 429 responses conventionally use
/// delta-seconds.
private func retryAfterSeconds(from response: HTTPURLResponse) -> TimeInterval? {
    guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
    return TimeInterval(value.trimmingCharacters(in: .whitespacesAndNewlines))
}
