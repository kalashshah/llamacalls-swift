import XCTest
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
        print("LIVE room:", body["room"] ?? "?")
        let call = LlamaCall(configuresAudioSession: false)
        try await call.connect(room: body["room"] as! String, url: URL(string: body["url"] as! String)!, token: body["token"] as! String)
        XCTAssertEqual(call.state, .live)
        try await call.setMicrophone(true)
        let deadline = Date().addingTimeInterval(20)
        while !call.captions.contains(where: { $0.role == .agent && $0.isFinal }) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertEqual(call.captions.first(where: { $0.role == .agent })?.text, "Hi, this is Priya.")
        await call.hangUp()
        XCTAssertEqual(call.state, .ended(reason: "hung up"))
        // Let the socket drain the hangup before the process exits.
        try await Task.sleep(for: .seconds(2))
    }
}
