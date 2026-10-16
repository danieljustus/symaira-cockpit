import Foundation
import SymairaMCP
import os
@testable import SymCockpitMCP
@testable import SymCockpitCore

/// Boots a TuneMCPServer with write-isolated defaults on an in-process pipe pair.
struct MCPTestHarness {
    let server: MCPServer
    let clientWrite: FileHandle
    let reader: LineReader
    let serverTask: Task<Void, Error>

    static func make(
        controller: TuneController? = nil,
        config: TuneConfig = TuneConfig(),
        powerSource: any PowerAssertionSource = MockMCPPowerAssertionSource()
    ) throws -> MCPTestHarness {
        // Default protocol tests must never write to the host's display, SMC
        // or power assertions. Tests for successful SMC writes inject their own mock.
        let unavailableSMC = MockSMCConnection()
        unavailableSMC.isOpen = false
        let controller = controller ?? TuneController(
            displayWrite: MockMCPDisplayWriteService(),
            smcService: SMCService(connection: unavailableSMC),
            batterySource: MockBatterySource(),
            keepAwakeSource: powerSource
        )
        let clientToServer = Pipe()
        let serverToClient = Pipe()
        let transport = MCPStdioTransport(
            input: clientToServer.fileHandleForReading,
            output: serverToClient.fileHandleForWriting
        )
        let tuneServer = TuneMCPServer(controller: controller, config: config)
        let server = tuneServer.makeServer()
        // Detached: async XCTest methods run on a special executor that never
        // schedules unstructured tasks created inside the test body.
        let serverTask = Task.detached { try await server.start(transport: transport) }
        return MCPTestHarness(
            server: server,
            clientWrite: clientToServer.fileHandleForWriting,
            reader: LineReader(handle: serverToClient.fileHandleForReading),
            serverTask: serverTask
        )
    }
}

final class MockMCPPowerAssertionSource: PowerAssertionSource, Sendable {
    private let state = OSAllocatedUnfairLock(initialState: (created: 0, released: 0))

    var counts: (created: Int, released: Int) { state.withLock { $0 } }

    func create(type: PowerAssertionType, reason: String) throws -> UInt32 {
        state.withLock {
            $0.created += 1
            return UInt32($0.created)
        }
    }

    func release(_ assertionID: UInt32) { state.withLock { $0.released += 1 } }
}
