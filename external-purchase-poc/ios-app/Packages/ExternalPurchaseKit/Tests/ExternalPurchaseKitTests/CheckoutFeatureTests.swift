import ComposableArchitecture
import Foundation
import Testing

@testable import ExternalPurchaseKit

@MainActor
struct CheckoutFeatureTests {
    private let product = PurchasableProduct(
        id: "com.example.premium.monthly", userId: "user-1",
        displayName: "Premium Placement", priceText: "€29.99"
    )
    private let checkoutURL = URL(string: "http://localhost:8000/checkout/session-1")!
    private let servicesToken = ExternalPurchaseToken(value: "svc-token-1")
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private var session: CheckoutSession {
        CheckoutSession(sessionId: "session-1", checkoutURL: checkoutURL, expiresAt: nil)
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
            $0.externalPurchaseClient.token = { [servicesToken] _ in servicesToken }
            $0.externalPurchaseClient.showNotice = { _ in .continue }
            $0.bffClient.createCheckoutSession = { [session] _, _, _, _ in session }
            $0.bffClient.verifySession = { _ in VerifyResult(status: .paid, verifiedAt: fixedDate) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.buttonTapped) {
            $0.phase = .checkingEligibility
        }
        await store.receive(.eligibilityResponse(true)) {
            $0.phase = .preparingSession
        }
        await store.receive(.sessionResponse(.success(session))) {
            $0.phase = .presentingNotice
            $0.session = session
        }
        await store.receive(.noticeResponse(.success(.continue))) {
            $0.phase = .presentingWebView
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
        let session = self.session
        let store = TestStore(initialState: CheckoutFeature.State(product: product)) {
            CheckoutFeature()
        } withDependencies: {
            configure(&$0)
            $0.date = .constant(fixedDate)
            $0.externalPurchaseClient.isEligible = { true }
            $0.externalPurchaseClient.token = { [servicesToken] _ in servicesToken }
            $0.externalPurchaseClient.showNotice = { _ in .cancel }
            $0.bffClient.createCheckoutSession = { [session] _, _, _, _ in session }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.buttonTapped) { $0.phase = .checkingEligibility }
        await store.receive(.eligibilityResponse(true)) { $0.phase = .preparingSession }
        await store.receive(.sessionResponse(.success(session))) {
            $0.phase = .presentingNotice
            $0.session = session
        }
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
            $0.externalPurchaseClient.token = { [servicesToken] _ in servicesToken }
            $0.externalPurchaseClient.showNotice = { _ in .continue }
            $0.bffClient.createCheckoutSession = { [session] _, _, _, _ in session }
            // The server never saw anything happen — session is still pending.
            $0.bffClient.verifySession = { _ in VerifyResult(status: .pending, verifiedAt: nil) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.buttonTapped) { $0.phase = .checkingEligibility }
        await store.receive(.eligibilityResponse(true)) { $0.phase = .preparingSession }
        await store.receive(.sessionResponse(.success(session))) {
            $0.phase = .presentingNotice
            $0.session = session
        }
        await store.receive(.noticeResponse(.success(.continue))) {
            $0.phase = .presentingWebView
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
            $0.externalPurchaseClient.token = { [servicesToken] _ in servicesToken }
            $0.externalPurchaseClient.showNotice = { _ in .continue }
            $0.bffClient.createCheckoutSession = { [session] _, _, _, _ in session }
            // The mock server's "forge" button redirects claiming
            // status=paid but deliberately never touches session state —
            // verify must still report the truth: pending.
            $0.bffClient.verifySession = { _ in VerifyResult(status: .pending, verifiedAt: nil) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.buttonTapped) { $0.phase = .checkingEligibility }
        await store.receive(.eligibilityResponse(true)) { $0.phase = .preparingSession }
        await store.receive(.sessionResponse(.success(session))) {
            $0.phase = .presentingNotice
            $0.session = session
        }
        await store.receive(.noticeResponse(.success(.continue))) {
            $0.phase = .presentingWebView
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
            $0.externalPurchaseClient.token = { [servicesToken] _ in servicesToken }
            $0.externalPurchaseClient.showNotice = { _ in .continue }
            $0.bffClient.createCheckoutSession = { [session] _, _, _, _ in session }
            $0.bffClient.verifySession = { _ in VerifyResult(status: .pending, verifiedAt: nil) }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.buttonTapped) { $0.phase = .checkingEligibility }
        await store.receive(.eligibilityResponse(true)) { $0.phase = .preparingSession }
        await store.receive(.sessionResponse(.success(session))) {
            $0.phase = .presentingNotice
            $0.session = session
        }
        await store.receive(.noticeResponse(.success(.continue))) {
            $0.phase = .presentingWebView
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

    // MARK: - Token fetch failure

    @Test
    func tokenFetchFailure() async {
        let store = TestStore(initialState: CheckoutFeature.State(product: product)) {
            CheckoutFeature()
        } withDependencies: {
            configure(&$0)
            $0.externalPurchaseClient.isEligible = { true }
            $0.externalPurchaseClient.token = { _ in
                throw ExternalPurchaseError.tokenFetchFailed("Simulated failure")
            }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.buttonTapped) { $0.phase = .checkingEligibility }
        await store.receive(.eligibilityResponse(true)) { $0.phase = .preparingSession }
        await store.receive(.servicesTokenResponse(.failure(.tokenFetchFailed("Simulated failure")))) {
            $0.phase = .terminal(.failed(.tokenFetchFailed("Simulated failure")))
        }
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
