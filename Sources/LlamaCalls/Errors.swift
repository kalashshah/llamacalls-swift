/// Thrown by the calls that start something. A call that ends after connecting is `LlamaCall.State.ended`.
public enum LlamaCallError: Error, Equatable, Sendable {
    /// The room could not be reached at all.
    case unreachable
    /// The room answered and then closed before welcoming us (a bad or expired token).
    case refused
    case notConnected
    case alreadyStarted
    case invalidJoinUrl
    case negotiationFailed(String)
    case microphoneDenied
    case cameraDenied
}
