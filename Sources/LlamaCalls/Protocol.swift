import Foundation

/// An SDP blob, as the room and the peer connection exchange it.
public struct SessionDescription: Codable, Equatable, Sendable {
    public var type: String
    public var sdp: String
    public init(type: String, sdp: String) {
        self.type = type
        self.sdp = sdp
    }
}

struct IceServer: Decodable, Equatable, Sendable {
    var urls: [String]
    var username: String?
    var credential: String?

    init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }

    private enum Keys: String, CodingKey { case urls, username, credential }

    // The room sends `urls` as a string or an array, as RTCIceServer allows.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        if let one = try? c.decode(String.self, forKey: .urls) { urls = [one] } else { urls = try c.decode([String].self, forKey: .urls) }
        username = try c.decodeIfPresent(String.self, forKey: .username)
        credential = try c.decodeIfPresent(String.self, forKey: .credential)
    }
}

struct OfferedTrack: Decodable, Equatable, Sendable {
    var mid: String
    var name: String
    var kind: String
}

struct PublishedTrack: Encodable, Equatable, Sendable {
    var mid: String
    var name: String
}

/// Mirrors `ServerMessage` in realtime/src/protocol.ts. Change both together.
enum ServerMessage: Equatable, Sendable {
    case welcome(iceServers: [IceServer])
    case answer(SessionDescription)
    case offer(SessionDescription, tracks: [OfferedTrack])
    case caption(id: String, role: String, text: String, isFinal: Bool)
    case state(String)
    case agent(present: Bool)
    case screen(live: Bool)
    case ended(reason: String)
    case error(String)
    case other

    static func decode(_ text: String) -> ServerMessage? {
        guard let raw = try? JSONDecoder().decode(Raw.self, from: Data(text.utf8)) else { return nil }
        switch raw.t {
        case "welcome": return .welcome(iceServers: raw.iceServers ?? [])
        case "answer": return raw.answer.map { .answer($0) }
        case "offer": return raw.offer.map { .offer($0, tracks: raw.tracks ?? []) }
        case "caption":
            guard let id = raw.id, let role = raw.role, let text = raw.text else { return nil }
            return .caption(id: id, role: role, text: text, isFinal: raw.final ?? false)
        case "state": return raw.state.map { .state($0) }
        case "agent": return .agent(present: raw.present ?? false)
        case "screen": return .screen(live: raw.live ?? false)
        case "ended": return .ended(reason: raw.reason ?? "ended")
        case "error": return .error(raw.message ?? "unknown error")
        default: return .other
        }
    }

    private struct Raw: Decodable {
        var t: String
        var iceServers: [IceServer]?
        var answer: SessionDescription?
        var offer: SessionDescription?
        var tracks: [OfferedTrack]?
        var id: String?
        var role: String?
        var text: String?
        var final: Bool?
        var state: String?
        var present: Bool?
        var live: Bool?
        var reason: String?
        var message: String?
    }
}

/// Mirrors `ClientMessage` in realtime/src/protocol.ts (the caller's subset).
enum ClientMessage: Equatable, Sendable {
    case publish(offer: SessionDescription, tracks: [PublishedTrack])
    case answer(SessionDescription)
    case camera(on: Bool)
    case hangup
    /// Receive the agent's tracks before publishing anything.
    case subscribe
    case ping

    func encoded() -> String {
        let body: Out
        switch self {
        case let .publish(offer, tracks): body = Out(t: "publish", offer: offer, tracks: tracks)
        case let .answer(answer): body = Out(t: "answer", answer: answer)
        case let .camera(on): body = Out(t: "camera", on: on)
        case .hangup: body = Out(t: "hangup")
        case .subscribe: body = Out(t: "subscribe")
        case .ping: body = Out(t: "ping")
        }
        return (try? JSONEncoder().encode(body)).map { String(decoding: $0, as: UTF8.self) } ?? #"{"t":"ping"}"#
    }

    private struct Out: Encodable {
        var t: String
        var offer: SessionDescription?
        var answer: SessionDescription?
        var tracks: [PublishedTrack]?
        var on: Bool?
    }
}
