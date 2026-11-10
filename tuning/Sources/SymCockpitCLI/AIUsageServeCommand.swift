import Foundation
import SymCockpitCore

/// Explicit opt-in HTTP reader. Requests never fetch providers: the running GUI
/// or `ai-usage --force` writes the shared cache independently.
func runAIUsageServe(_ args: [String], controller: TuneController) throws {
    if args.contains("--help") || args.contains("-h") {
        emit("Usage: symcockpit ai-usage serve [--port 6737]")
        emit("Serves cached usage on 127.0.0.1 only. No provider requests. Stop with Ctrl-C.")
        emit("GET /v1/limits and /v1/usage, optionally followed by /provider-id.")
        emit("Browser-origin requests are refused. Other local processes can read the data.")
        return
    }
    let port: UInt16
    if args.isEmpty {
        port = 6737
    } else if args.count == 2, args[0] == "--port", let parsed = UInt16(args[1]) {
        port = parsed
    } else {
        throw TuneError.usage("ai-usage serve: expected --port 0...65535")
    }
    let snapshots = AIUsageLocalSnapshots()
    snapshots.replace(controller.cachedAIUsageReport())
    let server = AIUsageLocalServer(port: port, snapshots: snapshots.read)
    let done = DispatchSemaphore(value: 0)
    let oldInt = signal(SIGINT, SIG_IGN)
    let oldTerm = signal(SIGTERM, SIG_IGN)
    let signals = [SIGINT, SIGTERM].map { signalNumber in
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
        source.setEventHandler { done.signal() }
        source.resume()
        return source
    }
    defer {
        server.stop()
        signals.forEach { $0.cancel() }
        signal(SIGINT, oldInt)
        signal(SIGTERM, oldTerm)
    }
    let boundPort = try server.start()
    emit("AI usage API: http://127.0.0.1:\(boundPort) (cache only; Ctrl-C to stop)")
    while done.wait(timeout: .now() + 2) == .timedOut {
        snapshots.replace(controller.cachedAIUsageReport())
    }
}
