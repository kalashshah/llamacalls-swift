import XCTest
@testable import LlamaCalls

@MainActor final class LlamaCallTests: XCTestCase {
    var media: FakeMedia!
    var audio: FakeAudioSession!
    var call: LlamaCall!

    override func setUp() async throws {
        media = FakeMedia()
        audio = FakeAudioSession()
        call = LlamaCall(media: media, audioSession: audio, configuresAudioSession: true,
                         pingInterval: .milliseconds(50), answerTimeout: .milliseconds(300), now: { Date(timeIntervalSince1970: 100) })
    }

    /// Connects and welcomes; returns the room's socket.
    func connected() async throws -> FakeSocket {
        let connecting = Task { try await call.connect(room: "api-1", url: URL(string: "https://rt.example")!, token: "TOK") }
        await settle()
        media.socket!.server(#"{"t":"welcome","identity":"u","iceServers":[{"urls":"stun:a"}]}"#)
        try await connecting.value
        return media.socket!
    }

    func testConnectsWithTokenAndGoesLiveOnWelcome() async throws {
        let socket = try await connected()
        XCTAssertEqual(socket.url.absoluteString, "wss://rt.example/rooms/api-1/connect?token=TOK")
        XCTAssertEqual(call.state, .live)
        XCTAssertTrue(audio.active)
    }

    func testCloseBeforeWelcomeIsRefusedAndNeverOpeningIsUnreachable() async {
        for (opened, expected) in [(true, LlamaCallError.refused), (false, .unreachable)] {
            let call = LlamaCall(media: media, audioSession: audio, configuresAudioSession: false,
                                 pingInterval: .seconds(30), answerTimeout: .seconds(1), now: Date.init)
            let connecting = Task { try await call.connect(room: "r", url: URL(string: "https://rt.example")!, token: "T") }
            await settle()
            media.socket!.serverClose(opened: opened)
            do { try await connecting.value; XCTFail("expected a throw") } catch { XCTAssertEqual(error as? LlamaCallError, expected) }
        }
    }

    func testMessageInSameBurstAsWelcomeIsApplied() async throws {
        let connecting = Task { try await call.connect(room: "api-1", url: URL(string: "https://rt.example")!, token: "TOK") }
        await settle()
        media.socket!.server(#"{"t":"welcome","identity":"u","iceServers":[]}"#)
        media.socket!.server(#"{"t":"agent","present":true}"#)
        try await connecting.value
        XCTAssertTrue(call.agentPresent)
    }

    func testCaptionsMergeByIdAndStateIsTracked() async throws {
        let socket = try await connected()
        socket.server(#"{"t":"caption","id":"u0","role":"user","text":"hel","final":false}"#)
        socket.server(#"{"t":"caption","id":"u0","role":"user","text":"hello","final":true}"#)
        socket.server(#"{"t":"caption","id":"a0","role":"agent","text":"Hi","final":true}"#)
        socket.server(#"{"t":"state","state":"thinking"}"#)
        XCTAssertEqual(call.captions.map(\.text), ["hello", "Hi"])
        XCTAssertEqual(call.captions.map(\.role), [.user, .agent])
        XCTAssertEqual(call.captions.first?.isFinal, true)
        XCTAssertEqual(call.agentState, .thinking)
        socket.server(#"{"t":"agent","present":false}"#)
        XCTAssertFalse(call.agentPresent)
        XCTAssertNil(call.agentState)
    }

    func testRoutesRemoteTracksByName() async throws {
        let socket = try await connected()
        socket.server(#"{"t":"offer","offer":{"type":"offer","sdp":"S"},"tracks":[{"mid":"1","name":"agent-voice","kind":"audio"},{"mid":"2","name":"agent-face","kind":"video"}]}"#)
        await settle()
        let face = VideoTrack(NSObject())
        let voice = FakeRemoteAudio()
        media.events!.peerConnection(received: .audio(voice), mid: "1")
        media.events!.peerConnection(received: .video(face), mid: "2")
        XCTAssertEqual(call.faceTrack, face)
        XCTAssertEqual(voice.taps, 1)
    }

    func testAgentVolumeReachesLateTrack() async throws {
        let socket = try await connected()
        call.agentVolume = 0
        socket.server(#"{"t":"offer","offer":{"type":"offer","sdp":"S"},"tracks":[{"mid":"5","name":"agent-face-voice","kind":"audio"}]}"#)
        await settle()
        let late = FakeRemoteAudio()
        media.events!.peerConnection(received: .audio(late), mid: "5")
        XCTAssertEqual(late.volume, 0)
        call.agentVolume = 1
        XCTAssertEqual(late.volume, 1)
    }

    func testMicrophonePublishesOnceThenToggles() async throws {
        let socket = try await connected()
        let enabling = Task { try await call.setMicrophone(true) }
        await settle()
        socket.server(#"{"t":"answer","answer":{"type":"answer","sdp":"A"}}"#)
        try await enabling.value
        XCTAssertTrue(call.isMicrophoneOn)
        try await call.setMicrophone(false)
        XCTAssertEqual(media.madeMicrophone?.isEnabled, false)
        XCTAssertEqual(socket.sentTypes.filter { $0 == "publish" }.count, 1)
    }

    func testMicrophoneDenied() async throws {
        _ = try await connected()
        media.micAllowed = false
        do { try await call.setMicrophone(true); XCTFail("expected a throw") } catch {
            XCTAssertEqual(error as? LlamaCallError, .microphoneDenied)
        }
    }

    func testCameraPreviewThenPublishThenOffAndOn() async throws {
        let socket = try await connected()
        try await call.setCamera(true, publish: false)
        XCTAssertNotNil(call.selfTrack)
        XCTAssertEqual(socket.sentTypes.filter { $0 == "publish" }.count, 0)
        let publishing = Task { try await call.setCamera(true) }
        await settle()
        socket.server(#"{"t":"answer","answer":{"type":"answer","sdp":"A"}}"#)
        try await publishing.value
        XCTAssertEqual(socket.sentTypes.filter { $0 == "publish" }.count, 1)
        try await call.setCamera(false)
        XCTAssertFalse(media.madeCamera!.running)
        XCTAssertNil(call.selfTrack)
        try await call.setCamera(true)
        XCTAssertTrue(media.madeCamera!.running)
        XCTAssertEqual(socket.sentTypes.suffix(2), ["camera", "camera"])
        XCTAssertEqual(socket.sentTypes.filter { $0 == "publish" }.count, 1)
    }

    func testErrorDuringPublishEndsTheCall() async throws {
        let socket = try await connected()
        let enabling = Task { try await call.setMicrophone(true) }
        await settle()
        socket.server(#"{"t":"error","message":"media negotiation failed"}"#)
        _ = try? await enabling.value
        XCTAssertEqual(call.state, .ended(reason: "media negotiation failed"))
    }

    func testEndedTearsDownOnce() async throws {
        let socket = try await connected()
        socket.server(#"{"t":"ended","reason":"empty"}"#)
        socket.serverClose()
        XCTAssertEqual(call.state, .ended(reason: "empty"))
        XCTAssertTrue(media.peer.closed)
        XCTAssertTrue(socket.closed)
        XCTAssertFalse(audio.active)
    }

    func testHangUpSendsHangupBeforeClosingAndLeaveDoesNot() async throws {
        var socket = try await connected()
        await call.hangUp()
        XCTAssertEqual(socket.sentTypes.last, "hangup")
        XCTAssertTrue(socket.closed)
        XCTAssertEqual(call.state, .ended(reason: "hung up"))

        call = LlamaCall(media: media, audioSession: audio, configuresAudioSession: false,
                         pingInterval: .seconds(30), answerTimeout: .seconds(1), now: Date.init)
        socket = try await connected()
        await call.leave()
        XCTAssertFalse(socket.sentTypes.contains("hangup"))
        XCTAssertEqual(call.state, .ended(reason: "left"))
    }

    func testHangUpDuringPublishEndsOnce() async throws {
        _ = try await connected()
        let enabling = Task { try await call.setMicrophone(true) }
        await settle()
        await call.hangUp()
        _ = try? await enabling.value
        XCTAssertEqual(call.state, .ended(reason: "hung up"))
    }

    func testPings() async throws {
        let socket = try await connected()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertTrue(socket.sentTypes.contains("ping"))
    }

    func testScreenFramesOnlyWhileLive() async throws {
        let socket = try await connected()
        socket.onData?(Data([1]))
        await settle()
        XCTAssertNil(call.screen)
        socket.server(#"{"t":"screen","live":true}"#)
        socket.onData?(Data([1]))
        await settle()
        XCTAssertNotNil(call.screen)
        socket.server(#"{"t":"screen","live":false}"#)
        XCTAssertNil(call.screen)
    }

    func testSecondConnectIsRefused() async throws {
        _ = try await connected()
        do { try await call.connect(room: "r", url: URL(string: "https://rt.example")!, token: "T"); XCTFail("expected a throw") } catch {
            XCTAssertEqual(error as? LlamaCallError, .alreadyStarted)
        }
    }

    func testParsesJoinUrl() {
        let parts = LlamaCall.parse(joinUrl: URL(string: "https://llamacalls.com/embed/api-9#url=https%3A%2F%2Frealtime.llamacalls.com&token=T.K&name=Priya")!)
        XCTAssertEqual(parts?.room, "api-9")
        XCTAssertEqual(parts?.url.absoluteString, "https://realtime.llamacalls.com")
        XCTAssertEqual(parts?.token, "T.K")
        XCTAssertNil(LlamaCall.parse(joinUrl: URL(string: "https://llamacalls.com/embed/api-9")!))
    }

    func testEndedBeforeWelcomeThrowsInsteadOfHanging() async {
        let connecting = Task { try await call.connect(room: "r", url: URL(string: "https://rt.example")!, token: "T") }
        await settle()
        media.socket!.server(#"{"t":"ended","reason":"room closed"}"#)
        media.socket!.serverClose()
        do { try await connecting.value; XCTFail("expected a throw") } catch {
            XCTAssertEqual(error as? LlamaCallError, .refused)
        }
    }

    func testHangUpWhileConnectingThrowsNotConnected() async {
        let connecting = Task { try await call.connect(room: "r", url: URL(string: "https://rt.example")!, token: "T") }
        await settle()
        await call.hangUp()
        do { try await connecting.value; XCTFail("expected a throw") } catch {
            XCTAssertEqual(error as? LlamaCallError, .notConnected)
        }
        XCTAssertEqual(call.state, .ended(reason: "hung up"))
    }

    func testAFailedMicPublishCanBeRetried() async throws {
        let socket = try await connected()
        do { try await call.setMicrophone(true); XCTFail("expected a timeout") } catch {}
        XCTAssertFalse(call.isMicrophoneOn)
        let retry = Task { try await call.setMicrophone(true) }
        await settle()
        socket.server(#"{"t":"answer","answer":{"type":"answer","sdp":"A"}}"#)
        try await retry.value
        XCTAssertTrue(call.isMicrophoneOn)
        XCTAssertEqual(socket.sentTypes.filter { $0 == "publish" }.count, 2)
    }

    func testCameraStartingAfterTheCallEndedIsStoppedAgain() async throws {
        _ = try await connected()
        media.slowCamera = true
        let starting = Task { try await call.setCamera(true, publish: false) }
        await settle()
        await call.leave()
        media.madeCamera?.finishStart()
        _ = try? await starting.value
        XCTAssertEqual(media.madeCamera?.running, false)
        XCTAssertFalse(call.isCameraOn)
    }
}
