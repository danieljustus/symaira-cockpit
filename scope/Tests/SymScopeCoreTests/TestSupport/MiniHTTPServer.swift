import Darwin
import Foundation
import Network

/// Guards a `CheckedContinuation` against the double-resume crash — `NWListener`'s
/// state handler can fire more than once before the socket is torn down.
private final class ResumeBox<T: Sendable>: @unchecked Sendable {
    private var continuation: CheckedContinuation<T, Error>?
    private let lock = NSLock()

    init(continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        guard let cont else { return }
        switch result {
        case .success(let value): cont.resume(returning: value)
        case .failure(let error): cont.resume(throwing: error)
        }
    }
}

private func awaitReady(_ listener: NWListener) async throws -> UInt16 {
    try await withCheckedThrowingContinuation { continuation in
        let box = ResumeBox(continuation: continuation)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = listener.port?.rawValue {
                    box.resume(.success(port))
                }
            case .failed(let error):
                box.resume(.failure(error))
            default:
                break
            }
        }
        listener.start(queue: .main)
    }
}

/// Minimal loopback HTTP responder for exercising `MCPHealthService`'s http/sse
/// probe path without real network access — binds an ephemeral port, replies
/// with a fixed status line to every connection.
final class MiniHTTPServer: @unchecked Sendable {
    private var listener: NWListener?
    let port: UInt16

    init(statusLine: String = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n") async throws {
        let listener = try NWListener(using: .tcp)
        self.listener = listener
        listener.newConnectionHandler = { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                connection.send(content: statusLine.data(using: .utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        self.port = try await awaitReady(listener)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

/// Reserves then immediately releases an ephemeral loopback port so a caller
/// can connect to it and reliably observe "connection refused". Uses a raw
/// POSIX socket (bind + getsockname + close) rather than `NWListener` — no
/// async readiness handshake needed for a bind-only probe.
func reserveAndReleaseEphemeralPort() async throws -> UInt16 {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }
    defer { close(fd) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = 0
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            bind(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard bindResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }

    var assigned = sockaddr_in()
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &assigned) { ptr -> Int32 in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
            getsockname(fd, sockaddrPtr, &len)
        }
    }
    guard nameResult == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL) }

    // Closing without ever calling listen()/accept() releases the port while
    // guaranteeing nothing will answer a connection attempt against it.
    return UInt16(bigEndian: assigned.sin_port)
}
