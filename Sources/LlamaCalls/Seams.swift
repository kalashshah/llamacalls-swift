import AVFoundation
import Foundation

#if canImport(UIKit)
import UIKit
public typealias PlatformImage = UIImage
#else
import AppKit
public typealias PlatformImage = NSImage
#endif

/// A video track an app can draw with `LlamaCallVideoView`. Opaque: apps never see WebRTC types.
public final class VideoTrack: Equatable, @unchecked Sendable {
    let underlying: AnyObject
    init(_ underlying: AnyObject) { self.underlying = underlying }
    public static func == (a: VideoTrack, b: VideoTrack) -> Bool { a.underlying === b.underlying }
}

protocol LocalMediaTrack: AnyObject {
    var isEnabled: Bool { get set }
    /// Taken off WebRTC before release, so the audio thread cannot call into a freed tap.
    func detach()
}

protocol RemoteAudioTrack: AnyObject {
    var volume: Double { get set }
    func tap(_ handler: @escaping @Sendable (AVAudioPCMBuffer) -> Void)
    func detach()
}

enum RemoteMedia {
    case audio(RemoteAudioTrack)
    case video(VideoTrack)
}

protocol Transceiver: AnyObject {
    var mid: String? { get }
}

@MainActor protocol PeerConnectionEvents: AnyObject {
    func peerConnection(received media: RemoteMedia, mid: String)
    func peerConnectionFailed()
}

@MainActor protocol PeerConnection: AnyObject {
    /// The room's last description, for numbering our offers to agree with it.
    var remoteSDP: String? { get }
    func addTransceiver(sending track: LocalMediaTrack) throws -> Transceiver
    func createOffer() async throws -> SessionDescription
    func createAnswer() async throws -> SessionDescription
    func setLocalDescription(_ description: SessionDescription) async throws
    func setRemoteDescription(_ description: SessionDescription) async throws
    func rollback() async throws
    func close()
}

@MainActor protocol Socket: AnyObject {
    var onText: ((String) -> Void)? { get set }
    var onData: ((Data) -> Void)? { get set }
    /// Called once. `opened` is false when the connection never came up at all.
    var onClose: ((_ opened: Bool) -> Void)? { get set }
    func send(_ text: String)
    /// Closes after anything already sent has gone out.
    func close()
}

@MainActor protocol Camera: AnyObject {
    var track: LocalMediaTrack { get }
    var preview: VideoTrack { get }
    func start() async throws
    func stop()
}

@MainActor protocol Media: AnyObject {
    func openSocket(_ url: URL) -> Socket
    func makePeerConnection(iceServers: [IceServer], events: PeerConnectionEvents) throws -> PeerConnection
    func makeMicrophone(tap: @escaping @Sendable (AVAudioPCMBuffer) -> Void) -> LocalMediaTrack
    func makeCamera() -> Camera
    func microphoneAllowed() async -> Bool
    func cameraAllowed() async -> Bool
    func decodeJPEG(_ data: Data) async -> PlatformImage?
}

@MainActor protocol AudioSessionControl {
    func activate() throws
    func deactivate()
}

/// A handler the audio thread can call while the main actor replaces it.
final class AudioTap: @unchecked Sendable {
    private let lock = NSLock()
    private var _handler: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var handler: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }
    var forward: @Sendable (AVAudioPCMBuffer) -> Void {
        { [weak self] buffer in self?.handler?(buffer) }
    }
}
