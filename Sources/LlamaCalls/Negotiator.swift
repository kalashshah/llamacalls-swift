import Foundation

/// One publish's wait for the room: its answer, or the room's own offer crossing it (glare).
@MainActor final class Waiter {
    enum Outcome {
        case answer(SessionDescription)
        case glare(SessionDescription, [OfferedTrack])
    }

    private var result: Result<Outcome, Error>?
    private var continuation: CheckedContinuation<Outcome, Error>?

    var isResolved: Bool { result != nil }

    /// First resolution wins; later ones are ignored.
    func resolve(_ outcome: Result<Outcome, Error>) {
        guard result == nil else { return }
        result = outcome
        continuation?.resume(with: outcome)
        continuation = nil
    }

    func wait() async throws -> Outcome {
        if let result { return try result.get() }
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
}

/// Serialises negotiation on the one peer connection, as `CloudflareRoom` does: a publish
/// waits for its answer before the next offer is handled, and the room wins a glare.
@MainActor final class Negotiator {
    private let peer: PeerConnection
    private let send: (ClientMessage) -> Void
    private let answerTimeout: Duration
    private var trackNames: [String: String] = [:]
    private var tail: Task<Void, Never>?
    private var waiting: Waiter?

    init(peer: PeerConnection, send: @escaping (ClientMessage) -> Void, answerTimeout: Duration = .seconds(15)) {
        self.peer = peer
        self.send = send
        self.answerTimeout = answerTimeout
    }

    func name(forMid mid: String) -> String? { trackNames[mid] }

    func receiveOffer(_ offer: SessionDescription, tracks: [OfferedTrack]) {
        if let waiter = waiting {
            waiting = nil
            waiter.resolve(.success(.glare(offer, tracks)))
            return
        }
        Task { try? await self.enqueue { try await self.apply(offer, tracks: tracks) } }
    }

    func receiveAnswer(_ answer: SessionDescription) {
        waiting?.resolve(.success(.answer(answer)))
        waiting = nil
    }

    /// True when the error failed our publish, so the call must end.
    func receiveError(_ message: String) -> Bool {
        guard let waiter = waiting else { return false }
        waiting = nil
        waiter.resolve(.failure(LlamaCallError.negotiationFailed(message)))
        return true
    }

    func cancel() {
        waiting?.resolve(.failure(LlamaCallError.notConnected))
        waiting = nil
    }

    func publish(_ track: LocalMediaTrack, as name: String) async throws {
        try await enqueue { [self] in
            let transceiver = try peer.addTransceiver(sending: track)
            for _ in 0..<3 {
                // Registered before the offer is built, so a room offer landing meanwhile is glare.
                let waiter = Waiter()
                waiting = waiter
                let timeout = Task { [answerTimeout, weak self] in
                    try? await Task.sleep(for: answerTimeout)
                    guard !Task.isCancelled else { return }
                    waiter.resolve(.failure(LlamaCallError.negotiationFailed("the call did not answer our media in time")))
                    if self?.waiting === waiter { self?.waiting = nil }
                }
                defer { timeout.cancel() }
                let offer = try await peer.createOffer()
                try await peer.setLocalDescription(offer)
                // The room drops a publish that crossed its offer, so one already crossed is not sent.
                if !waiter.isResolved {
                    send(.publish(offer: offer, tracks: [PublishedTrack(mid: transceiver.mid ?? "", name: name)]))
                }
                switch try await waiter.wait() {
                case let .answer(answer):
                    try await peer.setRemoteDescription(answer)
                    return
                case let .glare(offer, tracks):
                    try await peer.rollback()
                    try await apply(offer, tracks: tracks)
                }
            }
            throw LlamaCallError.negotiationFailed("media negotiation kept colliding")
        }
    }

    private func apply(_ offer: SessionDescription, tracks: [OfferedTrack]) async throws {
        for track in tracks { trackNames[track.mid] = track.name }
        try await peer.setRemoteDescription(offer)
        let answer = try await peer.createAnswer()
        try await peer.setLocalDescription(answer)
        send(.answer(SessionDescription(type: "answer", sdp: answer.sdp)))
    }

    private func enqueue(_ step: @escaping @MainActor () async throws -> Void) async throws {
        let previous = tail
        let run = Task { @MainActor in
            await previous?.value
            try await step()
        }
        tail = Task { _ = try? await run.value }
        try await run.value
    }
}
