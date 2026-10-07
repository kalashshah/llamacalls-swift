import XCTest
@testable import LlamaCalls

final class ProtocolTests: XCTestCase {
    func testDecodesWelcomeWithStringOrArrayUrls() {
        let one = ServerMessage.decode(#"{"t":"welcome","identity":"u","iceServers":[{"urls":"stun:a"}]}"#)
        XCTAssertEqual(one, .welcome(iceServers: [IceServer(urls: ["stun:a"])]))
        let many = ServerMessage.decode(#"{"t":"welcome","identity":"u","iceServers":[{"urls":["turn:b"],"username":"x","credential":"y"}]}"#)
        XCTAssertEqual(many, .welcome(iceServers: [IceServer(urls: ["turn:b"], username: "x", credential: "y")]))
    }

    func testDecodesOfferWithTracks() {
        let message = ServerMessage.decode(#"{"t":"offer","offer":{"type":"offer","sdp":"S"},"tracks":[{"mid":"3","name":"agent-voice","kind":"audio"}]}"#)
        XCTAssertEqual(message, .offer(SessionDescription(type: "offer", sdp: "S"), tracks: [OfferedTrack(mid: "3", name: "agent-voice", kind: "audio")]))
    }

    func testDecodesTheRest() {
        XCTAssertEqual(ServerMessage.decode(#"{"t":"answer","answer":{"type":"answer","sdp":"A"}}"#), .answer(SessionDescription(type: "answer", sdp: "A")))
        XCTAssertEqual(ServerMessage.decode(#"{"t":"caption","id":"c1","role":"agent","text":"Hi","final":true}"#), .caption(id: "c1", role: "agent", text: "Hi", isFinal: true))
        XCTAssertEqual(ServerMessage.decode(#"{"t":"state","state":"speaking"}"#), .state("speaking"))
        XCTAssertEqual(ServerMessage.decode(#"{"t":"agent","present":false}"#), .agent(present: false))
        XCTAssertEqual(ServerMessage.decode(#"{"t":"screen","live":true}"#), .screen(live: true))
        XCTAssertEqual(ServerMessage.decode(#"{"t":"ended","reason":"hung up"}"#), .ended(reason: "hung up"))
        XCTAssertEqual(ServerMessage.decode(#"{"t":"error","message":"boom"}"#), .error("boom"))
        XCTAssertEqual(ServerMessage.decode(#"{"t":"pong"}"#), .other)
        XCTAssertNil(ServerMessage.decode("not json"))
    }

    func testEncodesClientMessages() throws {
        func object(_ message: ClientMessage) throws -> NSDictionary {
            try JSONSerialization.jsonObject(with: Data(message.encoded().utf8)) as! NSDictionary
        }
        XCTAssertEqual(try object(.ping), ["t": "ping"])
        XCTAssertEqual(try object(.hangup), ["t": "hangup"])
        XCTAssertEqual(try object(.camera(on: false)), ["t": "camera", "on": false])
        XCTAssertEqual(try object(.answer(SessionDescription(type: "answer", sdp: "A"))), ["t": "answer", "answer": ["type": "answer", "sdp": "A"]])
        XCTAssertEqual(
            try object(.publish(offer: SessionDescription(type: "offer", sdp: "O"), tracks: [PublishedTrack(mid: "0", name: "mic")])),
            ["t": "publish", "offer": ["type": "offer", "sdp": "O"], "tracks": [["mid": "0", "name": "mic"]]]
        )
    }
}
