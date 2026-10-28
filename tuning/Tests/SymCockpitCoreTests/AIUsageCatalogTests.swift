import Foundation
import XCTest
@testable import SymCockpitCore

final class AIUsageCatalogTests: XCTestCase {
    func testStableCatalogAndNewDescriptorsAreMetadataOnly() throws {
        let catalog = SymBrainUsageProvider.catalog()
        XCTAssertEqual(catalog.map(\.id), [
            "claude", "codex", "copilot", "cursor", "kimi", "moonshot", "nous",
            "opencode", "openrouter", "antigravity", "zai", "devin", "grok", "ollama",
        ])
        XCTAssertEqual(catalog.count, 14)
        for (id, name, account) in [
            ("zai", "Z.ai", "zai-api-key"),
            ("devin", "Devin", "devin-api-key"),
            ("grok", "Grok", "grok-access-token"),
            ("opencode", "OpenCode Go", "opencode-go-api-key"),
        ] {
            let provider = try XCTUnwrap(catalog.first { $0.id == id })
            XCTAssertEqual(provider.displayName, name)
            XCTAssertFalse(provider.isConfigured)
            let descriptor = try XCTUnwrap(provider.credentialDescriptor)
            guard case .apiKey(let actual) = descriptor.authKind else { return XCTFail(id) }
            XCTAssertEqual(actual, account)
        }
        let ollama = try XCTUnwrap(catalog.first { $0.id == "ollama" })
        XCTAssertEqual(ollama.displayName, "Ollama Cloud")
        guard case .externalToken(let resolver) = try XCTUnwrap(ollama.credentialDescriptor).authKind else {
            return XCTFail("Ollama must not offer an API-key field")
        }
        XCTAssertEqual(resolver.read().status, .missing)
        XCTAssertFalse(SymVaultEntryPaths.supportedProviderIDs.contains("ollama"))
        XCTAssertNil(SymVaultEntryPaths(["ollama": "ignored/key"]).reference(for: "ollama"))
    }

    func testDefaultLocalDiscoveryAndExplicitReferences() {
        let defaults = SymVaultEntryPaths()
        XCTAssertNil(defaults.reference(for: "grok"))
        XCTAssertNil(defaults.reference(for: "devin"))
        XCTAssertEqual(defaults.reference(for: "zai"), "symvault://symtune/zai")
        for id in ["grok", "devin", "opencode"] {
            XCTAssertEqual(SymVaultEntryPaths([id: "existing/work"]).reference(for: id), "symvault://existing/work")
            XCTAssertEqual(SymVaultEntryPaths([id: "symtune/" + id]).reference(for: id), "symvault://symtune/" + id)
            XCTAssertEqual(AIUsageFormatting.unavailableReason(
                providerID: id, error: AIUsageService.notConfiguredMessage, entryPaths: defaults
            ), AIUsageService.notConfiguredMessage)
        }
    }

    func testExactSelectedCommandEnvironmentAndDisabledReferenceIsolation() throws {
        let recorder = CatalogRecorder()
        let paths = SymVaultEntryPaths(["devin": "cli/work", "grok": "grok/work"])
        let client = SymBrainUsageClient(runner: recorder, environment: [
            "PATH": "/fixture/bin", "ZAI_API_KEY": "user-supplied-fixture",
            "OPENROUTER_API_KEY": "disabled-fixture", "GROK_HOME": "/fixture/grok",
        ], credentialReference: { id in
            recorder.references.append(id)
            return paths.reference(for: id)
        })
        XCTAssertTrue(recorder.references.isEmpty)
        _ = try client.fetchReport(providerIDs: ["zai", "devin", "grok", "ollama"])
        XCTAssertEqual(recorder.arguments, ["usage", "--output", "json", "--providers", "devin,grok,ollama,zai"])
        XCTAssertEqual(recorder.environment, [
            "PATH": "/fixture/bin", "ZAI_API_KEY": "user-supplied-fixture",
            "DEVIN_API_KEY": "symvault://cli/work", "GROK_ACCESS_TOKEN": "symvault://grok/work",
            "GROK_HOME": "/fixture/grok",
        ])
        XCTAssertEqual(Set(recorder.references), ["devin", "grok"])
        recorder.references = []
        _ = try client.fetchReport(providerIDs: ["ollama"])
        XCTAssertEqual(recorder.arguments.last, "ollama")
        XCTAssertEqual(recorder.environment, ["PATH": "/fixture/bin", "GROK_HOME": "/fixture/grok"])
        XCTAssertTrue(recorder.references.isEmpty)
    }

    func testSelectedLocalAuthReceivesNoSynthesizedReferenceAndUserEnvironmentWins() throws {
        let recorder = CatalogRecorder()
        let client = SymBrainUsageClient(runner: recorder, environment: ["GROK_HOME": "/fixture/grok"],
            credentialReference: { SymVaultEntryPaths().reference(for: $0) })
        _ = try client.fetchReport(providerIDs: ["grok", "devin"])
        XCTAssertEqual(recorder.environment, ["GROK_HOME": "/fixture/grok"])
        let explicit = SymBrainUsageClient(runner: recorder, environment: [
            "GROK_ACCESS_TOKEN": "fixture-token", "DEVIN_API_KEY": "fixture-cli-key",
        ], credentialReference: { _ in XCTFail("User environment must win"); return nil })
        _ = try explicit.fetchReport(providerIDs: ["grok", "devin"])
        XCTAssertEqual(recorder.environment, ["GROK_ACCESS_TOKEN": "fixture-token", "DEVIN_API_KEY": "fixture-cli-key"])
    }

    func testExplicitReferenceFailureNeverRetriesLocalDiscovery() {
        for (id, key) in [("grok", "GROK_ACCESS_TOKEN"), ("opencode", "OPENCODE_GO_API_KEY")] {
            let recorder = CatalogRecorder()
            recorder.status = 1
            let client = SymBrainUsageClient(runner: recorder, environment: [:],
                credentialReference: { _ in "symvault://missing/explicit" })
            XCTAssertThrowsError(try client.fetchReport(providerIDs: [id]))
            XCTAssertEqual(recorder.calls, 1)
            XCTAssertEqual(recorder.environment, [key: "symvault://missing/explicit"])
        }
    }

    func testOpenCodeDiscoveryExplicitKeyPrecedenceAndDisabledIsolation() throws {
        let discovery = [
            "OPENCODE_DATA_DIR": "/fixture/opencode", "XDG_DATA_HOME": "/fixture/data",
            "XDG_CONFIG_HOME": "/fixture/config", "HOME": "/fixture/home",
            "OPENCODE_COOKIE": "fixture-cookie", "OPENCODE_WORKSPACE_ID": "fixture-workspace",
        ]
        for apiKey in [nil, "", "env://FIXTURE_GO_KEY", "symvault://user/go"] as [String?] {
            let recorder = CatalogRecorder()
            var environment = discovery
            environment["OPENCODE_GO_API_KEY"] = apiKey
            let client = SymBrainUsageClient(runner: recorder, environment: environment,
                credentialReference: { id in
                    recorder.references.append(id)
                    return SymVaultEntryPaths().reference(for: id)
                })
            XCTAssertTrue(recorder.references.isEmpty)
            _ = try client.fetchReport(providerIDs: ["opencode"])
            XCTAssertEqual(recorder.environment, environment, "No invented default; preserve native/cookie paths")
            XCTAssertEqual(recorder.references, apiKey?.isEmpty == false ? [] : ["opencode"])
        }
        let recorder = CatalogRecorder()
        let paths = SymVaultEntryPaths(["opencode": "existing/go"])
        let client = SymBrainUsageClient(runner: recorder, environment: discovery,
            credentialReference: { id in recorder.references.append(id); return paths.reference(for: id) })
        _ = try client.fetchReport(providerIDs: ["opencode"])
        XCTAssertEqual(recorder.environment, discovery.merging(["OPENCODE_GO_API_KEY": "symvault://existing/go"]) { _, new in new })
        XCTAssertEqual(recorder.references, ["opencode"])
        let disabled = SymBrainUsageClient(runner: recorder,
            environment: discovery.merging(["OPENCODE_GO_API_KEY": "symvault://poison/disabled"]) { _, new in new },
            credentialReference: { _ in XCTFail("Disabled provider must not request a reference"); return nil })
        _ = try disabled.fetchReport(providerIDs: ["ollama"])
        XCTAssertEqual(recorder.environment, discovery)
    }
}

private final class CatalogRecorder: SymBrainCommandRunner, @unchecked Sendable {
    var arguments: [String] = []
    var environment: [String: String] = [:]
    var references: [String] = []
    var status: Int32 = 0
    var calls = 0
    func run(arguments: [String], environment: [String: String]) throws -> SymBrainCommandResult {
        self.arguments = arguments
        self.environment = environment
        calls += 1
        return SymBrainCommandResult(standardOutput: Data(#"{"schema_version":1,"providers":[]}"#.utf8),
                                     standardError: Data(), terminationStatus: status)
    }
}
