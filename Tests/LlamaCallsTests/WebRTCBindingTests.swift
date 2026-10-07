import LiveKitWebRTC
import XCTest
@testable import LlamaCalls

/// The peer's two load-bearing delegate methods are optional in Objective-C, so a misspelt
/// Swift name compiles and is never called. These pin the selectors WebRTC actually invokes.
@MainActor final class WebRTCBindingTests: XCTestCase {
    func testPeerAnswersTheSelectorsWebRTCCalls() throws {
        let peer = try WebRTCPeer(iceServers: [IceServer(urls: ["stun:stun.cloudflare.com:3478"])], events: Events())
        XCTAssertTrue(peer.responds(to: NSSelectorFromString("peerConnection:didStartReceivingOnTransceiver:")))
        XCTAssertTrue(peer.responds(to: NSSelectorFromString("peerConnection:didChangeConnectionState:")))
        peer.close()
    }

    func testOfferAndRollbackWorkOnARealPeer() async throws {
        let peer = try WebRTCPeer(iceServers: [], events: Events())
        let media = WebRTCMedia()
        let mic = media.makeMicrophone(tap: { _ in })
        let transceiver = try peer.addTransceiver(sending: mic)
        let offer = try await peer.createOffer()
        XCTAssertEqual(offer.type, "offer")
        XCTAssertTrue(offer.sdp.contains("m=audio"))
        try await peer.setLocalDescription(offer)
        XCTAssertEqual(transceiver.mid, "0")
        try await peer.rollback()
        peer.close()
    }

    /// A fresh source reads 1.0, WebRTC's unity gain, so full agent volume must map to 1.0, not amplify it.
    /// (Setting the volume only takes effect on remote sources, which this test cannot make.)
    func testAgentVolumeOneIsUnityGain() {
        let factory = WebRTCMedia.factory
        let track = factory.audioTrack(with: factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)), trackId: "probe")
        XCTAssertEqual(track.source.volume, 1)
        XCTAssertEqual(WebRTCRemoteAudio(track).volume, 1)
    }

    /// Closing detaches the delegate first: WebRTC's signaling thread can still be delivering a
    /// callback while the peer is freed, and a weak delegate is not cleared until after its ivars go.
    func testCloseDetachesTheDelegateBeforeTheCallbacksCanReachAFreedPeer() throws {
        let peer = try WebRTCPeer(iceServers: [], events: Events())
        peer.close()
        XCTAssertNil(peer.connectionDelegate)
    }

    /// WebRTC can still reach a tap after we remove it (removal happens on its own thread), so a tap
    /// must live as long as the track it was added to, not as long as our wrapper.
    func testATapOutlivesItsWrapperWhileTheTrackLives() {
        let factory = WebRTCMedia.factory
        let track = factory.audioTrack(with: factory.audioSource(with: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)), trackId: "probe")
        weak var tap: PCMRenderer?
        do {
            let audio = WebRTCRemoteAudio(track)
            audio.tap { _ in }
            tap = audio.lastTap
            audio.detach()
        }
        XCTAssertNotNil(tap, "the tap was freed while WebRTC may still call it")
        withExtendedLifetime(track) {}
    }

    /// A peer dropped without close() (an app releasing a live call) must close itself, delegate first,
    /// or WebRTC's signaling thread calls into it while it is being freed.
    func testAPeerDroppedWithoutCloseClosesItself() throws {
        var peer: WebRTCPeer? = try WebRTCPeer(iceServers: [], events: Events())
        let raw = try XCTUnwrap(peer?.raw)
        peer = nil
        XCTAssertEqual(raw.connectionState, .closed)
        XCTAssertNil(raw.delegate)
    }

    private final class Events: PeerConnectionEvents {
        func peerConnection(received media: RemoteMedia, mid: String) {}
        func peerConnectionFailed() {}
    }
}
