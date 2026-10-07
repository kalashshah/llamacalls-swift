import AVFoundation
import Foundation
import Observation

/// One call on the Cloudflare transport: what `POST /api/calls` (or a joinUrl) opens.
@Observable @MainActor
public final class LlamaCall {
    public enum State: Equatable, Sendable {
        case idle, connecting, live
        case ended(reason: String)
    }

    public enum Role: Sendable { case user, agent }
    public enum AgentState: String, Sendable { case listening, thinking, speaking }

    public struct Caption: Identifiable, Equatable, Sendable {
        public let id: String
        public let role: Role
        public let text: String
        public let isFinal: Bool
        /// When this version of the caption arrived.
        public let receivedAt: Date

        public init(id: String, role: Role, text: String, isFinal: Bool, receivedAt: Date) {
            self.id = id
            self.role = role
            self.text = text
            self.isFinal = isFinal
            self.receivedAt = receivedAt
        }
    }

    public private(set) var state: State = .idle
    public private(set) var agentPresent = false
    public private(set) var agentState: AgentState?
    public private(set) var captions: [Caption] = []
    public private(set) var faceTrack: VideoTrack?
    public private(set) var selfTrack: VideoTrack?
    public private(set) var screen: PlatformImage?
    public private(set) var isMicrophoneOn = false
    public private(set) var isCameraOn = false

    /// The agent's playout volume, 0...1, on every one of its audio tracks. Local only.
    public var agentVolume: Double = 1 {
        didSet { for track in agentAudio { track.volume = agentVolume } }
    }

    /// Raw audio for level meters. Called on the audio thread.
    public var onMicrophoneAudio: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { micTap.handler }
        set { micTap.handler = newValue }
    }
    public var onAgentAudio: (@Sendable (AVAudioPCMBuffer) -> Void)? {
        get { agentTap.handler }
        set { agentTap.handler = newValue }
    }

    @ObservationIgnored private let media: Media
    @ObservationIgnored private let audioSession: AudioSessionControl
    @ObservationIgnored private let configuresAudioSession: Bool
    @ObservationIgnored private let pingInterval: Duration
    @ObservationIgnored private let answerTimeout: Duration
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let micTap = AudioTap()
    @ObservationIgnored private let agentTap = AudioTap()
    @ObservationIgnored private var socket: Socket?
    @ObservationIgnored private var peer: PeerConnection?
    @ObservationIgnored private var negotiator: Negotiator?
    @ObservationIgnored private var pinger: Task<Void, Never>?
    @ObservationIgnored private var microphone: LocalMediaTrack?
    @ObservationIgnored private var camera: Camera?
    @ObservationIgnored private var cameraPublished = false
    @ObservationIgnored private var agentAudio: [RemoteAudioTrack] = []
    @ObservationIgnored private var screenLive = false
    @ObservationIgnored private var decodingScreen = false

    init(media: Media, audioSession: AudioSessionControl, configuresAudioSession: Bool,
         pingInterval: Duration = .seconds(30), answerTimeout: Duration = .seconds(15), now: @escaping () -> Date = Date.init) {
        self.media = media
        self.audioSession = audioSession
        self.configuresAudioSession = configuresAudioSession
        self.pingInterval = pingInterval
        self.answerTimeout = answerTimeout
        self.now = now
    }

    // MARK: Connecting

    public func connect(joinUrl: URL) async throws {
        guard let parts = Self.parse(joinUrl: joinUrl) else { throw LlamaCallError.invalidJoinUrl }
        try await connect(room: parts.room, url: parts.url, token: parts.token)
    }

    /// Returns once the room has welcomed us and the peer connection exists.
    public func connect(room: String, url: URL, token: String) async throws {
        guard state == .idle else { throw LlamaCallError.alreadyStarted }
        guard let socketURL = Self.socketURL(url, room: room, token: token) else { throw LlamaCallError.unreachable }
        state = .connecting
        if configuresAudioSession { try? audioSession.activate() }
        let socket = media.openSocket(socketURL)
        self.socket = socket
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                var settled = false
                socket.onText = { [weak self] text in
                    guard let self, let message = ServerMessage.decode(text) else { return }
                    if !settled, case let .welcome(iceServers) = message {
                        settled = true
                        // Built here, not after the await, so a message in the same burst finds it.
                        do {
                            try self.open(iceServers: iceServers)
                            continuation.resume()
                        } catch {
                            continuation.resume(throwing: error)
                        }
                        return
                    }
                    self.handle(message)
                }
                socket.onData = { [weak self] data in self?.receiveScreenFrame(data) }
                socket.onClose = { [weak self] opened in
                    if !settled {
                        settled = true
                        continuation.resume(throwing: opened ? LlamaCallError.refused : LlamaCallError.unreachable)
                    } else {
                        self?.end("disconnected")
                    }
                }
            }
        } catch {
            end("could not connect")
            throw error
        }
        guard state == .connecting else { return }
        state = .live
    }

    private func open(iceServers: [IceServer]) throws {
        let peer = try media.makePeerConnection(iceServers: iceServers, events: self)
        self.peer = peer
        negotiator = Negotiator(peer: peer, send: { [weak self] in self?.send($0) }, answerTimeout: answerTimeout)
        pinger = Task { [weak self, pingInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pingInterval)
                guard !Task.isCancelled else { return }
                self?.send(.ping)
            }
        }
    }

    // MARK: Media

    /// The first call asks permission and publishes the mic; later calls mute and unmute it.
    public func setMicrophone(_ on: Bool) async throws {
        if let microphone {
            microphone.isEnabled = on
            isMicrophoneOn = on
            return
        }
        guard on else { return }
        guard let negotiator else { throw LlamaCallError.notConnected }
        guard await media.microphoneAllowed() else { throw LlamaCallError.microphoneDenied }
        let track = media.makeMicrophone(tap: micTap.forward)
        microphone = track
        isMicrophoneOn = true
        try await negotiator.publish(track, as: "mic")
    }

    /// `publish: false` starts the camera for `selfTrack` only; nothing leaves the phone until a later `setCamera(true)`.
    public func setCamera(_ on: Bool, publish: Bool = true) async throws {
        guard let negotiator else { throw LlamaCallError.notConnected }
        guard on else {
            guard let camera else { return }
            camera.track.isEnabled = false
            camera.stop()
            if cameraPublished { send(.camera(on: false)) }
            isCameraOn = false
            selfTrack = nil
            return
        }
        let camera: Camera
        if let existing = self.camera {
            camera = existing
        } else {
            guard await media.cameraAllowed() else { throw LlamaCallError.cameraDenied }
            camera = media.makeCamera()
            self.camera = camera
        }
        if !isCameraOn {
            try await camera.start()
            camera.track.isEnabled = true
            isCameraOn = true
            selfTrack = camera.preview
            if cameraPublished { send(.camera(on: true)) }
        }
        if publish && !cameraPublished {
            cameraPublished = true
            try await negotiator.publish(camera.track, as: "camera")
        }
    }

    // MARK: Ending

    /// Ends the call for everyone, now.
    public func hangUp() async {
        guard socket != nil else { return }
        send(.hangup)
        end("hung up")
    }

    /// Leaves; the room ends the call a minute later unless someone rejoins.
    public func leave() async {
        guard socket != nil else { return }
        end("left")
    }

    private func end(_ reason: String) {
        if case .ended = state { return }
        state = .ended(reason: reason)
        pinger?.cancel()
        pinger = nil
        negotiator?.cancel()
        negotiator = nil
        camera?.stop()
        camera = nil
        microphone = nil
        peer?.close()
        peer = nil
        socket?.onClose = nil
        socket?.close()
        socket = nil
        agentAudio = []
        faceTrack = nil
        selfTrack = nil
        screen = nil
        screenLive = false
        isMicrophoneOn = false
        isCameraOn = false
        agentPresent = false
        agentState = nil
        if configuresAudioSession { audioSession.deactivate() }
    }

    // MARK: The room

    private func handle(_ message: ServerMessage) {
        switch message {
        case let .answer(answer):
            negotiator?.receiveAnswer(answer)
        case let .offer(offer, tracks):
            negotiator?.receiveOffer(offer, tracks: tracks)
        case let .error(text):
            // Only an error that failed our publish ends the call; the room recovers from its own.
            if negotiator?.receiveError(text) == true { end(text) }
        case let .caption(id, role, text, isFinal):
            let caption = Caption(id: id, role: role == "agent" ? .agent : .user, text: text, isFinal: isFinal, receivedAt: now())
            if let index = captions.firstIndex(where: { $0.id == id }) { captions[index] = caption } else { captions.append(caption) }
        case let .state(value):
            agentState = AgentState(rawValue: value)
        case let .agent(present):
            agentPresent = present
            if !present { agentState = nil }
        case let .screen(live):
            screenLive = live
            if !live { screen = nil }
        case let .ended(reason):
            end(reason)
        case .welcome, .other:
            break
        }
    }

    /// One decode at a time: a frame arriving mid-decode is dropped, never queued.
    private func receiveScreenFrame(_ data: Data) {
        guard screenLive, !decodingScreen else { return }
        decodingScreen = true
        Task {
            let image = await media.decodeJPEG(data)
            decodingScreen = false
            if screenLive { screen = image }
        }
    }

    private func send(_ message: ClientMessage) {
        socket?.send(message.encoded())
    }

    // MARK: URLs

    static func socketURL(_ base: URL, room: String, token: String) -> URL? {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false),
              let roomPath = room.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        components.scheme = components.scheme == "http" ? "ws" : "wss"
        var path = components.percentEncodedPath
        if path.hasSuffix("/") { path.removeLast() }
        components.percentEncodedPath = path + "/rooms/\(roomPath)/connect"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }

    /// `https://…/embed/<room>#url=…&token=…`, as `POST /api/calls` returns it.
    static func parse(joinUrl: URL) -> (room: String, url: URL, token: String)? {
        let segments = joinUrl.pathComponents
        guard segments.count >= 3, segments[segments.count - 2] == "embed", let room = segments.last,
              let fragment = joinUrl.fragment else { return nil }
        var query = URLComponents()
        query.percentEncodedQuery = fragment
        let items = query.queryItems ?? []
        guard let raw = items.first(where: { $0.name == "url" })?.value, let url = URL(string: raw),
              let token = items.first(where: { $0.name == "token" })?.value, !token.isEmpty else { return nil }
        return (room, url, token)
    }
}

extension LlamaCall: PeerConnectionEvents {
    func peerConnection(received media: RemoteMedia, mid: String) {
        switch (negotiator?.name(forMid: mid), media) {
        case let ("agent-face", .video(track)):
            faceTrack = track
        case let ("agent-voice", .audio(track)), let ("agent-face-voice", .audio(track)):
            track.volume = agentVolume
            track.tap(agentTap.forward)
            agentAudio.append(track)
        default:
            break
        }
    }

    func peerConnectionFailed() {
        end("media connection failed")
    }
}
