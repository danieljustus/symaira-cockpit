import XCTest
@testable import SymScopeMCP

final class SymScopeMCPTests: XCTestCase {
    func testToolsList() async throws {
        let server = SymScopeMCPServer()
        let result = try await server.dispatch(method: "tools/list")
        let tools = result["tools"] as? [[String: Any]]
        XCTAssertNotNil(tools)
        let names = tools?.compactMap { $0["name"] as? String } ?? []
        XCTAssertEqual(names, ["scan", "ports_list", "ports_suggest", "mcp_list", "conflicts", "mcp_health"])
    }

    func testPing() async throws {
        let server = SymScopeMCPServer()
        let result = try await server.dispatch(method: "ping")
        XCTAssertEqual(result.count, 0)
    }

    func testUnknownMethodThrows() async {
        let server = SymScopeMCPServer()
        do {
            _ = try await server.dispatch(method: "unknown/method")
            XCTFail("Expected error")
        } catch {
            // expected
        }
    }

    func testUnknownToolThrows() async {
        let server = SymScopeMCPServer()
        do {
            _ = try await server.dispatch(method: "tools/call", params: ["name": "nope"])
            XCTFail("Expected error")
        } catch {
            // expected
        }
    }

    func testMissingToolNameThrows() async {
        let server = SymScopeMCPServer()
        do {
            _ = try await server.dispatch(method: "tools/call", params: [:])
            XCTFail("Expected error")
        } catch {
            // expected
        }
    }
}
