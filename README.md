# LlamaCalls for iOS

Run a [LlamaCalls](https://llamacalls.com) voice or video call natively in your iOS app. The package
joins the call, publishes the microphone and camera, plays the agent's voice and gives you its face,
captions and state. Your app draws everything: the package has no UI beyond a view that renders a
video track.

## Install

Swift Package Manager, iOS 17+:

```swift
.package(url: "https://github.com/kalashshah/llamacalls-swift.git", from: "0.1.0")
```

Add `NSMicrophoneUsageDescription` to your `Info.plist`, and `NSCameraUsageDescription` if callers
can turn their camera on.

## Start the call on your server

Your API key spends your account's credit, so it stays on your server. Start the call there and hand
the app what it answers:

```bash
curl https://llamacalls.com/api/calls \
  -H "Authorization: Bearer $LLAMACALLS_KEY" -H "Content-Type: application/json" \
  -d '{"agent": {"name": "Priya", "instructions": "You are Priya, a hiring manager…"}}'
# → { "room": "api-…", "url": "https://realtime.llamacalls.com", "token": "…", "joinUrl": "…" }
```

Everything an agent can be set up with goes in `agent`; see the
[API documentation](https://llamacalls.com/developers). The token opens this one call only, so it is
safe to send to the app.

## Join it from the app

```swift
import LlamaCalls
import SwiftUI

struct CallScreen: View {
    @State private var call = LlamaCall()
    let room: String, url: URL, token: String

    var body: some View {
        VStack {
            LlamaCallVideoView(call.faceTrack)
            Text(call.captions.last?.text ?? "")
            Button("Hang up") { Task { await call.hangUp() } }
        }
        .task {
            try? await call.connect(room: room, url: url, token: token)
            try? await call.setMicrophone(true)
        }
        // A call is not torn down when the view goes away; leave it, or it keeps the mic open.
        .onDisappear { Task { await call.leave() } }
    }
}
```

`connect(joinUrl:)` takes the `joinUrl` from the same answer instead of the three values.

## What `LlamaCall` gives you

| | |
|---|---|
| `state` | `.idle`, `.connecting`, `.live`, `.ended(reason:)`. A call that ends after connecting is a state, never a thrown error |
| `agentPresent`, `agentState` | Whether the agent is in the call, and `.listening`, `.thinking` or `.speaking` |
| `captions` | Both sides, as `Caption(id, role, text, isFinal, receivedAt)`, updated in place by id |
| `faceTrack` | The agent's face, when it has one. Draw it with `LlamaCallVideoView` |
| `selfTrack` | Your camera while it is on |
| `screen` | The latest frame of a page the agent is sharing, as an image; nil when it is not |
| `isMicrophoneOn`, `isCameraOn` | |
| `agentVolume` | 0…1, local only. 0 holds the agent silent, e.g. behind an intro screen |
| `onMicrophoneAudio`, `onAgentAudio` | Raw `AVAudioPCMBuffer`s for level meters, on the audio thread |
| `setMicrophone(_:)` | The first `true` asks permission and publishes; later calls mute and unmute |
| `setCamera(_:publish:)` | `publish: false` shows `selfTrack` without sending anything until a later `setCamera(true)` |
| `hangUp()` | Ends the call for everyone, now |
| `leave()` | Leaves; the call ends a minute later unless someone rejoins |

`LlamaCall(configuresAudioSession: false)` leaves `AVAudioSession` to your app. By default the
package sets play-and-record, voice chat, speaker and Bluetooth for the length of the call.

Errors (`LlamaCallError`): `unreachable`, `refused` (a bad or expired token), `notConnected`,
`alreadyStarted`, `invalidJoinUrl`, `negotiationFailed(String)`, `microphoneDenied`, `cameraDenied`.

## Tests

`swift test` runs the protocol and negotiation logic against fakes, plus a real WebRTC offer on
macOS. `LLAMACALLS_LIVE_KEY=lc_live_… swift test --filter LiveCallTests` places a real call (about a
cent).
