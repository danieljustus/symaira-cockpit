import XCTest
@testable import SymTuneCore

// MARK: - Test doubles

/// Scripted process probe (no subprocesses in tests).
private final class StubProcessProbe: AntigravityProcessProbe, @unchecked Sendable {
    var processes: String?
    var portsByPID: [Int: String] = [:]

    func processList() -> String? { processes }
    func listeningPorts(pid: Int) -> String? { portsByPID[pid] }
    func isAntigravityRunning() -> Bool { processes?.contains("agy") ?? false || processes?.contains("Antigravity") ?? false }
}

/// Scripted localhost transport keyed by the request's last path component.
private final class ScriptedTransport: AntigravityLocalTransport, @unchecked Sendable {
    var script: [String: Result<(Data, URLResponse), Error>] = [:]
    var requests: [URLRequest] = []

    func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        requests.append(request)
        let key = request.url?.lastPathComponent ?? ""
        if let result = script[key] {
            return try result.get()
        }
        throw URLError(.cannotConnectToHost)
    }
}

// MARK: - Tests

final class AntigravityUsageProviderTests: XCTestCase {
    private func fixture(_ name: String) throws -> Data {
        let bundle = Bundle.module
        let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")!
        return try Data(contentsOf: url)
    }

    private func httpResponse(_ status: Int, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://127.0.0.1:34567/exa.language_server_pb.LanguageServerService/GetUnleashData")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
    }

    // MARK: Candidate discovery (port discovery covered here)

    func testParseCandidatesFindsAppServerWithCSRFToken() {
        let ps = """
          123 /usr/libexec/sshd
         4567 /Applications/Antigravity.app/Contents/Resources/language_server_macos_arm --app_data_dir antigravity --csrf_token tok_abc123 --extension_server_port 34567
         9999 /usr/bin/ssh-agent
        """
        let candidates = AntigravityLocalProbeStrategy.parseCandidates(processList: ps)
        XCTAssertEqual(candidates, [AntigravityLocalProbeStrategy.ServerCandidate(pid: 4567, csrfToken: "tok_abc123")])
    }

    func testParseCandidatesFindsCLIWithoutToken() {
        let ps = """
          7890 /opt/homebrew/bin/agy
          1234 /usr/libexec/sshd
        """
        let candidates = AntigravityLocalProbeStrategy.parseCandidates(processList: ps)
        XCTAssertEqual(candidates, [AntigravityLocalProbeStrategy.ServerCandidate(pid: 7890, csrfToken: nil)])
    }

    func testParseCandidatesIgnoresUnrelatedProcesses() {
        let ps = """
          123 /usr/libexec/sshd
          456 /System/Library/CoreServices/Finder.app/Contents/MacOS/Finder
          789 /usr/bin/python3 /usr/local/bin/something language_server
        """
        // A bare "language_server" token without Antigravity markers is not
        // an Antigravity server.
        XCTAssertTrue(AntigravityLocalProbeStrategy.parseCandidates(processList: ps).isEmpty)
    }

    func testParsePortsExtractsListeningTCPPorts() {
        let lsof = """
        COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
        language_ 4567 daniel   14u  IPv4 0x123 0t0  TCP 127.0.0.1:34567 (LISTEN)
        language_ 4567 daniel   15u  IPv6 0x456 0t0  TCP [::1]:34568 (LISTEN)
        language_ 4567 daniel   16u  IPv4 0x789 0t0  TCP *:34569 (LISTEN)
        """
        XCTAssertEqual(AntigravityLocalProbeStrategy.parsePorts(portList: lsof), [34567, 34568, 34569])
    }

    func testParsePortsIgnoresNonListeners() {
        let lsof = """
        COMMAND     PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME
        sshd      1234 daniel    3u  IPv4 0xabc 0t0  TCP 127.0.0.1:22 (ESTABLISHED)
        """
        XCTAssertTrue(AntigravityLocalProbeStrategy.parsePorts(portList: lsof).isEmpty)
    }

    // MARK: Parsing fixtures

    func testParsesQuotaSummaryFixture() async throws {
        let snapshot = try AntigravityParsing.quotaSummarySnapshot(
            data: try fixture("antigravity-quota-summary"),
            providerID: "antigravity",
            source: "local"
        )
        XCTAssertEqual(snapshot.source, "local")
        let weekly = snapshot.meters.first { $0.label == "Gemini Models — Weekly limit" }
        XCTAssertEqual(weekly?.used, Decimal(58), "used = (1 - 0.42) * 100")
        XCTAssertEqual(weekly?.unit, .percent)
        XCTAssertNotNil(weekly?.resetsAt)
        let fiveHour = snapshot.meters.first { $0.label == "Gemini Models — 5-hour limit" }
        XCTAssertEqual(fiveHour?.used, Decimal(15))
        let claude = snapshot.meters.first { $0.label == "Claude and GPT models — Weekly limit" }
        XCTAssertEqual(claude?.used, Decimal(90))
    }

    func testParsesUserStatusFixture() async throws {
        let snapshot = try AntigravityParsing.userStatusSnapshot(
            data: try fixture("antigravity-user-status"),
            providerID: "antigravity",
            source: "local"
        )
        let gemini = snapshot.meters.first { $0.label == "Gemini 2.5 Pro" }
        XCTAssertEqual(gemini?.used, Decimal(67))
        let claude = snapshot.meters.first { $0.label == "claude-sonnet-4" }
        XCTAssertEqual(claude?.used, Decimal(50))
    }

    func testParsesModelConfigsFixture() async throws {
        let snapshot = try AntigravityParsing.modelConfigsSnapshot(
            data: try fixture("antigravity-model-configs"),
            providerID: "antigravity",
            source: "local"
        )
        let gptOSS = snapshot.meters.first { $0.label == "GPT-OSS" }
        XCTAssertEqual(gptOSS?.used, Decimal(25))
        XCTAssertNotNil(gptOSS?.resetsAt)
    }

    // MARK: Strategy flow

    func testNotRunningWhenNoCandidates() async {
        let probe = StubProcessProbe()
        probe.processes = "  123 /usr/libexec/sshd\n"
        let strategy = AntigravityLocalProbeStrategy(processProbe: probe, transport: ScriptedTransport())

        do {
            _ = try await strategy.fetch()
            XCTFail("expected notRunning")
        } catch let error as AntigravityError {
            guard case .notRunning = error else {
                return XCTFail("unexpected error: \(error)")
            }
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testConnectProbeThenQuotaSummary() async throws {
        let probe = StubProcessProbe()
        probe.processes = "4567 /Applications/Antigravity.app/Contents/Resources/language_server_macos_arm --app_data_dir antigravity --csrf_token tok_abc123\n"
        probe.portsByPID[4567] = """
        language_ 4567 daniel   14u  IPv4 0x123 0t0  TCP 127.0.0.1:34567 (LISTEN)
        """

        let transport = ScriptedTransport()
        transport.script = [
            "GetUnleashData": .success((Data(), httpResponse(200))),
            "RetrieveUserQuotaSummary": .success((try fixture("antigravity-quota-summary"), httpResponse(200))),
        ]
        let strategy = AntigravityLocalProbeStrategy(processProbe: probe, transport: transport)

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.providerID, "antigravity")
        XCTAssertEqual(snapshot.source, "local")
        XCTAssertTrue(snapshot.meters.contains { $0.label == "Gemini Models — Weekly limit" })
        // The CSRF token must reach the local server on every request.
        for request in transport.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Codeium-Csrf-Token"), "tok_abc123")
        }
        let connect = transport.requests.first { $0.url?.lastPathComponent == "GetUnleashData" }
        XCTAssertEqual(connect?.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testQuotaChainFallsBackToUserStatus() async throws {
        let probe = StubProcessProbe()
        probe.processes = "7890 /opt/homebrew/bin/agy\n"
        probe.portsByPID[7890] = "agy      7890 daniel   14u  IPv4 0x123 0t0  TCP 127.0.0.1:34987 (LISTEN)\n"

        let transport = ScriptedTransport()
        transport.script = [
            "GetUnleashData": .success((Data(), httpResponse(200))),
            "RetrieveUserQuotaSummary": .success((Data("not json".utf8), httpResponse(200))),
            "GetUserStatus": .success((try fixture("antigravity-user-status"), httpResponse(200))),
        ]
        let strategy = AntigravityLocalProbeStrategy(processProbe: probe, transport: transport)

        let snapshot = try await strategy.fetch()

        XCTAssertEqual(snapshot.source, "local")
        XCTAssertTrue(snapshot.meters.contains { $0.label == "Gemini 2.5 Pro" })
        XCTAssertEqual(transport.requests.map(\.url?.lastPathComponent).filter { $0 != "GetUnleashData" }.count, 2)
    }

    func testQuotaChainEndsAtModelConfigs() async throws {
        let probe = StubProcessProbe()
        probe.processes = "7890 /opt/homebrew/bin/agy\n"
        probe.portsByPID[7890] = "agy      7890 daniel   14u  IPv4 0x123 0t0  TCP 127.0.0.1:34987 (LISTEN)\n"

        let transport = ScriptedTransport()
        transport.script = [
            "GetUnleashData": .success((Data(), httpResponse(200))),
            "RetrieveUserQuotaSummary": .success((Data("not json".utf8), httpResponse(200))),
            "GetUserStatus": .success((Data("not json".utf8), httpResponse(200))),
            "GetCommandModelConfigs": .success((try fixture("antigravity-model-configs"), httpResponse(200))),
        ]
        let strategy = AntigravityLocalProbeStrategy(processProbe: probe, transport: transport)

        let snapshot = try await strategy.fetch()

        XCTAssertTrue(snapshot.meters.contains { $0.label == "GPT-OSS" })
        XCTAssertEqual(transport.requests.count, 4)
    }

    // MARK: 429 → AIUsageError.rateLimited (issue #318)

    func testQuotaEndpointHTTP429MapsToRateLimitedWithRetryAfterHeader() async throws {
        let probe = StubProcessProbe()
        probe.processes = "7890 /opt/homebrew/bin/agy\n"
        probe.portsByPID[7890] = "agy      7890 daniel   14u  IPv4 0x123 0t0  TCP 127.0.0.1:34987 (LISTEN)\n"

        let transport = ScriptedTransport()
        transport.script = [
            "GetUnleashData": .success((Data(), httpResponse(200))),
            "RetrieveUserQuotaSummary": .success((Data(), httpResponse(429, headers: ["Retry-After": "9"]))),
            "GetUserStatus": .success((Data(), httpResponse(429, headers: ["Retry-After": "9"]))),
            "GetCommandModelConfigs": .success((Data(), httpResponse(429, headers: ["Retry-After": "9"]))),
        ]
        let strategy = AntigravityLocalProbeStrategy(processProbe: probe, transport: transport)

        do {
            _ = try await strategy.fetch()
            XCTFail("expected an error")
        } catch let error as AIUsageError {
            guard case .rateLimited(let id, let retryAfter) = error else {
                XCTFail("expected .rateLimited, got \(error)")
                return
            }
            XCTAssertEqual(id, "antigravity")
            XCTAssertEqual(retryAfter, 9)
        } catch {
            XCTFail("unexpected error type: \(error)")
        }
    }

    func testProviderIsAlwaysConfigured() {
        let provider = AntigravityUsageProvider()
        XCTAssertTrue(provider.isConfigured)
        XCTAssertEqual(provider.strategies.count, 1)
        XCTAssertEqual(provider.strategies[0].source, "local")
    }
}
