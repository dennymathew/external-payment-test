import Foundation

/// A product the host app wants to sell via the external purchase link.
/// Intentionally minimal — the package doesn't know or care about
/// entitlements, it only needs enough to start a checkout session.
public struct PurchasableProduct: Equatable, Sendable, Identifiable {
    public let id: String
    public let userId: String
    public let displayName: String
    public let priceText: String

    public init(id: String, userId: String, displayName: String, priceText: String) {
        self.id = id
        self.userId = userId
        self.displayName = displayName
        self.priceText = priceText
    }
}
