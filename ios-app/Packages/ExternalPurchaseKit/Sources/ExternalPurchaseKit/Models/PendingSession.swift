import Foundation

/// A checkout session the user actually engaged with (saw the web checkout)
/// whose outcome wasn't confirmed before the app stopped running — force-quit
/// mid-checkout, crash, or a `pendingVerification` outcome still in flight on
/// the server. Persisted so a cold launch can reconcile it against the BFF
/// before any new purchase is allowed to start.
public struct PendingSession: Equatable, Sendable, Codable, Identifiable {
    public let id: String
    public let productId: String
    public let createdAt: Date

    public init(id: String, productId: String, createdAt: Date) {
        self.id = id
        self.productId = productId
        self.createdAt = createdAt
    }
}
