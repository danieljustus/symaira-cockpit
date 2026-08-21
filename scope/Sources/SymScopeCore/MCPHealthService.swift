import Foundation

/// Health probes for configured MCP servers. stdio servers are probed by
/// spawning with a short timeout and reading stderr; http/sse servers by a
/// lightweight GET. Never blocks forever — every probe is bounded.
public enum MCPHealthService: Sendable {
    /// Probe every server; results carry per-server latency/status.
    public static func checkAll(_ servers: [MCPServer], timeoutSeconds: Double = 5) async -> [MCPHealthResult] {
        var results: [MCPHealthResult] = []
        for server in servers {
            results.append(await check(server, timeoutSeconds: timeoutSeconds))
        }
        return results
    }

    public static func check(_ server: MCPServer, timeoutSeconds: Double = 5) async -> MCPHealthResult {
        let start = Date()
        switch server.transport {
        case "stdio":
            let ok = await probeStdio(server, timeoutSeconds: timeoutSeconds)
            let latency = Int64((Date().timeIntervalSince(start) * 1000).rounded())
            return MCPHealthResult(
                name: server.name,
                client: server.client,
                status: ok ? "healthy" : "unhealthy",
                latencyMs: latency,
                error: ok ? nil : "stdio spawn/read failed"
            )
        case "http", "sse":
            guard let url = server.url, let parsed = URL(string: url) else {
                return MCPHealthResult(name: server.name, client: server.client, status: "unhealthy", latencyMs: 0, error: "missing url")
            }
            let ok = await probeHTTP(parsed, timeoutSeconds: timeoutSeconds)
            let latency = Int64((Date().timeIntervalSince(start) * 1000).rounded())
            return MCPHealthResult(
                name: server.name,
                client: server.client,
                status: ok ? "healthy" : "unhealthy",
                latencyMs: latency,
                error: ok ? nil : "http probe failed"
            )
        default:
            return MCPHealthResult(name: server.name, client: server.client, status: "unknown", latencyMs: 0)
        }
    }

    // MARK: - Probes

    private static func probeStdio(_ server: MCPServer, timeoutSeconds: Double) async -> Bool {
        guard let command = server.command else { return false }
        // Resolve binary via PATH (Process uses PATH when executableURL has no slash).
        let process = Process()
        if command.contains("/") {
            process.executableURL = URL(fileURLWithPath: command)
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [command] + server.args
        }
        let errPipe = Pipe()
        process.standardOutput = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
        } catch {
            return false
        }
        // Bounded wait — give up after timeout.
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                return false
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return process.terminationStatus == 0
    }

    private static func probeHTTP(_ url: URL, timeoutSeconds: Double) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                return (200..<400).contains(http.statusCode)
            }
            return true
        } catch {
            return false
        }
    }
}
