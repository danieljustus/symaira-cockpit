import XCTest

final class SymTuneCLITests: XCTestCase {

    /// Path to the built symtune binary.
    /// The test target uses the PRODUCT_BUNDLE_IDENTIFIER build setting
    /// injected by SPM to find the binary relative to the test bundle.
    var symtuneBinary: String {
        // SPM places the built product one directory up from the test bundle.
        let binDir = productsDirectory
        return binDir.appendingPathComponent("symtune").path
    }

    /// Returns the products directory (where the test bundle and symtune live).
    var productsDirectory: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            return bundle.bundleURL.deletingLastPathComponent()
        }
        fatalError("Could not locate the products directory — not running within an XCTest bundle?")
    }

    // MARK: - --help / -h on subcommands

    func testFanHelp() throws {
        let output = try runCommand(args: ["fan", "--help"])
        XCTAssert(output.contains("Usage: symtune fan"))
        XCTAssert(output.contains("<0.0-1.0>"))
    }

    func testFanHelpShort() throws {
        let output = try runCommand(args: ["fan", "-h"])
        XCTAssert(output.contains("Usage: symtune fan"))
    }

    func testDimHelp() throws {
        let output = try runCommand(args: ["dim", "--help"])
        XCTAssert(output.contains("Usage: symtune dim"))
    }

    func testWarmthHelp() throws {
        let output = try runCommand(args: ["warmth", "--help"])
        XCTAssert(output.contains("Usage: symtune warmth"))
    }

    func testBatteryLimitHelp() throws {
        let output = try runCommand(args: ["battery-limit", "--help"])
        XCTAssert(output.contains("Usage: symtune battery-limit"))
    }

    func testMetricsHelp() throws {
        let output = try runCommand(args: ["metrics", "--help"])
        XCTAssert(output.contains("Usage: symtune metrics"))
        XCTAssert(output.contains("system metrics"))
    }

    func testMetricsHelpShort() throws {
        let output = try runCommand(args: ["metrics", "-h"])
        XCTAssert(output.contains("Usage: symtune metrics"))
    }

    // MARK: Unknown-flag rejection

    func testFanUnknownFlag() throws {
        let output = try runCommand(args: ["fan", "--bogus"], expectFailure: true)
        XCTAssert(output.contains("unexpected argument"))
        XCTAssert(output.contains("--bogus"))
    }

    func testDimUnknownFlag() throws {
        let output = try runCommand(args: ["dim", "set", "--invalid"], expectFailure: true)
        XCTAssert(output.contains("unexpected argument"))
        XCTAssert(output.contains("--invalid"))
    }

    func testWarmthUnknownFlag() throws {
        let output = try runCommand(args: ["warmth", "--junk"], expectFailure: true)
        XCTAssert(output.contains("unexpected argument"))
        XCTAssert(output.contains("--junk"))
    }

    func testBatteryLimitUnknownFlag() throws {
        let output = try runCommand(args: ["battery-limit", "--unknown"], expectFailure: true)
        XCTAssert(output.contains("unexpected argument"))
        XCTAssert(output.contains("--unknown"))
    }

    func testMetricsUnknownFlag() throws {
        let output = try runCommand(args: ["metrics", "--bogus"], expectFailure: true)
        XCTAssert(output.contains("unexpected argument"))
        XCTAssert(output.contains("--bogus"))
    }

    func testMetricsJSON() throws {
        let output = try runCommand(args: ["metrics"])
        XCTAssert(output.contains("cpu"))
        XCTAssert(output.contains("memory"))
        XCTAssert(output.contains("network"))
    }

    func testAIUsageHelp() throws {
        let output = try runCommand(args: ["ai-usage", "--help"])
        XCTAssert(output.contains("ai-usage"))
        XCTAssert(output.contains("--json"))
    }

    func testAIUsageUnknownFlag() throws {
        _ = try runCommand(args: ["ai-usage", "--nope"], expectFailure: true)
    }

    func testAIUsageJSONListsProviders() throws {
        // Hermetic (issue #341): override OPENROUTER_API_KEY to an empty
        // value so the spawned binary short-circuits to "not configured"
        // before any Keychain read or network fetch — a machine with a real
        // key used to make this test perform a live openrouter.ai fetch and
        // take ~4 minutes.
        let output = try runCommand(
            args: ["ai-usage", "--json"],
            environment: ["OPENROUTER_API_KEY": ""]
        )
        XCTAssert(output.contains("openrouter"))
        XCTAssert(output.contains("provider_id"))
    }

    // MARK: - Always-JSON read commands (doctor, sensors, battery, displays, permissions)
    //
    // These five commands take no options: they should honour --help/-h
    // instead of running, and reject any other argument with a usage error
    // (exit code 2) instead of silently ignoring it.

    private static let alwaysJSONCommands = ["doctor", "sensors", "battery", "displays", "permissions"]

    func testAlwaysJSONCommandsHelp() throws {
        for command in Self.alwaysJSONCommands {
            let output = try runCommand(args: [command, "--help"])
            XCTAssert(output.contains("Usage: symtune \(command)"), "\(command) --help: \(output)")
            // Help output must not be the JSON report.
            XCTAssertFalse(output.contains("{"), "\(command) --help printed JSON instead of help: \(output)")
        }
    }

    func testAlwaysJSONCommandsHelpShort() throws {
        for command in Self.alwaysJSONCommands {
            let output = try runCommand(args: [command, "-h"])
            XCTAssert(output.contains("Usage: symtune \(command)"), "\(command) -h: \(output)")
            XCTAssertFalse(output.contains("{"), "\(command) -h printed JSON instead of help: \(output)")
        }
    }

    func testAlwaysJSONCommandsUnknownFlag() throws {
        for command in Self.alwaysJSONCommands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: symtuneBinary)
            process.arguments = [command, "--bogus"]
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            let waitForExit = armBoundedWait(process)
            try process.run()
            XCTAssertTrue(waitForExit(), "\(command) --bogus did not exit in time")

            let errorOutput = String(data: errorPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

            XCTAssertEqual(process.terminationStatus, 2,
                            "\(command) --bogus: expected ExitCode.usage (2), got \(process.terminationStatus). stderr: \(errorOutput)")
            XCTAssert(errorOutput.contains("unexpected argument"), "\(command) --bogus: \(errorOutput)")
            XCTAssert(errorOutput.contains("--bogus"), "\(command) --bogus: \(errorOutput)")
        }
    }

    func testDoctorJSON() throws {
        let output = try runCommand(args: ["doctor"])
        XCTAssert(output.contains("{"))
    }

    // MARK: - Unified --json contract (issue #315)
    //
    // Every read command accepts --json. The six always-JSON commands
    // (doctor, sensors, battery, displays, permissions, metrics) already
    // only have a machine form; --json must be a recognized no-op there,
    // not rejected by the #314 unexpected-argument check.

    private static let sixAlwaysJSONCommands = alwaysJSONCommands + ["metrics"]

    func testAlwaysJSONCommandsAcceptJSONFlagWithoutRejection() throws {
        for command in Self.sixAlwaysJSONCommands {
            let output = try runCommand(args: [command, "--json"])
            XCTAssert(output.contains("{"), "\(command) --json: expected JSON output, got: \(output)")
            XCTAssertFalse(output.contains("unexpected argument"),
                            "\(command) --json: flag should be a no-op, not rejected. Output: \(output)")
        }
    }

    func testAlwaysJSONCommandsJSONFlagIsNoOp() throws {
        // --json must not change the shape of the output: same top-level
        // keys with and without the flag.
        for command in Self.sixAlwaysJSONCommands {
            let plain = try runCommand(args: [command])
            let withFlag = try runCommand(args: [command, "--json"])

            guard let plainData = plain.data(using: .utf8),
                  let flagData = withFlag.data(using: .utf8),
                  let plainJSON = try? JSONSerialization.jsonObject(with: plainData) as? [String: Any],
                  let flagJSON = try? JSONSerialization.jsonObject(with: flagData) as? [String: Any] else {
                XCTFail("\(command): could not parse plain/--json output as a JSON object. plain: \(plain), --json: \(withFlag)")
                continue
            }
            XCTAssertEqual(Set(plainJSON.keys), Set(flagJSON.keys),
                            "\(command) --json: top-level keys should match the plain output")
        }
    }

    func testAlwaysJSONCommandsStillRejectOtherUnknownFlags() throws {
        // --json is a recognized no-op, but genuinely unknown flags must
        // still be rejected even when --json is also present.
        for command in Self.sixAlwaysJSONCommands {
            let output = try runCommand(args: [command, "--json", "--bogus"], expectFailure: true)
            XCTAssert(output.contains("unexpected argument"), "\(command) --json --bogus: \(output)")
            XCTAssert(output.contains("--bogus"), "\(command) --json --bogus: \(output)")
        }
    }

    // MARK: - Helpers

    /// Registers a bounded termination wait, mirroring `ServeChild` in
    /// `SymTuneServeIntegrationTests.swift`: the handler must be set *before*
    /// `process.run()` so a process that exits immediately still signals.
    /// Never use `waitUntilExit()` here — it blocks forever if the child
    /// itself hangs (e.g. on a wedged Keychain read in a headless/no-GUI
    /// -session environment). On timeout the child is force-terminated so a
    /// hang surfaces as a fast, clear test failure instead of stalling the
    /// whole suite for minutes.
    private func armBoundedWait(_ process: Process) -> () -> Bool {
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        return {
            if done.wait(timeout: .now() + 15) == .timedOut {
                process.terminate()
                _ = done.wait(timeout: .now() + 3)
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                return false
            }
            return true
        }
    }

    /// Run `symtune` with the given arguments and return stderr (merged with stdout).
    /// - Parameters:
    ///   - args: Arguments to pass to the binary.
    ///   - expectFailure: If true, the process is expected to exit with a non-zero code.
    ///   - environment: Additional environment overrides applied on top of the
    ///     parent's environment (Foundation `Process` replaces the whole
    ///     environment when set, so the parent's is copied first).
    /// - Returns: The combined stdout+stderr output of the process.
    @discardableResult
    private func runCommand(
        args: [String],
        expectFailure: Bool = false,
        environment: [String: String] = [:]
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: symtuneBinary)
        process.arguments = args

        if !environment.isEmpty {
            var childEnvironment = ProcessInfo.processInfo.environment
            for (key, value) in environment {
                childEnvironment[key] = value
            }
            process.environment = childEnvironment
        }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        let waitForExit = armBoundedWait(process)
        try process.run()
        XCTAssertTrue(waitForExit(), "symtune \(args.joined(separator: " ")) did not exit in time")

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8) ?? ""
        let errorOutput = String(data: errorData, encoding: .utf8) ?? ""
        let combined = output + errorOutput

        if expectFailure {
            XCTAssertNotEqual(process.terminationStatus, 0,
                              "Expected failure but process succeeded. args: \(args)")
        } else {
            XCTAssertEqual(process.terminationStatus, 0,
                           "Process failed. args: \(args), stderr: \(errorOutput)")
        }

        return combined
    }
}
