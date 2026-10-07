extension LlamaCall {
    /// `configuresAudioSession`: false for an app that manages `AVAudioSession` itself.
    public convenience init(configuresAudioSession: Bool = true) {
        self.init(media: WebRTCMedia(), audioSession: SystemAudioSession(), configuresAudioSession: configuresAudioSession)
    }
}
