import Network
import XCTest
@testable import LlamaCalls

/// A one-connection WebSocket server on localhost: records text frames and whether the client went away.
final class LocalWebSocketServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "ws-test")
    private let lock = NSLock()
    private var _received: [String] = []
    private var _closed = false
    var received: [String] { lock.withLock { _received } }
    var closed: Bool { lock.withLock { _closed } }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.defaultProtocolStack.applicationProtocols.insert(NWProtocolWebSocket.Options(), at: 0)
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.stateUpdateHandler = { state in
                if case .cancelled = state { self.lock.withLock { self._closed = true } }
                if case .failed = state { self.lock.withLock { self._closed = true } }
            }
            connection.start(queue: self.queue)
            self.read(connection)
        }
    }

    func start() async throws -> UInt16 {
        listener.start(queue: queue)
        for _ in 0..<100 {
            if let port = listener.port?.rawValue, port != 0 { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw URLError(.cannotConnectToHost)
    }

    private func read(_ connection: NWConnection) {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self else { return }
            let metadata = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            if metadata?.opcode == .close || error != nil {
                self.lock.withLock { self._closed = true }
                connection.cancel()
                return
            }
            if let data, metadata?.opcode == .text { self.lock.withLock { self._received.append(String(decoding: data, as: UTF8.self)) } }
            self.read(connection)
        }
    }
}

@MainActor final class URLSessionSocketTests: XCTestCase {
    func testCloseRightAfterASendDeliversItThenClosesEvenWhenNothingElseHoldsTheSocket() async throws {
        let server = try LocalWebSocketServer()
        let port = try await server.start()
        var socket: URLSessionSocket? = URLSessionSocket(url: URL(string: "ws://127.0.0.1:\(port)/")!)
        try await Task.sleep(for: .milliseconds(300))
        socket?.send(#"{"t":"hangup"}"#)
        socket?.close()
        // What LlamaCall.end() does: drop the only reference straight after closing.
        socket = nil
        for _ in 0..<50 where !server.closed { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(server.received, [#"{"t":"hangup"}"#])
        XCTAssertTrue(server.closed, "the socket never closed: its drain-then-close did not run")
        server.listener.cancel()
    }
}
