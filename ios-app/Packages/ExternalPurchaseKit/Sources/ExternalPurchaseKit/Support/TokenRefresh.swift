import Foundation

extension Result where Failure == ExternalPurchaseError {
    /// `Result.init(catching:)` only supports synchronous throwing
    /// closures — this fills the gap for `async throws`.
    static func catching(_ body: () async throws -> Success) async -> Result<Success, ExternalPurchaseError> {
        do {
            return .success(try await body())
        } catch let error as ExternalPurchaseError {
            return .failure(error)
        } catch {
            return .failure(.network(String(describing: error)))
        }
    }
}

/// Fetches, decodes, and validates one token type — the single place a raw
/// StoreKit string gets turned into a decoded `ExternalPurchaseToken` (or a
/// concrete failure reason). Every reducer that needs a token goes through
/// this, so none of them ever see an undecoded string or a raw thrown error.
enum TokenFetch {
    static func attempt(_ type: TokenType, client: ExternalPurchaseClient, now: Date) async -> TokenHealth {
        do {
            guard let raw = try await client.token(type) else {
                return .unavailable(reason: .expectedForReturningCustomer)
            }
            do {
                let token = try ExternalPurchaseToken(rawValue: raw, expecting: type)
                return .available(token: token, fetchedAt: now)
            } catch let error as TokenDecodingError {
                return .malformed(error)
            } catch {
                return .malformed(.malformedPayload(description: String(describing: error)))
            }
        } catch let error as ExternalPurchaseError {
            return .unavailable(reason: .subsystemFailure(error.localizedDescription))
        } catch {
            return .unavailable(reason: .subsystemFailure(String(describing: error)))
        }
    }
}

/// Refreshes a `TokenSnapshot` for an imminent checkout — reuses whatever's
/// cached unless it's already expired or within 5 minutes of expiring, since
/// a SERVICES token is normally minted fresh per purchase attempt anyway and
/// an ACQUISITION token fetched at launch is usually still good.
public enum TokenSnapshotRefresh {
    static let staleWithin: TimeInterval = 5 * 60

    public struct Outcome: Equatable, Sendable {
        public var snapshot: TokenSnapshot
        public var acquisitionHealth: TokenHealth
        public var servicesHealth: TokenHealth
    }

    static func refresh(_ snapshot: TokenSnapshot, client: ExternalPurchaseClient, now: Date) async -> Outcome {
        let needsRefresh =
            snapshot.fetchedAt == nil
            || snapshot.isExpired(asOf: now)
            || snapshot.expiresWithin(staleWithin, asOf: now)
        guard needsRefresh else {
            return Outcome(
                snapshot: snapshot,
                acquisitionHealth: health(for: snapshot.acquisition, fetchedAt: snapshot.fetchedAt ?? now),
                servicesHealth: health(for: snapshot.services, fetchedAt: snapshot.fetchedAt ?? now)
            )
        }
        async let acquisition = TokenFetch.attempt(.acquisition, client: client, now: now)
        async let services = TokenFetch.attempt(.services, client: client, now: now)
        let acquisitionHealth = await acquisition
        let servicesHealth = await services
        let newSnapshot = TokenSnapshot(
            // A failed refetch keeps whatever ACQUISITION token was already
            // known-good rather than discarding it — SERVICES has no such
            // fallback since it's minted per-transaction and a stale one
            // isn't meaningfully reusable.
            acquisition: acquisitionHealth.token ?? snapshot.acquisition,
            services: servicesHealth.token,
            fetchedAt: now
        )
        return Outcome(snapshot: newSnapshot, acquisitionHealth: acquisitionHealth, servicesHealth: servicesHealth)
    }

    private static func health(for token: ExternalPurchaseToken?, fetchedAt: Date) -> TokenHealth {
        guard let token else { return .unavailable(reason: .expectedForReturningCustomer) }
        return .available(token: token, fetchedAt: fetchedAt)
    }
}
