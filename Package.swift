// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LlamaCalls",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "LlamaCalls", targets: ["LlamaCalls"])],
    dependencies: [
        // The range the LiveKit Swift SDK resolves too, so an app that keeps it links one WebRTC.
        .package(url: "https://github.com/livekit/webrtc-xcframework.git", "144.7559.0"..<"151.0.0"),
    ],
    targets: [
        .target(name: "LlamaCalls", dependencies: [.product(name: "LiveKitWebRTC", package: "webrtc-xcframework")]),
        .testTarget(name: "LlamaCallsTests", dependencies: ["LlamaCalls"]),
    ]
)
