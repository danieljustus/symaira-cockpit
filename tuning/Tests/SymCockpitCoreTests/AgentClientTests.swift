import XCTest
@testable import SymCockpitCore

/// `AgentClient` against a fake agent: a small Perl script (Perl and its core
/// JSON::PP ship with macOS) that speaks the protocol of docs/agent-protocol.md
/// over stdin/stdout. No Rust binary, hardware or permission is involved.
///
/// The scenario is the script's first argument:
/// `ok`, `version` (hello refused with -32010), `refuse` (stderr + exit 3),
/// `garbage` (non-JSON stdout), `silent` (never answers) and `crash`
/// (exits 7 on the first `call`).
final class AgentClientTests: XCTestCase {

    private static let script = #"""
    use strict; use warnings; use JSON::PP;
    $| = 1;
    my $scenario = shift @ARGV // 'ok';
    my $json = JSON::PP->new->canonical;
    if ($scenario eq 'refuse') {
        print STDERR "symcockpit: agent: the parent process is not the signed com.symaira.cockpit app\n";
        exit 3;
    }
    sub send_frame { print $json->encode($_[0]), "\n"; }
    sub reply { send_frame({ jsonrpc => "2.0", id => $_[0], result => $_[1] }); }
    sub fail  { send_frame({ jsonrpc => "2.0", id => $_[0], error => $_[1] }); }
    sub event {
        my ($sub, $seq) = @_;
        send_frame({ jsonrpc => "2.0", method => "event", params => {
            subscription_id => $sub, command => "metrics", seq => $seq,
            monotonic_ms => 100 * $seq, result => { cpu => $seq } } });
    }
    my $hello = {
        protocol_version => 1, server_version => "9.9.9-fake",
        capabilities => {
            methods => ["hello", "call", "confirm", "subscribe", "unsubscribe", "set_visibility", "ping"],
            topics => ["metrics"], max_subscriptions => 32, min_interval_ms => 100,
            max_interval_ms => 3600000, default_interval_visible_ms => 1000,
            default_interval_hidden_ms => 10000 },
        commands => [
            { name => "metrics", risk => "read", input_schema => { type => "object" } },
            { name => "fan.set", risk => "risky", input_schema => { type => "object" } } ] };
    while (my $line = <STDIN>) {
        chomp $line;
        next unless length $line;
        my $req = eval { $json->decode($line) } or next;
        my ($id, $method, $p) = ($req->{id}, $req->{method}, $req->{params} // {});
        if ($method eq 'hello') {
            next if $scenario eq 'silent';
            if ($scenario eq 'garbage') { print "this is not json\n"; next; }
            if ($scenario eq 'version') {
                fail($id, { code => -32010, message => "protocol version 1 is not supported (this agent speaks 7)",
                            data => { supported => [7], requested => 1 } });
                next;
            }
            reply($id, $hello);
        } elsif ($method eq 'call') {
            exit 7 if $scenario eq 'crash';
            my $c = $p->{command};
            if ($c eq 'bluetooth.scan') {
                fail($id, { code => -32000, message => "permission error: Bluetooth access was not granted",
                            data => { exit_code => 3, class => "permission" } });
            } elsif ($c eq 'fan.set') {
                reply($id, { status => "confirmation_required", command => $c, risk => "risky",
                             plan => { id => "pl_1", state => "pending", items => [ { command => $c, params => $p->{params} } ] } });
            } else {
                reply($id, { status => "ok", command => $c, risk => "read",
                             output => { echo => $c, params => $p->{params} } });
            }
        } elsif ($method eq 'confirm') {
            reply($id, { plan_id => $p->{plan_id}, status => "confirmed", output => { applied => JSON::PP::true } });
        } elsif ($method eq 'subscribe') {
            reply($id, { subscription_id => 1, command => $p->{command}, interval_ms => 1000 });
            event(1, $_) for 1 .. 3;
        } elsif ($method eq 'unsubscribe') {
            reply($id, { subscription_id => $p->{subscription_id}, active => 0 });
        } elsif ($method eq 'set_visibility') {
            reply($id, { visible => $p->{visible}, active => 0 });
        } else {
            fail($id, { code => -32601, message => "Method not found: $method" });
        }
    }
    exit 0;
    """#

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agent-client-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.script.write(to: directory.appendingPathComponent("fake-agent.pl"), atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [AgentEvent] = []
        private var _states: [AgentState] = []
        var events: [AgentEvent] { lock.lock(); defer { lock.unlock() }; return _events }
        var states: [AgentState] { lock.lock(); defer { lock.unlock() }; return _states }
        func add(_ event: AgentEvent) { lock.lock(); _events.append(event); lock.unlock() }
        func add(_ state: AgentState) { lock.lock(); _states.append(state); lock.unlock() }
    }

    private func client(
        _ scenario: String, recorder: Recorder = Recorder(), startTimeout: TimeInterval = 10
    ) -> AgentClient {
        AgentClient(
            configuration: .init(
                executable: URL(fileURLWithPath: "/usr/bin/perl"),
                arguments: [directory.appendingPathComponent("fake-agent.pl").path, scenario],
                startTimeout: startTimeout, requestTimeout: 5
            ),
            onEvent: { recorder.add($0) },
            onStateChange: { recorder.add($0) }
        )
    }

    private func waitFor(_ description: String, timeout: TimeInterval = 5, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        XCTAssertTrue(condition(), "timed out waiting for \(description)")
    }

    // MARK: - Handshake

    func testHelloReturnsTheAgentsVersionCapabilitiesAndRegister() async throws {
        let recorder = Recorder()
        let agent = client("ok", recorder: recorder)
        let hello = try await agent.start()
        defer { agent.stop() }
        XCTAssertEqual(hello.protocolVersion, 1)
        XCTAssertEqual(hello.serverVersion, "9.9.9-fake")
        XCTAssertEqual(hello.topics, ["metrics"])
        XCTAssertEqual(hello.commands.map(\.name), ["metrics", "fan.set"])
        XCTAssertEqual(hello.commands.map(\.risk), ["read", "risky"])
        XCTAssertEqual([hello.minIntervalMs, hello.defaultVisibleMs, hello.defaultHiddenMs], [100, 1000, 10000])
        XCTAssertEqual(agent.state, .ready(hello))
        XCTAssertEqual(recorder.states, [.starting, .ready(hello)])
        // A second start does not launch a second agent.
        let again = try await agent.start()
        XCTAssertEqual(again, hello)
    }

    func testAMissingExecutableIsADiagnosisNotACrash() async {
        let agent = AgentClient(configuration: .init(
            executable: directory.appendingPathComponent("no-such-agent")
        ))
        do {
            _ = try await agent.start()
            XCTFail("expected a failure")
        } catch let failure as AgentFailure {
            XCTAssertEqual(failure, .executableMissing(path: directory.appendingPathComponent("no-such-agent").path))
            XCTAssertTrue(failure.localizedDescription.contains("missing"))
            XCTAssertEqual(agent.state, .failed(failure))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testAnotherProtocolVersionFailsWithBothVersions() async {
        let agent = client("version")
        do {
            _ = try await agent.start()
            XCTFail("expected a failure")
        } catch let failure as AgentFailure {
            XCTAssertEqual(failure, .versionMismatch(clientVersion: 1, agentVersions: [7]))
            XCTAssertTrue(failure.localizedDescription.contains("version 7"))
            XCTAssertEqual(agent.state, .failed(failure))
        } catch {
            XCTFail("\(error)")
        }
        // No request is served by a failed agent.
        do {
            _ = try await agent.call("metrics")
            XCTFail("expected notRunning")
        } catch {
            XCTAssertEqual(error as? AgentFailure, .notRunning)
        }
    }

    func testAnAgentThatRefusesToStartReportsExit3WithItsStderr() async {
        let agent = client("refuse")
        do {
            _ = try await agent.start()
            XCTFail("expected a failure")
        } catch let failure as AgentFailure {
            guard case .exited(let status, let stderr) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(status, 3)
            XCTAssertTrue(stderr.contains("not the signed com.symaira.cockpit app"), stderr)
            XCTAssertTrue(failure.localizedDescription.contains("signed Symaira Cockpit app"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testNonProtocolOutputIsAProtocolViolation() async {
        let agent = client("garbage")
        do {
            _ = try await agent.start()
            XCTFail("expected a failure")
        } catch let failure as AgentFailure {
            guard case .protocolViolation(let reason) = failure else { return XCTFail("\(failure)") }
            XCTAssertTrue(reason.contains("this is not json"), reason)
        } catch {
            XCTFail("\(error)")
        }
    }

    func testASilentAgentTimesOutTheHandshake() async {
        let agent = client("silent", startTimeout: 0.3)
        do {
            _ = try await agent.start()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? AgentFailure, .timedOut("hello"))
            XCTAssertEqual(agent.state, .failed(.timedOut("hello")))
        }
    }

    // MARK: - Calls

    func testCallReturnsTheOutputAndAPlanForARiskyCommand() async throws {
        let agent = client("ok")
        try await agent.start()
        defer { agent.stop() }
        let direct = try await agent.call("metrics", params: ["n": .number(2)])
        XCTAssertEqual(direct, .ok(
            command: "metrics", risk: "read",
            output: .object(["echo": .string("metrics"), "params": .object(["n": .number(2)])])
        ))
        let planned = try await agent.call("fan.set", params: ["fraction": .number(0.7)])
        guard case .confirmationRequired(let command, let planID, let plan) = planned else {
            return XCTFail("\(planned)")
        }
        XCTAssertEqual([command, planID], ["fan.set", "pl_1"])
        XCTAssertEqual(plan["state"]?.stringValue, "pending")
        let confirmed = try await agent.confirm(planID: planID)
        XCTAssertEqual(confirmed["status"]?.stringValue, "confirmed")
        XCTAssertEqual(confirmed["output"]?["applied"]?.boolValue, true)
    }

    func testAMissingPermissionKeepsItsExitClass() async throws {
        let agent = client("ok")
        try await agent.start()
        defer { agent.stop() }
        do {
            _ = try await agent.call("bluetooth.scan")
            XCTFail("expected an error")
        } catch let error as AgentRemoteError {
            XCTAssertEqual(error.exitClass, "permission")
            XCTAssertEqual(error.exitCode, 3)
            XCTAssertEqual(error.code, -32000)
            XCTAssertEqual(error.localizedDescription, "permission error: Bluetooth access was not granted")
        }
        // The agent is still usable after a command error.
        let result = try await agent.call("metrics")
        guard case .ok = result else { return XCTFail("\(result)") }
        XCTAssertEqual(agent.state.isReady, true)
    }

    // MARK: - Subscriptions

    func testSubscriptionEventsReachTheCallbackInOrder() async throws {
        let recorder = Recorder()
        let agent = client("ok", recorder: recorder)
        try await agent.start()
        defer { agent.stop() }
        let id = try await agent.subscribe("metrics", visibleMs: 200, hiddenMs: 2000)
        XCTAssertEqual(id, 1)
        waitFor("three events") { recorder.events.count == 3 }
        XCTAssertEqual(recorder.events.map(\.sequence), [1, 2, 3])
        XCTAssertEqual(recorder.events.map(\.monotonicMs), [100, 200, 300])
        XCTAssertEqual(recorder.events[0].payload, .result(.object(["cpu": .number(1)])))
        XCTAssertTrue(recorder.events.allSatisfy { $0.subscriptionID == 1 && $0.command == "metrics" && !$0.ended })
        try await agent.setVisibility(false)
        try await agent.unsubscribe(id)
    }

    // MARK: - Failure and restart

    func testACrashFailsThePendingCallWithTheExitStatusAndRestartRecovers() async throws {
        let recorder = Recorder()
        let agent = client("crash", recorder: recorder)
        try await agent.start()
        do {
            _ = try await agent.call("metrics")
            XCTFail("expected a failure")
        } catch let failure as AgentFailure {
            guard case .exited(let status, _) = failure else { return XCTFail("\(failure)") }
            XCTAssertEqual(status, 7)
        }
        XCTAssertEqual(agent.state, .failed(.exited(status: 7, stderr: "")))
        // No value is invented while it is down.
        do {
            _ = try await agent.call("metrics")
            XCTFail("expected notRunning")
        } catch {
            XCTAssertEqual(error as? AgentFailure, .notRunning)
        }
        // The caller restarts; the new process answers the handshake again.
        let hello = try await agent.restart()
        defer { agent.stop() }
        XCTAssertEqual(agent.state, .ready(hello))
        XCTAssertEqual(
            recorder.states.map(\.label),
            ["starting", "ready", "failed", "stopped", "starting", "ready"]
        )
    }

    func testStopEndsTheAgentThroughEndOfInput() async throws {
        let recorder = Recorder()
        let agent = client("ok", recorder: recorder)
        try await agent.start()
        agent.stop()
        XCTAssertEqual(agent.state, .stopped)
        // A stopped client is not a failure, and cannot serve requests.
        do {
            _ = try await agent.call("metrics")
            XCTFail("expected notRunning")
        } catch {
            XCTAssertEqual(error as? AgentFailure, .notRunning)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(agent.state, .stopped, "the clean exit after stop is not reported as a crash")
    }
}

private extension AgentState {
    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var label: String {
        switch self {
        case .stopped: "stopped"
        case .starting: "starting"
        case .ready: "ready"
        case .failed: "failed"
        }
    }
}
