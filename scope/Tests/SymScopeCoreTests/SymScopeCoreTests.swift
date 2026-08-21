import XCTest
@testable import SymScopeCore

final class JSONCTests: XCTestCase {
    func testStripsLineComments() {
        let input = """
        {
          // comment
          "a": 1 // trailing
        }
        """
        let output = JSONC.strip(input)
        XCTAssertFalse(output.contains("comment"))
        XCTAssertFalse(output.contains("trailing"))
        XCTAssertTrue(output.contains("\"a\": 1"))
    }

    func testStripsBlockComments() {
        let input = """
        { /* block */ "a": 1 /* mid */ , "b": 2 }
        """
        let output = JSONC.strip(input)
        XCTAssertFalse(output.contains("block"))
        XCTAssertFalse(output.contains("mid"))
        XCTAssertTrue(output.contains("\"a\": 1"))
    }

    func testPreservesCommentInsideString() {
        let input = #"{ "note": "// not a comment", "a": 1 }"#
        let output = JSONC.strip(input)
        XCTAssertTrue(output.contains("// not a comment"))
    }

    func testPreservesEscapedQuote() {
        let input = #"{ "s": "a\"//b", "a": 1 }"#
        let output = JSONC.strip(input)
        XCTAssertTrue(output.contains(#"a\"//b"#))
    }

    func testStrippedOutputIsValidJSON() throws {
        let input = """
        {
          // line
          "mcpServers": {
            "github": { "command": "gh", "args": ["mcp"] }, /* block */
          }
        }
        """
        let output = JSONC.strip(input)
        let data = output.data(using: .utf8)!
        _ = try JSONSerialization.jsonObject(with: data)
    }
}

final class PortParseTests: XCTestCase {
    func testParseIPv4Address() {
        let parsed = PortService.parseAddress("127.0.0.1:8080")
        XCTAssertEqual(parsed?.port, 8080)
        XCTAssertEqual(parsed?.address, "127.0.0.1")
    }

    func testParseWildcard() {
        let parsed = PortService.parseAddress("*:5000")
        XCTAssertEqual(parsed?.port, 5000)
        XCTAssertEqual(parsed?.address, "*")
    }

    func testParseIPv6() {
        let parsed = PortService.parseAddress("[::1]:9000")
        XCTAssertEqual(parsed?.port, 9000)
        XCTAssertEqual(parsed?.address, "::1")
    }

    func testParseInvalid() {
        XCTAssertNil(PortService.parseAddress("not-a-port"))
        XCTAssertNil(PortService.parseAddress(":abc"))
    }

    func testParseLsofOutput() {
        let output = """
        p123
        cnode
        n127.0.0.1:8080
        p456
        cpython
        n0.0.0.0:5000
        """
        let ports = PortService.parseLsofOutput(output, protocol_: "tcp")
        XCTAssertEqual(ports.count, 2)
        XCTAssertEqual(ports[0].pid, 123)
        XCTAssertEqual(ports[0].process, "node")
        XCTAssertEqual(ports[0].port, 8080)
        XCTAssertEqual(ports[1].pid, 456)
        XCTAssertEqual(ports[1].process, "python")
        XCTAssertEqual(ports[1].port, 5000)
    }

    func testParseLsofSkipsEntriesWithoutAddress() {
        let output = """
        p123
        cnode
        p456
        cpython
        n127.0.0.1:9000
        """
        let ports = PortService.parseLsofOutput(output, protocol_: "tcp")
        XCTAssertEqual(ports.count, 1)
        XCTAssertEqual(ports[0].pid, 456)
    }
}

final class ContainerPortParseTests: XCTestCase {
    func testParsePublishedPortsSimple() {
        let ports = ContainerService.parsePublishedPorts("0.0.0.0:8080->80/tcp")
        XCTAssertEqual(ports, [8080])
    }

    func testParsePublishedPortsIPv6() {
        let ports = ContainerService.parsePublishedPorts(":::8080->80/tcp")
        XCTAssertEqual(ports, [8080])
    }

    func testParseMultiple() {
        let ports = ContainerService.parsePublishedPorts("0.0.0.0:8080->80/tcp, 0.0.0.0:8443->443/tcp")
        XCTAssertEqual(ports, [8080, 8443])
    }

    func testParseNoPorts() {
        XCTAssertEqual(ContainerService.parsePublishedPorts(""), [])
        XCTAssertEqual(ContainerService.parsePublishedPorts("80/tcp"), [])
    }
}

final class ConflictDetectorTests: XCTestCase {
    func testDetectsSamePortDifferentProcesses() {
        let ports = [
            Port(port: 8080, protocol_: "tcp", address: "127.0.0.1", pid: 100, process: "node"),
            Port(port: 8080, protocol_: "tcp", address: "0.0.0.0", pid: 200, process: "python"),
            Port(port: 9090, protocol_: "tcp", address: "127.0.0.1", pid: 300, process: "nginx"),
        ]
        let conflicts = ConflictDetector.detect(ports)
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts[0].port, 8080)
        XCTAssertEqual(conflicts[0].kind, "process-process")
    }

    func testIgnoresSameProcessTwice() {
        let ports = [
            Port(port: 8080, protocol_: "tcp", address: "127.0.0.1", pid: 100, process: "node"),
            Port(port: 8080, protocol_: "tcp", address: "::1", pid: 100, process: "node"),
        ]
        XCTAssertEqual(ConflictDetector.detect(ports).count, 0)
    }
}

final class VersionTests: XCTestCase {
    func testVersionInfoSchema() {
        let info = Version.info()
        XCTAssertEqual(info.tool, "symscope")
        XCTAssertEqual(info.schemaVersion, 1)
        XCTAssertFalse(info.version.isEmpty)
    }
}
