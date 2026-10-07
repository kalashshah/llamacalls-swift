#if canImport(UIKit)
import LiveKitWebRTC
import SwiftUI
import UIKit

/// Draws a call's video track. The only view in the package: layout and controls are the app's.
public struct LlamaCallVideoView: UIViewRepresentable {
    private let track: VideoTrack?
    private let contentMode: UIView.ContentMode

    public init(_ track: VideoTrack?, contentMode: UIView.ContentMode = .scaleAspectFill) {
        self.track = track
        self.contentMode = contentMode
    }

    public func makeUIView(context: Context) -> LKRTCMTLVideoView {
        let view = LKRTCMTLVideoView(frame: .zero)
        view.videoContentMode = contentMode
        attach(view, coordinator: context.coordinator)
        return view
    }

    public func updateUIView(_ view: LKRTCMTLVideoView, context: Context) {
        view.videoContentMode = contentMode
        attach(view, coordinator: context.coordinator)
    }

    public static func dismantleUIView(_ view: LKRTCMTLVideoView, coordinator: Coordinator) {
        (coordinator.attached?.underlying as? LKRTCVideoTrack)?.remove(view)
        coordinator.attached = nil
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public final class Coordinator {
        var attached: VideoTrack?
    }

    private func attach(_ view: LKRTCMTLVideoView, coordinator: Coordinator) {
        guard coordinator.attached != track else { return }
        (coordinator.attached?.underlying as? LKRTCVideoTrack)?.remove(view)
        (track?.underlying as? LKRTCVideoTrack)?.add(view)
        coordinator.attached = track
    }
}
#endif
