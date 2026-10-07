import XCTest

func step(_ s: String) { FileHandle.standardError.write(Data("STEP \(Date().timeIntervalSince1970) \(s)\n".utf8)) }
@testable import LlamaCalls

/// A real call against llamacalls.com. Runs only with LLAMACALLS_LIVE_KEY set; costs about a cent.
@MainActor final class LiveCallTests: XCTestCase {
    func testARealCallGreetsAndHangsUp() async throws {
        guard let key = ProcessInfo.processInfo.environment["LLAMACALLS_LIVE_KEY"] else { throw XCTSkip("no live key") }
        var request = URLRequest(url: URL(string: "https://llamacalls.com/api/calls")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = Data(#"{"agent":{"name":"Priya","greeting":"Hi, this is Priya.","capabilities":{"face":"none","recording":"transcript"}}}"#.utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        step("created \(body["room"] ?? "?")")
        let call = LlamaCall(configuresAudioSession: false)
        try await call.connect(room: body["room"] as! String, url: URL(string: body["url"] as! String)!, token: body["token"] as! String)
        step("connected")
        XCTAssertEqual(call.state, .live)
        // Dryrun's flow: nothing published until the agent is there.
        let present = Date().addingTimeInterval(20)
        while !call.agentPresent && Date() < present { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertTrue(call.agentPresent, "the agent never arrived for a caller that had not published")
        XCTAssertEqual(call.agentState, .listening)
        XCTAssertFalse(call.captions.contains { $0.role == .agent }, "greeted before the caller's mic was up")
        step("present=\(call.agentPresent) state=\(String(describing: call.agentState))")
        do { try await call.setMicrophone(true) } catch { step("mic failed: \(error) state=\(call.state)"); throw error }
        step("mic published")
        let deadline = Date().addingTimeInterval(20)
        while !call.captions.contains(where: { $0.role == .agent && $0.isFinal }) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(call.captions.first(where: { $0.role == .agent })?.text, "Hi, this is Priya.")
        step("captions \(call.captions.map(\.text))")
        await call.hangUp()
        step("hung up")
        XCTAssertEqual(call.state, .ended(reason: "hung up"))
        // Let the socket drain the hangup before the process exits.
        try await Task.sleep(for: .seconds(2))
    }
}
