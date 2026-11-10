import Darwin
import Foundation
import XCTest
@testable import SymCockpitCore

final class AIUsageLocalAPITests: XCTestCase {
    private let instant = Date(timeIntervalSince1970: 1_700_000_000)

    private func fixture() -> [AIUsageService.ProviderResult] {
        [AIUsageService.ProviderResult(providerID: "fixture", snapshot: AIUsageSnapshot(
            providerID: "fixture", meters: [
                AIUsageMeter(label: "Session", used: 42, limit: 100, unit: .percent),
                AIUsageMeter(label: "Missing", unit: .tokens),
                AIUsageMeter(label: "Limit only", limit: 50, unit: .requests),
                AIUsageMeter(label: "Zero", used: 0, unit: .credits),
                AIUsageMeter(label: "Cost", used: Decimal(string: "1.25"), unit: .currency("USD"))
            ], balance: 8, fetchedAt: instant, source: "RAW_SECRET_NOT_FOR_HTTP"
        ), error: "provider raw token=do-not-export"),
         AIUsageService.ProviderResult(providerID: "empty", snapshot: nil, error: nil)]
    }

    private func request(_ path: String = "/v1/limits", method: String = "GET", extra: String = "") -> Data {
        Data("\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1:6737\r\n\(extra)\r\n".utf8)
    }

    private func json(_ response: AIUsageLocalAPI.Response) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
    }

    func testLimitsScalarsMissingValuesAndCachedFailure() throws {
        let response = AIUsageLocalAPI.route(header: request(), port: 6737,
                                              now: instant.addingTimeInterval(600), snapshots: fixture)
        XCTAssertEqual(response.status, 200)
        let body = try json(response)
        XCTAssertEqual(body["schema"] as? String, "symaira.cockpit.limits.v1")
        let providers = try XCTUnwrap(body["providers"] as? [String: [String: Any]])
        let provider = try XCTUnwrap(providers["fixture"])
        XCTAssertNil(providers["empty"])
        XCTAssertEqual(provider["stale"] as? Bool, true)
        XCTAssertEqual(provider["fetched_at"] as? String, "2023-11-14T22:13:20Z")
        let resources = try XCTUnwrap(provider["resources"] as? [String: [String: Any]])
        let session = try XCTUnwrap(resources.values.first { $0["label"] as? String == "Session" })
        XCTAssertEqual(session["used"] as? Double, 42)
        XCTAssertEqual(session["remaining"] as? Double, 58)
        XCTAssertEqual(session["utilization"] as? Double, 0.42)
        XCTAssertEqual(session["unit"] as? String, "percent")
        XCTAssertFalse(resources.values.contains { $0["label"] as? String == "Missing" })
        let limitOnly = try XCTUnwrap(resources.values.first { $0["label"] as? String == "Limit only" })
        XCTAssertNil(limitOnly["used"])
        XCTAssertNil(limitOnly["remaining"])
        XCTAssertEqual(resources.values.first { $0["label"] as? String == "Zero" }?["used"] as? Double, 0)
        XCTAssertEqual(resources.values.first { $0["label"] as? String == "Cost" }?["used"] as? Double, 1.25)
        XCTAssertEqual(resources["balance"]?["unit"] as? String, "unknown")
        let text = try XCTUnwrap(String(data: response.body, encoding: .utf8))
        XCTAssertFalse(text.contains("do-not-export"))
        XCTAssertFalse(text.contains("RAW_SECRET"))
        XCTAssertEqual((body["errors"] as? [[String: String]])?.first?["code"], "usage_unavailable")
    }

    func testRoutesAndTrustBoundaryNeverReadCacheOnRejection() throws {
        let cases: [(Data, Int)] = [
            (request(extra: "Origin: https://evil.example\r\n"), 403),
            (request(extra: "Origin: null\r\n"), 403),
            (request(extra: "Origin: http://127.0.0.1:6737\r\n"), 403),
            (request(extra: "Sec-Fetch-Site: none\r\n"), 403),
            (Data("GET /v1/limits HTTP/1.1\r\nHost: evil.example:6737\r\n\r\n".utf8), 403),
            (request(extra: "Host: 127.0.0.1:6737\r\n"), 400),
            (request(extra: "Content-Length: 1\r\n"), 413),
            (request(extra: "Transfer-Encoding: chunked\r\n"), 413),
            (request(method: "POST"), 405), (request("/missing"), 404),
            (request("/v1/limits", method: "OPTIONS"), 204),
            (Data(repeating: 65, count: 8193), 431)
        ]
        for (header, status) in cases {
            var called = false
            let response = AIUsageLocalAPI.route(header: header, port: 6737) { called = true; return [] }
            XCTAssertEqual(response.status, status)
            XCTAssertFalse(called)
            let wire = try XCTUnwrap(String(data: response.httpData(), encoding: .utf8))
            XCTAssertFalse(wire.contains("Access-Control-Allow-Origin"))
        }
        XCTAssertEqual(AIUsageLocalAPI.route(header: request("/v1/limits/absent"), port: 6737,
                                             snapshots: fixture).status, 404)
        XCTAssertEqual(AIUsageLocalAPI.route(header: request("/v1/limits/empty"), port: 6737,
                                             snapshots: fixture).status, 200)
        let usage = try json(AIUsageLocalAPI.route(header: request("/v1/usage/fixture"), port: 6737,
                                                  snapshots: fixture))
        XCTAssertEqual(usage["schema"] as? String, "symaira.cockpit.usage.v1")
        XCTAssertEqual((usage["snapshots"] as? [[String: Any]])?.count, 1)
    }

    func testExactLabelIdentityAndDeterministicDuplicates() throws {
        let meters = [AIUsageMeter(label: "A B", used: 1, unit: .tokens),
                      AIUsageMeter(label: "A-B", used: 2, unit: .tokens),
                      AIUsageMeter(label: "A B", used: 3, unit: .requests)]
        func project(_ meters: [AIUsageMeter]) -> AIUsageLocalAPI.Response {
            AIUsageLocalAPI.route(header: request(), port: 6737, now: instant) {
                [.init(providerID: "p", snapshot: .init(providerID: "p", meters: meters,
                                                       fetchedAt: instant, source: "fixture"), error: nil)]
            }
        }
        XCTAssertEqual(project(meters).body, project(meters.reversed()).body)
        let providers = try XCTUnwrap(try json(project(meters))["providers"] as? [String: [String: Any]])
        let resources = try XCTUnwrap(providers["p"]?["resources"] as? [String: Any])
        XCTAssertEqual(resources.count, 3)
    }

    func testSnapshotBoundsAndNonFiniteMissingScalars() throws {
        let oversized = AIUsageLocalAPI.route(header: request(), port: 6737) {
            Array(repeating: .init(providerID: "p", snapshot: nil, error: nil), count: 65)
        }
        XCTAssertEqual(oversized.status, 503)
        let result = AIUsageLocalAPI.route(header: request(), port: 6737, now: instant) {
            [.init(providerID: "p", snapshot: .init(providerID: "p", meters: [
                .init(label: "No numeric value", used: .nan, unit: .tokens),
                .init(label: "Over", used: 120, limit: 100, unit: .requests),
                .init(label: "No denominator", used: 1, limit: 0, unit: .credits)
            ], fetchedAt: instant, source: "fixture"), error: nil)]
        }
        let providers = try XCTUnwrap(try json(result)["providers"] as? [String: [String: Any]])
        let provider = try XCTUnwrap(providers["p"])
        XCTAssertEqual(provider["stale"] as? Bool, false)
        let resources = try XCTUnwrap(provider["resources"] as? [String: [String: Any]])
        XCTAssertEqual(resources.count, 2)
        let over = try XCTUnwrap(resources.values.first { $0["label"] as? String == "Over" })
        XCTAssertEqual(over["remaining"] as? Double, 0)
        XCTAssertEqual(over["utilization"] as? Double, 1)
        let zeroLimit = try XCTUnwrap(resources.values.first { $0["label"] as? String == "No denominator" })
        XCTAssertNil(zeroLimit["utilization"])
    }

    private func connect(_ port: UInt16) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            Darwin.close(fd)
            throw error
        }
        return fd
    }

    private func assertRefused(_ port: UInt16, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let fd = try connect(port)
            defer { Darwin.close(fd) }
            XCTFail("Stopped listener accepted TCP", file: file, line: line)
        } catch {
            XCTAssertEqual((error as? POSIXError)?.code, .ECONNREFUSED, file: file, line: line)
        }
    }

    private func send(_ fd: Int32, _ text: String) throws {
        let data = Data(text.utf8)
        let sent = data.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard sent == data.count else { throw POSIXError(.EIO) }
    }

    private func read(_ fd: Int32) throws -> String {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            // Cancelling a connection with unread request bytes can reset TCP
            // after a complete HTTP error response rather than sending FIN.
            if count == 0 || (count < 0 && errno == ECONNRESET) { break }
            guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= 1_100_000 else { throw POSIXError(.EFBIG) }
        }
        return try XCTUnwrap(String(data: result, encoding: .utf8))
    }

    func testRealLoopbackSocketAndStop() throws {
        let rows = fixture()
        let server = AIUsageLocalServer(port: 0) { rows }
        let port = try server.start()
        XCTAssertNotEqual(port, 0)
        defer { server.stop() }
        let fd = try connect(port)
        defer { Darwin.close(fd) }
        try send(fd, "GET /v1/limits/fixture HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        let response = try read(fd)
        XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"))
        XCTAssertTrue(response.contains("symaira.cockpit.limits.v1"))
        XCTAssertFalse(response.contains("RAW_SECRET"))
        let hostile = try connect(port)
        defer { Darwin.close(hostile) }
        try send(hostile, "GET /v1/usage HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nOrigin: null\r\n\r\n")
        XCTAssertTrue(try read(hostile).hasPrefix("HTTP/1.1 403"))
        XCTAssertTrue(server.stop())
        XCTAssertTrue(server.stop())
        assertRefused(port)
    }

    func testRealSocketHeaderDeadlineBodyAndOverloadBounds() throws {
        let server = AIUsageLocalServer(port: 0) { [] }
        let port = try server.start()
        defer { server.stop() }
        let oversized = try connect(port)
        defer { Darwin.close(oversized) }
        try send(oversized, String(repeating: "X", count: 8193))
        XCTAssertTrue(try read(oversized).hasPrefix("HTTP/1.1 431"))
        let body = try connect(port)
        defer { Darwin.close(body) }
        try send(body, "GET /v1/limits HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nContent-Length: 1\r\n\r\nx")
        XCTAssertTrue(try read(body).hasPrefix("HTTP/1.1 413"))
        let slow = try connect(port)
        defer { Darwin.close(slow) }
        try send(slow, "GET ")
        XCTAssertTrue(try read(slow).hasPrefix("HTTP/1.1 408"))
        var held: [Int32] = []
        defer { held.forEach { Darwin.close($0) } }
        for _ in 0..<15 { let fd = try connect(port); held.append(fd); try send(fd, "GET ") }
        let excess = try connect(port)
        defer { Darwin.close(excess) }
        try send(excess, "GET ")
        XCTAssertTrue(try read(excess).hasPrefix("HTTP/1.1 503"))
        server.stop()
        for fd in held { XCTAssertEqual(try read(fd), "") }
    }

    private final class ShutdownProbe: @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var server: AIUsageLocalServer?
        var reads = 0 // Only accessed on the server queue, then after stop completion.
        var stoppedOnQueue: Bool?

        func snapshot() -> [AIUsageService.ProviderResult] {
            reads += 1
            if reads == 1 {
                entered.signal()
                guard release.wait(timeout: .now() + 3) == .success else { return [] }
                stoppedOnQueue = server?.stop()
            }
            return []
        }
    }

    func testStopOnCallbackQueueRejectsQueuedHTTPAndAllowsRebind() throws {
        let probe = ShutdownProbe()
        let server = AIUsageLocalServer(port: 0, snapshots: probe.snapshot)
        probe.server = server
        defer { probe.release.signal(); server.stop(); probe.server = nil }
        let port = try server.start()
        let active = try connect(port)
        defer { Darwin.close(active) }
        let header = "GET /v1/limits HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n"
        try send(active, header)
        XCTAssertEqual(probe.entered.wait(timeout: .now() + 3), .success)
        // The listener queue is inside snapshot(): TCP can complete, but its
        // newConnection callbacks cannot run until after the in-queue stop.
        var late: [Int32] = []
        defer { late.forEach { Darwin.close($0) } }
        for _ in 0..<8 {
            let fd = try connect(port)
            late.append(fd)
            try send(fd, header)
        }
        probe.release.signal()
        XCTAssertEqual(try read(active), "")
        XCTAssertTrue(server.stop()) // Explicitly observes native cancellation.
        XCTAssertEqual(probe.stoppedOnQueue, false)
        for fd in late { XCTAssertEqual(try read(fd), "", "Late HTTP must not serve cached usage") }
        XCTAssertEqual(probe.reads, 1)
        assertRefused(port)

        let rebound = AIUsageLocalServer(port: port) { [] }
        defer { rebound.stop() }
        for _ in 0..<3 {
            XCTAssertEqual(try rebound.start(), port)
            let fd = try connect(port)
            defer { Darwin.close(fd) }
            try send(fd, header)
            XCTAssertTrue(try read(fd).hasPrefix("HTTP/1.1 200 OK"))
            XCTAssertTrue(rebound.stop())
        }
    }

    func testStopDeadlineIncludesBlockedCallbackQueue() throws {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let server = AIUsageLocalServer(port: 0) {
            entered.signal()
            _ = release.wait(timeout: .now() + 10) // Watchdog, not synchronization.
            return []
        }
        defer { release.signal(); server.stop() }
        let port = try server.start()
        let fd = try connect(port)
        defer { Darwin.close(fd) }
        try send(fd, "GET /v1/limits HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\n\r\n")
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        let started = DispatchTime.now().uptimeNanoseconds
        XCTAssertFalse(server.stop(), "Blocked queue cannot report completed shutdown")
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000_000
        XCTAssertLessThan(elapsed, 4)
        release.signal()
        XCTAssertTrue(server.stop())
        assertRefused(port)
    }

    func testDeinitClosesHeldSocketAndReleasesPort() throws {
        var server: AIUsageLocalServer? = AIUsageLocalServer(port: 0) { [] }
        defer { server?.stop() }
        let port = try XCTUnwrap(server).start()
        let fd = try connect(port)
        defer { Darwin.close(fd) }
        try send(fd, "GET ")
        weak var released = server
        server = nil
        XCTAssertNil(released)
        XCTAssertEqual(try read(fd), "")
        assertRefused(port)
        let rebound = AIUsageLocalServer(port: port) { [] }
        defer { rebound.stop() }
        XCTAssertEqual(try rebound.start(), port)
        XCTAssertTrue(rebound.stop())
    }

    func testBindFailureIsVisible() throws {
        let server = AIUsageLocalServer(port: 0) { [] }
        let port = try server.start()
        defer { server.stop() }
        let conflict = AIUsageLocalServer(port: port) { [] }
        defer { conflict.stop() }
        XCTAssertThrowsError(try conflict.start()) { error in
            guard case .bindFailed = error as? AIUsageLocalServer.ServerError else {
                return XCTFail("Expected original bind error, got \(error)")
            }
        }
        XCTAssertTrue(conflict.stop())
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? AIUsageLocalServer.ServerError, .alreadyStarted)
        }
    }
}
