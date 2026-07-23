import ComposableArchitecture
import Foundation

/// Launch-time responsibilities that don't belong inside `CheckoutFeature`
/// because they aren't tied to any one purchase attempt:
///
///   1. Fetch and decode the ACQUISITION token, non-blocking, never gating
///      UI, and cache it into the shared `TokenSnapshot` so a purchase
///      attempt doesn't have to ask again if it's still fresh. Reporting it
///      to the BFF happens later — the `/tokens` endpoint requires a
///      SERVICES purchase ID in the same call, which only exists once a
///      purchase is actually underway, so `CheckoutFeature` owns that report.
///   2. Reconcile any sessions left `pending` from a previous run (force
///      quit mid-checkout, crash, or a `pendingVerification` outcome still
///      unresolved) against the BFF *before* purchase UI is shown — unlike
///      the token fetch, this one *does* gate the paywall, so a stale
///      session can't be double-acted-on.
@Reducer
public struct ExternalPurchaseLifecycleFeature {
    @ObservableState
    public struct State: Equatable {
        @Shared(.externalPurchaseAcquisitionHealth) public var acquisitionHealth = TokenHealth.notRequested
        @Shared(.externalPurchaseTokenSnapshot) public var tokenSnapshot = TokenSnapshot()
        @Shared(.externalPurchasePendingSessions) public var pendingSessions: [PendingSession] = []
        public var isReconciling: Bool = false

        public init() {}
    }

    public enum Action {
        case launch
        case acquisitionTokenHealth(TokenHealth)
        case reconciliationResult(sessionId: String, Result<VerifyResult, ExternalPurchaseError>)
        case reconciliationFinished
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case sessionResolved(PendingSession, PurchaseOutcome)
        }
    }

    @Dependency(\.externalPurchaseClient) var externalPurchaseClient
    @Dependency(\.bffClient) var bffClient
    @Dependency(\.date.now) var now

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .launch:
                state.isReconciling = !state.pendingSessions.isEmpty
                let externalPurchaseClient = externalPurchaseClient
                let bffClient = bffClient
                let sessions = state.pendingSessions
                let now = now
                return .merge(
                    .run { send in
                        await send(.acquisitionTokenHealth(
                            await TokenFetch.attempt(.acquisition, client: externalPurchaseClient, now: now)
                        ))
                    },
                    Self.reconcileEffect(sessions: sessions, bffClient: bffClient)
                )

            case .acquisitionTokenHealth(let health):
                state.$acquisitionHealth.withLock { $0 = health }
                // A successful fetch seeds the shared snapshot so a purchase
                // attempt started soon after launch can skip re-asking for
                // it. `fetchedAt` is deliberately left untouched here — only
                // a refresh that has confirmed *both* tokens sets it, so the
                // first purchase attempt still fetches SERVICES.
                if let token = health.token {
                    state.$tokenSnapshot.withLock { $0.acquisition = token }
                }
                return .none

            case .reconciliationResult(let sessionId, let result):
                guard let session = state.pendingSessions.first(where: { $0.id == sessionId }) else {
                    return .none
                }
                switch result {
                case .success(let verify) where verify.status != .pending:
                    let outcome = Self.outcome(for: verify, sessionId: sessionId, now: now)
                    state.$pendingSessions.withLock { $0.removeAll { $0.id == sessionId } }
                    return .send(.delegate(.sessionResolved(session, outcome)))
                default:
                    // Still pending, or the check itself failed — leave it
                    // in the list; the next launch will retry.
                    return .none
                }

            case .reconciliationFinished:
                state.isReconciling = false
                return .none

            case .delegate:
                return .none
            }
        }
    }

    private static func reconcileEffect(sessions: [PendingSession], bffClient: BFFClient) -> Effect<Action> {
        guard !sessions.isEmpty else { return .send(.reconciliationFinished) }
        return .run { send in
            await withTaskGroup(of: Void.self) { group in
                for session in sessions {
                    group.addTask {
                        await send(.reconciliationResult(
                            sessionId: session.id,
                            await Result.catching { try await bffClient.verifySession(session.id) }
                        ))
                    }
                }
            }
            await send(.reconciliationFinished)
        }
    }

    private static func outcome(for result: VerifyResult, sessionId: String, now: Date) -> PurchaseOutcome {
        switch result.status {
        case .paid:
            return .completed(sessionId: sessionId, verifiedAt: result.verifiedAt ?? now)
        case .cancelled:
            return .cancelled
        case .expired:
            return .failed(.verificationFailed("Checkout session expired before payment was completed."))
        case .pending:
            return .pendingVerification(sessionId: sessionId)
        }
    }
}
