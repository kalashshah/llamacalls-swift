import AVFoundation
import Foundation
import LiveKitWebRTC
#if canImport(UIKit)
import UIKit
#endif

@MainActor final class WebRTCMedia: Media {
    static let factory: LKRTCPeerConnectionFactory = {
        LKRTCInitializeSSL()
        return LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
                                          decoderFactory: LKRTCDefaultVideoDecoderFactory())
    }()

    func openSocket(_ url: URL) -> Socket { URLSessionSocket(url: url) }

    func makePeerConnection(iceServers: [IceServer], events: PeerConnectionEvents) throws -> PeerConnection {
        try WebRTCPeer(iceServers: iceServers, events: events)
    }

    func makeMicrophone(tap: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> LocalMediaTrack {
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: [
            "googEchoCancellation": "true", "googNoiseSuppression": "true", "googAutoGainControl": "true",
        ], optionalConstraints: nil)
        let source = Self.factory.audioSource(with: constraints)
        let track = Self.factory.audioTrack(with: source, trackId: "mic")
        let renderer = PCMRenderer(tap)
        track.add(renderer)
        return WebRTCLocalTrack(track, keeping: renderer)
    }

    func makeCamera() -> Camera { WebRTCCamera() }

    func microphoneAllowed() async -> Bool {
        #if os(iOS)
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }

    func cameraAllowed() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }

    func decodeJPEG(_ data: Data) async -> PlatformImage? {
        await Task.detached(priority: .userInitiated) { PlatformImage(data: data) }.value
    }
}

final class WebRTCLocalTrack: LocalMediaTrack {
    let track: LKRTCMediaStreamTrack
    // The track holds its renderer weakly in some builds; this keeps it alive with the track.
    private let renderer: AnyObject?
    init(_ track: LKRTCMediaStreamTrack, keeping renderer: AnyObject? = nil) {
        self.track = track
        self.renderer = renderer
    }
    var isEnabled: Bool {
        get { track.isEnabled }
        set { track.isEnabled = newValue }
    }
}

final class WebRTCRemoteAudio: RemoteAudioTrack {
    let track: LKRTCAudioTrack
    private var renderers: [PCMRenderer] = []
    init(_ track: LKRTCAudioTrack) { self.track = track }
    var volume: Double {
        get { track.source.volume / 10 }
        set { track.source.volume = newValue * 10 }  // the source's gain runs 0...10
    }
    func tap(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        let renderer = PCMRenderer(handler)
        renderers.append(renderer)
        track.add(renderer)
    }
}

final class PCMRenderer: NSObject, LKRTCAudioRenderer {
    private let handler: @Sendable (AVAudioPCMBuffer) -> Void
    init(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void) { self.handler = handler }
    func render(pcmBuffer: AVAudioPCMBuffer) { handler(pcmBuffer) }
}

final class WebRTCTransceiver: Transceiver {
    let transceiver: LKRTCRtpTransceiver
    init(_ transceiver: LKRTCRtpTransceiver) { self.transceiver = transceiver }
    var mid: String? { transceiver.mid.isEmpty ? nil : transceiver.mid }
}

@MainActor final class WebRTCPeer: NSObject, PeerConnection {
    private var pc: LKRTCPeerConnection!
    private weak var events: PeerConnectionEvents?

    init(iceServers: [IceServer], events: PeerConnectionEvents) throws {
        self.events = events
        super.init()
        let config = LKRTCConfiguration()
        config.iceServers = iceServers.map { LKRTCIceServer(urlStrings: $0.urls, username: $0.username, credential: $0.credential) }
        config.bundlePolicy = .maxBundle
        config.sdpSemantics = .unifiedPlan
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = WebRTCMedia.factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            throw LlamaCallError.negotiationFailed("could not create a peer connection")
        }
        self.pc = pc
    }

    func addTransceiver(sending track: LocalMediaTrack) throws -> Transceiver {
        guard let local = track as? WebRTCLocalTrack else { throw LlamaCallError.notConnected }
        let options = LKRTCRtpTransceiverInit()
        options.direction = .sendOnly
        guard let transceiver = pc.addTransceiver(with: local.track, init: options) else {
            throw LlamaCallError.negotiationFailed("could not add a track")
        }
        return WebRTCTransceiver(transceiver)
    }

    func createOffer() async throws -> SessionDescription {
        Self.wire(try await pc.offer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)))
    }

    func createAnswer() async throws -> SessionDescription {
        Self.wire(try await pc.answer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)))
    }

    func setLocalDescription(_ description: SessionDescription) async throws {
        try await pc.setLocalDescription(Self.native(description))
    }

    func setRemoteDescription(_ description: SessionDescription) async throws {
        try await pc.setRemoteDescription(Self.native(description))
    }

    func rollback() async throws {
        try await pc.setLocalDescription(LKRTCSessionDescription(type: .rollback, sdp: ""))
    }

    func close() { pc.close() }

    private static func wire(_ d: LKRTCSessionDescription) -> SessionDescription {
        SessionDescription(type: LKRTCSessionDescription.string(for: d.type), sdp: d.sdp)
    }

    private static func native(_ d: SessionDescription) -> LKRTCSessionDescription {
        LKRTCSessionDescription(type: LKRTCSessionDescription.type(for: d.type), sdp: d.sdp)
    }
}

extension WebRTCPeer: LKRTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didStartReceivingOn transceiver: LKRTCRtpTransceiver) {
        let mid = transceiver.mid
        guard let track = transceiver.receiver.track else { return }
        Task { @MainActor [weak self] in
            if let audio = track as? LKRTCAudioTrack {
                self?.events?.peerConnection(received: .audio(WebRTCRemoteAudio(audio)), mid: mid)
            } else if let video = track as? LKRTCVideoTrack {
                self?.events?.peerConnection(received: .video(VideoTrack(video)), mid: mid)
            }
        }
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCPeerConnectionState) {
        guard newState == .failed else { return }
        Task { @MainActor [weak self] in self?.events?.peerConnectionFailed() }
    }

    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
}

@MainActor final class WebRTCCamera: Camera {
    let track: LocalMediaTrack
    let preview: VideoTrack
    private let source: LKRTCVideoSource
    private let capturer: LKRTCCameraVideoCapturer

    init() {
        let source = WebRTCMedia.factory.videoSource()
        let video = WebRTCMedia.factory.videoTrack(with: source, trackId: "camera")
        self.source = source
        capturer = LKRTCCameraVideoCapturer(delegate: source)
        track = WebRTCLocalTrack(video)
        preview = VideoTrack(video)
    }

    func start() async throws {
        let devices = LKRTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == .front }) ?? devices.first else {
            throw LlamaCallError.cameraDenied
        }
        // The format closest to 1280 wide, at up to 24 fps.
        let formats = LKRTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = formats.min(by: { abs(Self.width($0) - 1280) < abs(Self.width($1) - 1280) }) else {
            throw LlamaCallError.cameraDenied
        }
        let fps = min(24, Int(format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 24))
        try await capturer.startCapture(with: device, format: format, fps: fps)
    }

    func stop() { capturer.stopCapture() }

    private static func width(_ format: AVCaptureDevice.Format) -> Int32 {
        CMVideoFormatDescriptionGetDimensions(format.formatDescription).width
    }
}
