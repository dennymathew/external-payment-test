import Foundation

public enum ExternalPurchaseError: Error, Equatable, Sendable, LocalizedError {
    case ineligible
    case tokenFetchFailed(String)
    /// StoreKit returned a token, but it didn't decode. Not retryable — see
    /// `TokenHealth.malformed`.
    case malformedToken(TokenDecodingError)
    case sessionCreationFailed(String)
    case verificationFailed(String)
    case presentationFailed(String)
    /// The webview landed on the handoff-failure page (already redeemed,
    /// expired, wrong session, or rejected) — the auth handoff itself was
    /// refused, distinct from a payment failure.
    case handoffRejected
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .ineligible:
            return "This account isn't eligible for external purchases."
        case .tokenFetchFailed(let message):
            return "Couldn't fetch a purchase token: \(message)"
        case .malformedToken(let error):
            return "Received an unreadable purchase token: \(error)"
        case .sessionCreationFailed(let message):
            return "Couldn't start checkout: \(message)"
        case .verificationFailed(let message):
            return "Couldn't verify payment: \(message)"
        case .presentationFailed(let message):
            return "Couldn't present the purchase UI: \(message)"
        case .handoffRejected:
            return "The checkout link was rejected. Please try again."
        case .network(let message):
            return "Network error: \(message)"
        }
    }
}

/// Why a checkout web view sheet went away — determines how a `pending`
/// verify result should be interpreted (see `CheckoutFeature`).
public enum DismissReason: Equatable, Sendable {
    /// The checkout page itself navigated to the app's return URL.
    case redirectIntercepted
    case doneTapped
    case cancelTapped
    /// Swipe-to-dismiss / any other system-driven dismissal.
    case systemDismiss
}

public enum PurchaseOutcome: Equatable, Sendable {
    case completed(sessionId: String, verifiedAt: Date)
    /// User dismissed — not an error.
    case cancelled
    /// Notice was rejected — not an error.
    case declined
    case pendingVerification(sessionId: String)
    case failed(ExternalPurchaseError)
}
