import XCTest
@testable import LlamaCalls

@MainActor final class NegotiatorTests: XCTestCase {
    var peer: FakePeer!
    var sent: [ClientMessage] = []
    var negotiator: Negotiator!

    override func setUp() async throws {
        peer = FakePeer()
        sent = []
        negotiator = Negotiator(peer: peer, send: { [unowned self] in sent.append($0) }, answerTimeout: .milliseconds(200))
    }

    private var publishCount: Int {
        sent.filter { if case .publish = $0 { return true } else { return false } }.count
    }

    func testAnswersARoomOfferAndRemembersTrackNames() async {
        negotiator.receiveOffer(SessionDescription(type: "offer", sdp: "ROOM"), tracks: [OfferedTrack(mid: "3", name: "agent-voice", kind: "audio")])
        await settle()
        XCTAssertEqual(peer.log, ["remote:offer:ROOM", "createAnswer", "local:answer"])
        XCTAssertEqual(sent, [.answer(SessionDescription(type: "answer", sdp: "LOCAL-ANSWER"))])
        XCTAssertEqual(negotiator.name(forMid: "3"), "agent-voice")
    }

    func testPublishSendsOfferAndAppliesAnswer() async throws {
        let publishing = Task { try await negotiator.publish(FakeTrack(), as: "mic") }
        await settle()
        XCTAssertEqual(sent, [.publish(offer: SessionDescription(type: "offer", sdp: "LOCAL-OFFER"), tracks: [PublishedTrack(mid: "0", name: "mic")])])
        negotiator.receiveAnswer(SessionDescription(type: "answer", sdp: "ROOM-ANSWER"))
        try await publishing.value
        XCTAssertEqual(peer.log, ["addTransceiver", "createOffer", "local:offer", "remote:answer:ROOM-ANSWER"])
    }

    func testGlareRollsBackAnswersTheRoomAndRetries() async throws {
        let publishing = Task { try await negotiator.publish(FakeTrack(), as: "mic") }
        await settle()
        negotiator.receiveOffer(SessionDescription(type: "offer", sdp: "CROSSING"), tracks: [])
        await settle()
        XCTAssertEqual(Array(peer.log.suffix(6)), ["rollback", "remote:offer:CROSSING", "createAnswer", "local:answer", "createOffer", "local:offer"])
        negotiator.receiveAnswer(SessionDescription(type: "answer", sdp: "A2"))
        try await publishing.value
        XCTAssertEqual(publishCount, 2)
    }

    func testAnOfferThatLandsWhileOursIsBuiltIsNotSentAndIsGlare() async throws {
        peer.duringCreateOffer = { [unowned self] in
            negotiator.receiveOffer(SessionDescription(type: "offer", sdp: "EARLY"), tracks: [])
        }
        let publishing = Task { try await negotiator.publish(FakeTrack(), as: "mic") }
        await settle()
        XCTAssertTrue(peer.log.contains("rollback"))
        negotiator.receiveAnswer(SessionDescription(type: "answer", sdp: "A"))
        try await publishing.value
        // The first offer was never sent: only the retry was.
        XCTAssertEqual(publishCount, 1)
    }

    func testAnErrorDuringAPublishFailsIt() async {
        let publishing = Task { try await negotiator.publish(FakeTrack(), as: "mic") }
        await settle()
        XCTAssertTrue(negotiator.receiveError("media negotiation failed"))
        do { try await publishing.value; XCTFail("expected a throw") } catch {
            XCTAssertEqual(error as? LlamaCallError, .negotiationFailed("media negotiation failed"))
        }
        XCTAssertFalse(negotiator.receiveError("the room's own"))
    }

    func testAnUnansweredPublishTimesOut() async {
        do { try await negotiator.publish(FakeTrack(), as: "mic"); XCTFail("expected a throw") } catch {
            XCTAssertEqual(error as? LlamaCallError, .negotiationFailed("the call did not answer our media in time"))
        }
    }

    func testCancelFailsAWaitingPublish() async {
        let publishing = Task { try await negotiator.publish(FakeTrack(), as: "mic") }
        await settle()
        negotiator.cancel()
        do { try await publishing.value; XCTFail("expected a throw") } catch {
            XCTAssertEqual(error as? LlamaCallError, .notConnected)
        }
    }

    func testPublishAlignsItsOfferWithTheRoomsHeaderExtensions() async throws {
        peer.remoteSDP = "m=audio 1 RTP/SAVPF 111\r\na=extmap:1 urn:transport-cc\r\n"
        peer.offerSDP = "m=audio 9 RTP/SAVPF 111\r\na=extmap:1 urn:audio-level\r\n"
        let publishing = Task { try await negotiator.publish(FakeTrack(), as: "mic") }
        await settle()
        guard case let .publish(offer, _) = sent.first else { return XCTFail("nothing published") }
        XCTAssertEqual(offer.sdp, "m=audio 9 RTP/SAVPF 111\r\na=extmap:2 urn:audio-level\r\n")
        XCTAssertTrue(peer.log.contains("local:offer"))
        XCTAssertEqual(peer.lastLocalSDP, offer.sdp)
        negotiator.receiveAnswer(SessionDescription(type: "answer", sdp: "A"))
        try await publishing.value
    }
}
