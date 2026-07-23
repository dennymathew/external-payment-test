import ComposableArchitecture
import Foundation

/// Owns the external-purchase flow end to end as an explicit state machine:
///
///     idle → checkingEligibility → preparingTokens → presentingNotice →
///     creatingSession → presentingWebView → verifying → terminal
///
/// The notice (Apple's mandated disclosure) happens *before* session
/// creation, not after — the checkout session's `checkoutURL` embeds a
/// one-time auth handoff good for only 60s, so nothing user-paced (like
/// waiting on a disclosure tap) can sit between creating it and presenting
/// the webview.
///
/// The package does not own subscription/entitlement state — it only ever
/// reports a `PurchaseOutcome` via `.delegate(.outcome)`. The host app
/// decides what that unlocks.
@Reducer
public struct CheckoutFeature {
    @ObservableState
    public struct State: Equatable {
        public var phase: Phase
        public var product: PurchasableProduct
        public var session: CheckoutSession?
        @Presents public var webCheckout: WebCheckoutFeature.State?

        @Shared(.externalPurchaseTokenSnapshot) public var tokenSnapshot = TokenSnapshot()
        @Shared(.externalPurchaseDeviceIdentity) public var deviceIdentity = DeviceIdentity()
        @Shared(.externalPurchasePendingSessions) public var pendingSessions: [PendingSession] = []

        public init(product: PurchasableProduct) {
            self.product = product
            self.phase = .idle
        }

        public enum Phase: Equatable {
            case idle
            case checkingEligibility
            case preparingTokens
            case presentingNotice
            case creatingSession
            case presentingWebView
            case verifying(sessionId: String)
            case terminal(PurchaseOutcome)
        }

        public enum ButtonState: Equatable {
            case idle
            case working
            case presenting
            case verifying
        }

        public var buttonState: ButtonState {
            switch phase {
            case .idle, .terminal:
                return .idle
            case .checkingEligibility, .preparingTokens, .presentingNotice, .creatingSession:
                return .working
            case .presentingWebView:
                return .presenting
            case .verifying:
                return .verifying
            }
        }

        public var isBusy: Bool {
            buttonState != .idle
        }
    }

    public enum Action: Equatable {
        case buttonTapped
        case eligibilityResponse(Bool)
        case tokensPrepared(TokenSnapshotRefresh.Outcome)
        case tokensReported(Result<Bool, ExternalPurchaseError>)
        case noticeResponse(Result<NoticeResult, ExternalPurchaseError>)
        case sessionResponse(Result<CheckoutSession, ExternalPurchaseError>)
        case webCheckout(PresentationAction<WebCheckoutFeature.Action>)
        case verifyResponse(Result<VerifyResult, ExternalPurchaseError>, dismissReason: DismissReason)
        case reset
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case outcome(PurchaseOutcome)
        }
    }

    @Dependency(\.externalPurchaseClient) var externalPurchaseClient
    @Dependency(\.bffClient) var bffClient
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date.now) var now

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .buttonTapped:
                guard !state.isBusy else { return .none }
                state.phase = .checkingEligibility
                state.session = nil
                let externalPurchaseClient = externalPurchaseClient
                return .run { send in
                    await send(.eligibilityResponse(externalPurchaseClient.isEligible()))
                }

            case .eligibilityResponse(let isEligible):
                guard isEligible else {
                    return Self.finish(&state, outcome: .failed(.ineligible))
                }
                state.phase = .preparingTokens
                let externalPurchaseClient = externalPurchaseClient
                let snapshot = state.tokenSnapshot
                let now = now
                return .run { send in
                    await send(.tokensPrepared(
                        await TokenSnapshotRefresh.refresh(snapshot, client: externalPurchaseClient, now: now)
                    ))
                }

            case .tokensPrepared(let outcome):
                state.$tokenSnapshot.withLock { $0 = outcome.snapshot }
                guard let servicesToken = outcome.servicesHealth.token else {
                    return Self.finish(&state, outcome: .failed(Self.tokenFailureError(outcome.servicesHealth)))
                }
                state.phase = .presentingNotice
                let externalPurchaseClient = externalPurchaseClient
                let bffClient = bffClient
                let clock = clock
                let deviceId = state.deviceIdentity.deviceId
                let acquisitionToken = outcome.snapshot.acquisition
                let now = now
                return .merge(
                    .run { send in
                        await send(.noticeResponse(
                            await Result.catching { try await externalPurchaseClient.showNotice(.services) }
                        ))
                    },
                    Self.reportTokensEffect(
                        acquisitionToken: acquisitionToken, servicesToken: servicesToken,
                        deviceId: deviceId, fetchedAt: now, bffClient: bffClient, clock: clock
                    )
                )

            case .tokensReported:
                // Fire-and-forget from the UI's perspective; retries already
                // happened inside the effect itself.
                return .none

            case .noticeResponse(.failure(let error)):
                return Self.finish(&state, outcome: .failed(error))

            case .noticeResponse(.success(.cancel)):
                return Self.finish(&state, outcome: .declined)

            case .noticeResponse(.success(.continue)):
                state.phase = .creatingSession
                let bffClient = bffClient
                return Self.createSessionEffect(
                    product: state.product, snapshot: state.tokenSnapshot, bffClient: bffClient
                )

            case .sessionResponse(.failure(let error)):
                return Self.finish(&state, outcome: .failed(error))

            case .sessionResponse(.success(let session)):
                guard session.handoffExpiresAt > now else {
                    // The 60s handoff TTL elapsed before we could present
                    // it (e.g. the app was backgrounded) — a dead URL isn't
                    // recoverable, so get a fresh one instead of loading it.
                    let bffClient = bffClient
                    return Self.createSessionEffect(
                        product: state.product, snapshot: state.tokenSnapshot, bffClient: bffClient
                    )
                }
                state.session = session
                state.phase = .presentingWebView
                state.webCheckout = WebCheckoutFeature.State(sessionId: session.sessionId, checkoutURL: session.checkoutURL)
                state.$pendingSessions.withLock {
                    $0.append(PendingSession(id: session.sessionId, productId: state.product.id, createdAt: now))
                }
                return .none

            case .webCheckout(.presented(.delegate(.dismissed(let reason)))):
                let bffClient = bffClient
                return Self.verify(&state, dismissReason: reason, bffClient: bffClient)

            case .webCheckout(.presented(.delegate(.handoffRejected))):
                state.webCheckout = nil
                return Self.finish(&state, outcome: .failed(.handoffRejected))

            case .webCheckout(.dismiss):
                let bffClient = bffClient
                return Self.verify(&state, dismissReason: .systemDismiss, bffClient: bffClient)

            case .webCheckout:
                return .none

            case .verifyResponse(.failure(let error), _):
                return Self.finish(&state, outcome: .failed(error))

            case .verifyResponse(.success(let result), let reason):
                let outcome = Self.outcome(for: result, sessionId: state.session?.sessionId, dismissReason: reason, now: now)
                return Self.finish(&state, outcome: outcome)

            case .reset:
                state.phase = .idle
                state.session = nil
                state.webCheckout = nil
                return .none

            case .delegate:
                return .none
            }
        }
        .ifLet(\.$webCheckout, action: \.webCheckout) {
            WebCheckoutFeature()
        }
    }

    private static func tokenFailureError(_ health: TokenHealth) -> ExternalPurchaseError {
        switch health {
        case .malformed(let error):
            return .malformedToken(error)
        case .unavailable(.subsystemFailure(let message)):
            return .tokenFetchFailed(message)
        case .unavailable(.expectedForReturningCustomer), .notRequested, .available:
            // SERVICES is minted per-transaction — Apple never legitimately
            // omits it the way it can for ACQUISITION, so a nil here reads
            // as a subsystem problem rather than an expected absence.
            return .tokenFetchFailed("No purchase token was issued for this transaction.")
        }
    }

    private static func createSessionEffect(
        product: PurchasableProduct, snapshot: TokenSnapshot, bffClient: BFFClient
    ) -> Effect<Action> {
        .run { send in
            await send(.sessionResponse(
                await Result.catching {
                    try await bffClient.createCheckoutSession(
                        product.id, product.userId, snapshot.acquisition?.value, snapshot.services?.value
                    )
                }
            ))
        }
    }

    /// Best-effort, non-blocking: the purchase flow proceeds to session
    /// creation regardless of whether this succeeds. Retries with backoff
    /// because the report is a compliance obligation (due to the BFF within
    /// 15 days), not because the checkout itself depends on it.
    private static func reportTokensEffect(
        acquisitionToken: ExternalPurchaseToken?, servicesToken: ExternalPurchaseToken,
        deviceId: String, fetchedAt: Date, bffClient: BFFClient, clock: any Clock<Duration>
    ) -> Effect<Action> {
        .run { send in
            var attempt = 0
            while true {
                let result = await Result<Bool, ExternalPurchaseError>.catching {
                    try await bffClient.reportTokens(
                        acquisitionToken?.externalPurchaseId,
                        servicesToken.externalPurchaseId,
                        acquisitionToken == nil ? "period_elapsed_or_not_issued" : nil,
                        deviceId,
                        fetchedAt
                    )
                    return true
                }
                if case .success = result {
                    await send(.tokensReported(result))
                    return
                }
                attempt += 1
                guard attempt < 3 else {
                    await send(.tokensReported(result))
                    return
                }
                try? await clock.sleep(for: .seconds(pow(2.0, Double(attempt))))
            }
        }
    }

    /// Every dismissal path — redirect, Done, Cancel, or system
    /// swipe-to-dismiss — goes through here. The server's verify response is
    /// always the deciding factor; the redirect URL itself is never
    /// inspected for anything beyond "this is our return URL".
    private static func verify(_ state: inout State, dismissReason: DismissReason, bffClient: BFFClient) -> Effect<Action> {
        guard let session = state.session else {
            return finish(&state, outcome: .cancelled)
        }
        state.webCheckout = nil
        state.phase = .verifying(sessionId: session.sessionId)
        return .run { send in
            await send(
                .verifyResponse(
                    await Result.catching { try await bffClient.verifySession(session.sessionId) },
                    dismissReason: dismissReason
                )
            )
        }
    }

    private static func finish(_ state: inout State, outcome: PurchaseOutcome) -> Effect<Action> {
        state.phase = .terminal(outcome)
        state.webCheckout = nil
        if let session = state.session, !isStillPending(outcome) {
            state.$pendingSessions.withLock { $0.removeAll { $0.id == session.sessionId } }
        }
        return .send(.delegate(.outcome(outcome)))
    }

    private static func isStillPending(_ outcome: PurchaseOutcome) -> Bool {
        if case .pendingVerification = outcome { return true }
        return false
    }

    /// Maps the BFF's verify status to a `PurchaseOutcome`. A `pending`
    /// status is ambiguous on its own — it means different things depending
    /// on *how* the sheet went away:
    ///   - A redirect occurred (the checkout page itself navigated back) but
    ///     the server hasn't confirmed yet → still might resolve later
    ///     (e.g. slow/async settlement) → `.pendingVerification`. This is
    ///     also exactly what a forged-success redirect resolves to: the URL
    ///     claimed `status=paid`, but the server says `pending`, so the app
    ///     never reports `.completed` — the forged claim is rejected.
    ///   - No redirect ever happened (Done/Cancel tapped, or swiped away)
    ///     and the server never confirmed anything → the user simply walked
    ///     away → `.cancelled`, not an error.
    static func outcome(
        for result: VerifyResult, sessionId: String?, dismissReason: DismissReason, now: Date
    ) -> PurchaseOutcome {
        switch result.status {
        case .paid:
            return .completed(sessionId: sessionId ?? "", verifiedAt: result.verifiedAt ?? now)
        case .cancelled:
            return .cancelled
        case .expired:
            return .failed(.verificationFailed("Checkout session expired before payment was completed."))
        case .pending:
            if dismissReason == .redirectIntercepted, let sessionId {
                return .pendingVerification(sessionId: sessionId)
            }
            return .cancelled
        }
    }
}
