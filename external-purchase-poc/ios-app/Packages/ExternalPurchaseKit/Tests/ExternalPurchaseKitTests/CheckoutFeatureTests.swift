import ComposableArchitecture
import Foundation
import Testing

@testable import ExternalPurchaseKit

private actor CallCounter {
    private(set) var count = 0
    @discardableResult
    func increment() -> Int {
        count += 1
        return count
    }
}

@MainActor
struct CheckoutFeatureTests {
    private let product = PurchasableProduct(
        id: "com.example.premium.monthly", userId: "user-1",
        displayName: "Premium Placement", priceText: "€29.99"
    )
    private let checkoutURL = URL(string: "http://localhost:8000/checkout/session-1")!
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private var session: CheckoutSession {
        CheckoutSession(
            sessionId: "session-1", checkoutURL: checkoutURL,
            handoffExpiresAt: fixedDate.addingTimeInterval(60), expiresAt: fixedDate.addingTimeInterval(900)
        )
    }

    /// `.inMemory`/`.fileStorage` shared state resolves through dependencies
    /// that, unless explicitly overridden, get inherited from an ambient
    /// context — under Swift Testing's parallel execution, that means
    /// concurrently-running `@Test`s can bleed shared state into each
    /// other. Giving every test its own fresh, private backing store avoids
    /// that entirely.
    ///
    /// Tests here also run non-exhaustively: because every mocked
    /// dependency resolves near-instantly, several actions in a chain can
    /// process back-to-back before the test gets a chance to assert on the
    /// first one, and `@Shared` fields (unlike plain state) are references —
    /// by the time an early `store.receive` assertion runs, a *later*
    /// action may have already mutated it further. `pendingSessions` is
    /// verified explicitly via `#expect` at the points that matter instead.
    private func configure(_ values: inout DependencyValues) {
        values.defaultFileStorage = .inMemory
        values.defaultInMemoryStorage = InMemoryStorage()
    }

    private func validTokenClient() -> @Sendable (TokenType) async throws -> String? {
        { type in ExternalPurchaseClient.mockTokenValue(type: type, createdAt: Date(timeIntervalSince1970: 1_700_000_000)) }
    }

    // MARK: - Happy path

    @Test
    func happyPath() async {
        let session = self.session
        let store = TestStore(initialState: CheckoutFeature.State(product: product)) {
            CheckoutFeature()
        } withDependencies: {
            configure(&$0)
            $0.date = .constant(fixedDate)
            $0.externalPurchaseClient.isEligible = { true }
            $0.externalPurchaseClient.token = validTokenClient()
            $0.externalPurchaseClient.showNotice = { _ in .continue }
            $0.bffClient.reportTokens = { _, _, _, _, _ in }
            $0.bffClient.createCheckoutSession = { [session] _, _, _, _ in session }
            $0.bffClient.verifySession = { _ in VerifyResult(status: .paid, verifiedAt: fixedDate) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.buttonTapped) {
            $0.phase = .checkingEligibility
        }
        await store.receive(.eligibilityResponse(true)) {
            $0.phase = .preparingTokens
        }
        await store.receive(\.tokensPrepared) {
            $0.phase = .presentingNotice
        }
        #expect(store.state.tokenSnapshot.services != nil)
        #expect(store.state.tokenSnapshot.acquisition == nil) // returning-customer default
        await store.receive(.noticeResponse(.success(.continue))) {
            $0.phase = .creatingSession
        }
        await store.receive(.sessionResponse(.success(session))) {
            $0.phase = .presentingWebView
            $0.session = session
            $0.webCheckout = WebCheckoutFeature.State(sessionId: session.sessionId, checkoutURL: session.checkoutURL)
        }
        #expect(store.state.pendingSessions == [PendingSession(id: session.sessionId, productId: product.id, createdAt: fixedDate)])

        await store.send(.webCheckout(.presented(.redirectIntercepted)))
        await store.receive(.webCheckout(.presented(.delegate(.dismissed(reason: .redirectIntercepted))))) {
            $0.webCheckout = nil
            $0.phase = .verifying(sessionId: session.sessionId)
        }
        await store.receive(
            .verifyResponse(.success(VerifyResult(status: .paid, verifiedAt: fixedDate)), dismissReason: .redirectIntercepted)
        ) {
            $0.phase = .terminal(.completed(sessionId: session.sessionId, verifiedAt: fixedDate))
        }
        #expect(store.state.pendingSessions.isEmpty)
        await store.finish()
    }

    // MARK: - Notice declined

    @Test
    func noticeDeclined() async {
        let store = TestStore(initialState: CheckoutFeature.State(product: product)) {
            CheckoutFeature()
        } withDependencies: {
            configure(&$0)
            $0.date = .constant(fixedDate)
            $0.externalPurchaseClient.isEligible = { true }
            $0.externalPurchaseClient.token = validTokenClient()
            $0.externalPurchaseClient.showNotice = { _ in .cancel }
            $0.bffClient.reportTokens = { _, _, _, _, _ in }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.buttonTapped) { $0.phase = .checkingEligibility }
        await store.receive(.eligibilityResponse(true)) { $0.phase = .preparingTokens }
        await store.receive(\.tokensPrepared) { $0.phase = .presentingNotice }
        await store.receive(.noticeResponse(.success(.cancel))) {
            $0.phase = .terminal(.declined)
        }
        #expect(store.state.pendingSessions.isEmpty)
        await store.finish()
    }

    // MARK: - User cancels web view (no redirect ever happened)

    @Test
    func userCancelsWebView() async {
        let session = self.session
        let store = TestStore(initialState: CheckoutFeature.State(product: product)) {
            CheckoutFeature()
        } withDependencies: {
            configure(&$0)
            $0.date = .constant(fixedDate)
            $0.externalPurchaseClient.isEligible = { true }
            $0.externalPurchaseClient.token = validTokenClient()
            $0.externalPurchaseClient.showNotice = { _ in .continue }
            $0.bffClient.reportTokens = { _, _, _, _, _ in }
            $0.bffClient.createCheckoutSession = { [session] _, _, _, _ in session }
            // The server never saw anything happen — session is still pending.
            $0.bffClient.verifySession = { _ in VerifyResult(status: .pending, verifiedAt: nil) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.buttonTapped) { $0.phase = .checkingEligibility }
        await store.receive(.eligibilityResponse(true)) { $0.phase = .preparingTokens }
        await store.receive(\.tokensPrepared) { $0.phase = .presentingNotice }
        await store.receive(.noticeResponse(.success(.continue))) { $0.phase = .creatingSession }
        await store.receive(.sessionResponse(.success(session))) {
            $0.phase = .presentingWebView
            $0.session = session
            $0.webCheckout = WebCheckoutFeature.State(sessionId: session.sessionId, checkoutURL: session.checkoutURL)
        }

        await store.send(.webCheckout(.presented(.cancelButtonTapped)))
        await store.receive(.webCheckout(.presented(.delegate(.dismissed(reason: .cancelTapped))))) {
            $0.webCheckout = nil
            $0.phase = .verifying(sessionId: session.sessionId)
        }
        await store.receive(
            .verifyResponse(.success(VerifyResult(status: .pending, verifiedAt: nil)), dismissReason: .cancelTapped)
        ) {
            // No redirect ever happened, so a `pending` verify reads as the
            // user having simply walked away — not an error.
            $0.phase = .terminal(.cancelled)
        }
        #expect(store.state.pendingSessions.isEmpty)
        await store.finish()
    }

    // MARK: - Forged-success redirect is rejected

    @Test
    func forgedSuccessRedirectIsRejected() async {
        let session = self.session
        let store = TestStore(initialState: CheckoutFeature.State(product: product)) {
            CheckoutFeature()
        } withDependencies: {
            configure(&$0)
            $0.date = .constant(fixedDate)
            $0.externalPurchaseClient.isEligible = { true }
            $0.externalPurchaseClient.token = validTokenClient()
            $0.externalPurchaseClient.showNotice = { _ in .continue }
            $0.bffClient.reportTokens = { _, _, _, _, _ in }
            $0.bffClient.createCheckoutSession = { [session] _, _, _, _ in session }
            // The mock server's "forge" button redirects claiming
            // status=paid but deliberately never touches session state —
            // verify must still report the truth: pending.
            $0.bffClient.verifySession = { _ in VerifyResult(status: .pending, verifiedAt: nil) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.buttonTapped) { $0.phase = .checkingEligibility }
        await store.receive(.eligibilityResponse(true)) { $0.phase = .preparingTokens }
        await store.receive(\.tokensPrepared) { $0.phase = .presentingNotice }
        await store.receive(.noticeResponse(.success(.continue))) { $0.phase = .creatingSession }
        await store.receive(.sessionResponse(.success(session))) {
            $0.phase = .presentingWebView
            $0.session = session
            $0.webCheckout = WebCheckoutFeature.State(sessionId: session.sessionId, checkoutURL: session.checkoutURL)
        }

        // The WKWebView delegate only ever reports "a redirect to our
        // return URL happened" — it never inspects or forwards the forged
        // `status=paid` query string, so this looks identical to any other
        // redirect from the app's point of view.
        await store.send(.webCheckout(.presented(.redirectIntercepted)))
        await store.receive(.webCheckout(.presented(.delegate(.dismissed(reason: .redirectIntercepted))))) {
            $0.webCheckout = nil
            $0.phase = .verifying(sessionId: session.sessionId)
        }
        await store.receive(
            .verifyResponse(.success(VerifyResult(status: .pending, verifiedAt: nil)), dismissReason: .redirectIntercepted)
        ) {
            $0.phase = .terminal(.pendingVerification(sessionId: session.sessionId))
        }

        if case .terminal(let outcome) = store.state.phase {
            #expect(outcome != .completed(sessionId: session.sessionId, verifiedAt: fixedDate))
        } else {
            Issue.record("expected a terminal phase")
        }

        // Still unresolved server-side, so it stays on-disk for the next
        // launch's cold-start reconciliation to catch.
        #expect(store.state.pendingSessions == [PendingSession(id: session.sessionId, productId: product.id, createdAt: fixedDate)])
        await store.finish()
    }

    // MARK: - Pending verification (e.g. slow/async settlement)

    @Test
    func pendingVerification() async {
        let session = self.session
        let store = TestStore(initialState: CheckoutFeature.State(product: product)) {
            CheckoutFeature()
        } withDependencies: {
            configure(&$0)
            $0.date = .constant(fixedDate)
            $0.externalPurchaseClient.isEligible = { true }
            $0.externalPurchaseClient.token = validTokenClient()
            $0.externalPurchaseClient.showNotice = { _ in .continue }
            $0.bffClient.reportTokens = { _, _, _, _, _ in }
            $0.bffClient.createCheckoutSession = { [session] _, _, _, _ in session }
            $0.bffClient.verifySession = { _ in VerifyResult(status: .pending, verifiedAt: nil) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.buttonTapped) { $0.phase = .checkingEligibility }
        await store.receive(.eligibilityResponse(true)) { $0.phase = .preparingTokens }
        await store.receive(\.tokensPrepared) { $0.phase = .presentingNotice }
        await store.receive(.noticeResponse(.success(.continue))) { $0.phase = .creatingSession }
        await store.receive(.sessionResponse(.success(session))) {
            $0.phase = .presentingWebView
            $0.session = session
            $0.webCheckout = WebCheckoutFeature.State(sessionId: session.sessionId, checkoutURL: session.checkoutURL)
        }

        await store.send(.webCheckout(.presented(.redirectIntercepted)))
        await store.receive(.webCheckout(.presented(.delegate(.dismissed(reason: .redirectIntercepted))))) {
            $0.webCheckout = nil
            $0.phase = .verifying(sessionId: session.sessionId)
        }
        await store.receive(
            .verifyResponse(.success(VerifyResult(status: .pending, verifiedAt: nil)), dismissReason: .redirectIntercepted)
        ) {
            $0.phase = .terminal(.pendingVerification(sessionId: session.sessionId))
        }
        #expect(store.state.pendingSessions == [PendingSession(id: session.sessionId, productId: product.id, createdAt: fixedDate)])
        await store.finish()
    }

    // MARK: - SERVICES token subsystem failure

    @Test
    func servicesTokenSubsystemFailure() async {
        let store = TestStore(initialState: CheckoutFeature.State(product: product)) {
            CheckoutFeature()
        } withDependencies: {
            configure(&$0)
            $0.date = .constant(fixedDate)
            $0.externalPurchaseClient.isEligible = { true }
            $0.externalPurchaseClient.token = { _ in
                throw ExternalPurchaseError.tokenFetchFailed("Simulated failure")
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.buttonTapped) { $0.phase = .checkingEligibility }
        await store.receive(.eligibilityResponse(true)) { $0.phase = .preparingTokens }
        await store.receive(\.tokensPrepared) { state in
            guard case .terminal(.failed(.tokenFetchFailed)) = state.phase else {
                Issue.record("expected a tokenFetchFailed outcome, got \(state.phase)")
                return
            }
        }
        #expect(store.state.pendingSessions.isEmpty)
        await store.finish()
    }

    // MARK: - Malformed SERVICES token: not retried, never enqueued

    @Test
    func malformedServicesTokenIsNotRetriedAndNeverEnqueued() async {
        let store = TestStore(initialState: CheckoutFeature.State(product: product)) {
            CheckoutFeature()
        } withDependencies: {
            configure(&$0)
            $0.date = .constant(fixedDate)
            $0.externalPurchaseClient.isEligible = { true }
            $0.externalPurchaseClient.token = { _ in Data("{not valid json".utf8).base64EncodedString() }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.buttonTapped) { $0.phase = .checkingEligibility }
        await store.receive(.eligibilityResponse(true)) { $0.phase = .preparingTokens }
        await store.receive(\.tokensPrepared) { state in
            guard case .terminal(.failed(.malformedToken)) = state.phase else {
                Issue.record("expected a malformedToken outcome, got \(state.phase)")
                return
            }
        }
        // No session was ever created, so nothing was queued for reconciliation.
        #expect(store.state.pendingSessions.isEmpty)
        await store.finish()
    }

    // MARK: - Expired handoff: session is discarded and re-created

    @Test
    func expiredHandoffTriggersSessionRecreation() async {
        let staleSession = CheckoutSession(
            sessionId: "session-stale", checkoutURL: checkoutURL,
            handoffExpiresAt: fixedDate.addingTimeInterval(-1), expiresAt: fixedDate.addingTimeInterval(900)
        )
        let freshSession = CheckoutSession(
            sessionId: "session-fresh", checkoutURL: checkoutURL,
            handoffExpiresAt: fixedDate.addingTimeInterval(60), expiresAt: fixedDate.addingTimeInterval(900)
        )
        let counter = CallCounter()
        let store = TestStore(initialState: CheckoutFeature.State(product: product)) {
            CheckoutFeature()
        } withDependencies: {
            configure(&$0)
            $0.date = .constant(fixedDate)
            $0.externalPurchaseClient.isEligible = { true }
            $0.externalPurchaseClient.token = validTokenClient()
            $0.externalPurchaseClient.showNotice = { _ in .continue }
            $0.bffClient.reportTokens = { _, _, _, _, _ in }
            $0.bffClient.createCheckoutSession = { [staleSession, freshSession] _, _, _, _ in
                await counter.increment() == 1 ? staleSession : freshSession
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.buttonTapped) { $0.phase = .checkingEligibility }
        await store.receive(.eligibilityResponse(true)) { $0.phase = .preparingTokens }
        await store.receive(\.tokensPrepared) { $0.phase = .presentingNotice }
        await store.receive(.noticeResponse(.success(.continue))) { $0.phase = .creatingSession }
        // The first session's handoff is already expired by `now` — it's
        // discarded (no state mutation) and a fresh one is requested instead
        // of ever being loaded.
        await store.receive(.sessionResponse(.success(staleSession)))
        await store.receive(.sessionResponse(.success(freshSession))) {
            $0.phase = .presentingWebView
            $0.session = freshSession
            $0.webCheckout = WebCheckoutFeature.State(sessionId: freshSession.sessionId, checkoutURL: freshSession.checkoutURL)
        }
        let callCount = await counter.count
        #expect(callCount == 2)
        await store.finish()
    }

    // MARK: - Handoff rejected by the server (401 page)

    @Test
    func handoffRejectedTerminatesFlow() async {
        let session = self.session
        let store = TestStore(initialState: CheckoutFeature.State(product: product)) {
            CheckoutFeature()
        } withDependencies: {
            configure(&$0)
            $0.date = .constant(fixedDate)
            $0.externalPurchaseClient.isEligible = { true }
            $0.externalPurchaseClient.token = validTokenClient()
            $0.externalPurchaseClient.showNotice = { _ in .continue }
            $0.bffClient.reportTokens = { _, _, _, _, _ in }
            $0.bffClient.createCheckoutSession = { [session] _, _, _, _ in session }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.buttonTapped) { $0.phase = .checkingEligibility }
        await store.receive(.eligibilityResponse(true)) { $0.phase = .preparingTokens }
        await store.receive(\.tokensPrepared) { $0.phase = .presentingNotice }
        await store.receive(.noticeResponse(.success(.continue))) { $0.phase = .creatingSession }
        await store.receive(.sessionResponse(.success(session))) {
            $0.phase = .presentingWebView
            $0.session = session
            $0.webCheckout = WebCheckoutFeature.State(sessionId: session.sessionId, checkoutURL: session.checkoutURL)
        }

        await store.send(.webCheckout(.presented(.handoffRejected)))
        await store.receive(.webCheckout(.presented(.delegate(.handoffRejected)))) {
            $0.webCheckout = nil
            $0.phase = .terminal(.failed(.handoffRejected))
        }
        #expect(store.state.pendingSessions.isEmpty)
        await store.finish()
    }

    // MARK: - Ineligible user

    @Test
    func ineligibleUser() async {
        let store = TestStore(initialState: CheckoutFeature.State(product: product)) {
            CheckoutFeature()
        } withDependencies: {
            configure(&$0)
            $0.externalPurchaseClient.isEligible = { false }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.buttonTapped) { $0.phase = .checkingEligibility }
        await store.receive(.eligibilityResponse(false)) {
            $0.phase = .terminal(.failed(.ineligible))
        }
        await store.finish()
    }
}
