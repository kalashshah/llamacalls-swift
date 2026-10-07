import XCTest
@testable import LlamaCalls

final class ExtmapTests: XCTestCase {
    /// Captured from a failing publish: the room's offer put transport-cc on id 1, and libwebrtc then
    /// gave the new mic section ssrc-audio-level on id 1 as well.
    let remote = "v=0\r\nm=audio 1473 UDP/TLS/RTP/SAVPF 111 0 8\r\na=mid:0\r\na=extmap:1 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01\r\n"
    let local = "v=0\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:0\r\na=extmap:1 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01\r\nm=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:1\r\na=extmap:1 http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01\r\na=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\r\na=extmap:2 http://www.webrtc.org/experiments/rtp-hdrext/abs-send-time\r\na=extmap:4 urn:ietf:params:rtp-hdrext:sdes:mid\r\n"

    private func extmaps(_ sdp: String) -> [(Int, String)] {
        sdp.components(separatedBy: "\r\n").compactMap { line in
            guard line.hasPrefix("a=extmap:") else { return nil }
            let parts = line.dropFirst("a=extmap:".count).split(separator: " ")
            return (Int(parts[0].split(separator: "/")[0])!, String(parts[1]))
        }
    }

    func testEveryIdNamesOneExtensionAndTheRoomsIdsStand() {
        let aligned = Extmap.align(local, toRemote: remote)
        var uriById: [Int: String] = [:]
        for (id, uri) in extmaps(aligned) {
            if let seen = uriById[id] { XCTAssertEqual(seen, uri, "id \(id) names two extensions") }
            uriById[id] = uri
        }
        XCTAssertEqual(uriById[1], "http://www.ietf.org/id/draft-holmer-rmcat-transport-wide-cc-extensions-01")
        XCTAssertEqual(Set(extmaps(aligned).map(\.1)).count, 4, "no extension dropped")
        XCTAssertTrue(aligned.hasSuffix("\r\n"))
    }

    func testAnExtensionKeepsOneIdAcrossSections() {
        let twice = local + "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=mid:2\r\na=extmap:1 urn:ietf:params:rtp-hdrext:ssrc-audio-level\r\n"
        let ids = extmaps(Extmap.align(twice, toRemote: remote)).filter { $0.1 == "urn:ietf:params:rtp-hdrext:ssrc-audio-level" }.map(\.0)
        XCTAssertEqual(Set(ids).count, 1)
    }

    func testNothingToAlignWithLeavesTheOfferAlone() {
        XCTAssertEqual(Extmap.align(local, toRemote: nil), local)
    }
}
