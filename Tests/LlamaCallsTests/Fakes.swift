import AVFoundation
import Foundation
@testable import LlamaCalls

final class FakeTrack: LocalMediaTrack { var isEnabled = true }

final class FakeTransceiver: Transceiver { var mid: String? }

final class FakeRemoteAudio: RemoteAudioTrack {
    var volume: Double = 1
    var taps = 0
    func tap(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) { taps += 1 }
}

@MainActor final class FakePeer: PeerConnection {
    var log: [String] = []
    var nextMid = 0
    var closed = false
    /// Runs inside createOffer, before it returns: lets a test land a room message mid-offer.
    var duringCreateOffer: (() -> Void)?

    func addTransceiver(sending track: LocalMediaTrack) throws -> Transceiver {
        let t = FakeTransceiver()
        t.mid = String(nextMid)
        nextMid += 1
        log.append("addTransceiver")
        return t
    }
    func createOffer() async throws -> SessionDescription {
        log.append("createOffer")
        duringCreateOffer?()
        duringCreateOffer = nil
        return SessionDescription(type: "offer", sdp: "LOCAL-OFFER")
    }
    func createAnswer() async throws -> SessionDescription {
        log.append("createAnswer")
        return SessionDescription(type: "answer", sdp: "LOCAL-ANSWER")
    }
    func setLocalDescription(_ d: SessionDescription) async throws { log.append("local:\(d.type)") }
    func setRemoteDescription(_ d: SessionDescription) async throws { log.append("remote:\(d.type):\(d.sdp)") }
    func rollback() async throws { log.append("rollback") }
    func close() { closed = true }
}

@MainActor final class FakeSocket: Socket {
    var onText: ((String) -> Void)?
    var onData: ((Data) -> Void)?
    var onClose: ((Bool) -> Void)?
    var sent: [String] = []
    var closed = false
    let url: URL
    init(url: URL) { self.url = url }

    func send(_ text: String) { sent.append(text) }
    func close() { closed = true }

    func server(_ json: String) { onText?(json) }
    func serverClose(opened: Bool = true) { onClose?(opened) }
    var sentTypes: [String] {
        sent.compactMap { (try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])?["t"] as? String }
    }
}

@MainActor final class FakeCamera: Camera {
    let track: LocalMediaTrack = FakeTrack()
    let preview = VideoTrack(NSObject())
    var running = false
    func start() async throws { running = true }
    func stop() { running = false }
}

@MainActor final class FakeMedia: Media {
    var socket: FakeSocket?
    let peer = FakePeer()
    var micAllowed = true
    var camAllowed = true
    var madeMicrophone: FakeTrack?
    var madeCamera: FakeCamera?
    var events: PeerConnectionEvents?

    func openSocket(_ url: URL) -> Socket {
        let s = FakeSocket(url: url)
        socket = s
        return s
    }
    func makePeerConnection(iceServers: [IceServer], events: PeerConnectionEvents) throws -> PeerConnection {
        self.events = events
        return peer
    }
    func makeMicrophone(tap: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> LocalMediaTrack {
        let t = FakeTrack()
        madeMicrophone = t
        return t
    }
    func makeCamera() -> Camera {
        let c = FakeCamera()
        madeCamera = c
        return c
    }
    func microphoneAllowed() async -> Bool { micAllowed }
    func cameraAllowed() async -> Bool { camAllowed }
    func decodeJPEG(_ data: Data) async -> PlatformImage? { PlatformImage() }
}

@MainActor final class FakeAudioSession: AudioSessionControl {
    var active = false
    func activate() throws { active = true }
    func deactivate() { active = false }
}

/// Lets queued main-actor work run.
@MainActor func settle() async {
    for _ in 0..<20 { await Task.yield() }
}
