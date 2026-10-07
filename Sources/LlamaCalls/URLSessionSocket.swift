import Foundation

/// `Socket` over URLSessionWebSocketTask. `close()` waits for sends already queued, so a
/// `hangup` written just before it reaches the room.
@MainActor final class URLSessionSocket: NSObject, Socket {
    var onText: ((String) -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((Bool) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var opened = false
    private var closed = false
    private var pendingSends = 0
    private var closeWhenDrained = false

    init(url: URL) {
        super.init()
        let session = URLSession(configuration: .default, delegate: Delegate(owner: self), delegateQueue: .main)
        self.session = session
        let task = session.webSocketTask(with: url)
        // The room's binary messages are JPEG frames, well under this.
        task.maximumMessageSize = 4 * 1024 * 1024
        self.task = task
        task.resume()
        receive()
    }

    func send(_ text: String) {
        guard let task, !closed else { return }
        pendingSends += 1
        task.send(.string(text)) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.pendingSends -= 1
                if self.closeWhenDrained && self.pendingSends == 0 { self.shutdown() }
            }
        }
    }

    func close() {
        guard !closed else { return }
        if pendingSends > 0 { closeWhenDrained = true } else { shutdown() }
    }

    private func shutdown() {
        guard !closed else { return }
        closed = true
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self, !self.closed else { return }
                switch result {
                case let .success(.string(text)):
                    self.onText?(text)
                    self.receive()
                case let .success(.data(data)):
                    self.onData?(data)
                    self.receive()
                case .success:
                    self.receive()
                case .failure:
                    self.finish()
                }
            }
        }
    }

    fileprivate func didOpen() { opened = true }

    fileprivate func finish() {
        guard !closed else { return }
        let callback = onClose
        onClose = nil
        shutdown()
        callback?(opened)
    }

    private final class Delegate: NSObject, URLSessionWebSocketDelegate {
        weak var owner: URLSessionSocket?
        init(owner: URLSessionSocket) { self.owner = owner }

        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
            MainActor.assumeIsolated { owner?.didOpen() }
        }
        func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
            MainActor.assumeIsolated { owner?.finish() }
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            MainActor.assumeIsolated { owner?.finish() }
        }
    }
}
