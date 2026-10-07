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

    private final class Events: PeerConnectionEvents {
        func peerConnection(received media: RemoteMedia, mid: String) {}
        func peerConnectionFailed() {}
    }
}
