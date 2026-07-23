import Foundation

/// The most recently fetched ACQUISITION + SERVICES tokens, cached together
/// so a purchase attempt doesn't re-mint a fresh SERVICES token (and re-ask
/// for ACQUISITION) more often than its real expiry requires.
public struct TokenSnapshot: Equatable, Sendable {
    public var acquisition: ExternalPurchaseToken?
    public var services: ExternalPurchaseToken?
    public var fetchedAt: Date?

    public init(acquisition: ExternalPurchaseToken? = nil, services: ExternalPurchaseToken? = nil, fetchedAt: Date? = nil) {
        self.acquisition = acquisition
        self.services = services
        self.fetchedAt = fetchedAt
    }

    /// Stable, collision-free, and identical to the pair of purchase IDs the
    /// BFF receives in `/tokens` — no client-generated UUID needed.
    public var idempotencyKey: String {
        [acquisition, services]
            .compactMap { $0?.payload.externalPurchaseId.uuidString }
            .joined(separator: ":")
    }

    /// The earliest non-nil expiry among the tokens currently held — the
    /// snapshot as a whole is only as fresh as its soonest-expiring token.
    public var expiresAt: Date? {
        [acquisition?.expiresAt, services?.expiresAt]
            .compactMap { $0 }
            .min()
    }

    public func isExpired(asOf now: Date) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    public func expiresWithin(_ interval: TimeInterval, asOf now: Date) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= interval
    }
}
