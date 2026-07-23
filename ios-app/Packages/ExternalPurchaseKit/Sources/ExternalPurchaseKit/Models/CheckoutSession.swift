import Foundation

/// Response from `POST /checkout/session`. `checkoutURL` already has a
/// one-time auth handoff token embedded in it — the client just loads it,
/// it's never constructed or modified client-side.
public struct CheckoutSession: Equatable, Sendable, Codable {
    public let sessionId: String
    public let checkoutURL: URL
    /// The handoff embedded in `checkoutURL` is only redeemable for 60s.
    /// Present the webview immediately after receiving the session; if that
    /// didn't happen before this passes, discard and re-create rather than
    /// loading a dead URL.
    public let handoffExpiresAt: Date
    public let expiresAt: Date

    public init(sessionId: String, checkoutURL: URL, handoffExpiresAt: Date, expiresAt: Date) {
        self.sessionId = sessionId
        self.checkoutURL = checkoutURL
        self.handoffExpiresAt = handoffExpiresAt
        self.expiresAt = expiresAt
    }

    /// Never log `checkoutURL` in full — this redacts the `handoff` query
    /// item while keeping the rest of the URL legible for debugging.
    public var redactedCheckoutURL: String {
        guard var components = URLComponents(url: checkoutURL, resolvingAgainstBaseURL: false) else {
            return "<unparseable>"
        }
        components.queryItems = components.queryItems?.map { item in
            guard item.name == "handoff" else { return item }
            return URLQueryItem(name: item.name, value: "REDACTED")
        }
        return components.string ?? "<unparseable>"
    }
}

/// Mirrors the mock server's `SessionStatus` literal exactly — this is the
/// one source of truth the app is allowed to trust for whether money moved.
public enum VerifyStatus: String, Equatable, Sendable, Codable {
    case pending
    case paid
    case cancelled
    case expired
}

public struct VerifyResult: Equatable, Sendable {
    public let status: VerifyStatus
    public let verifiedAt: Date?

    public init(status: VerifyStatus, verifiedAt: Date?) {
        self.status = status
        self.verifiedAt = verifiedAt
    }
}
