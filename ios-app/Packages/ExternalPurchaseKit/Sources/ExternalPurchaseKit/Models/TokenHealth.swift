import Foundation

/// Outcome of the most recent attempt to fetch and decode one token
/// (ACQUISITION or SERVICES).
///
/// A `nil` ACQUISITION token is the expected, common case for a returning
/// customer (Apple only vends one to attribute a *first* external purchase)
/// — that must map to `.unavailable(.expectedForReturningCustomer)`, never
/// to an error, and must never gate or block the paywall UI.
public enum TokenHealth: Equatable, Sendable {
    case notRequested
    case unavailable(reason: UnavailableReason)
    case available(token: ExternalPurchaseToken, fetchedAt: Date)
    /// StoreKit returned *something*, but it didn't decode. Distinct from
    /// `.unavailable(.subsystemFailure)`, which means StoreKit returned
    /// nothing — this means it returned something unreadable. Not
    /// retryable: the same bad string fails identically every time, so
    /// there's no backoff here, only loud, distinct telemetry.
    case malformed(TokenDecodingError)

    public enum UnavailableReason: Equatable, Sendable {
        /// The client legitimately returned `nil` — not an error.
        case expectedForReturningCustomer
        /// StoreKit's token subsystem itself failed (e.g. threw or timed
        /// out) — retryable, unlike `.malformed`.
        case subsystemFailure(String)
    }

    /// The decoded token, if one is currently available and healthy —
    /// convenience for call sites that just want to attach it when present.
    public var token: ExternalPurchaseToken? {
        if case .available(let token, _) = self {
            return token
        }
        return nil
    }
}
