import ComposableArchitecture
import Foundation
import Testing

@testable import ExternalPurchaseKit

@MainActor
struct ExternalPurchaseLifecycleFeatureTests {
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    /// See the identical helper in `CheckoutFeatureTests` — Swift Testing
    /// runs `@Test`s concurrently by default, and `.inMemory`/`.fileStorage`
    /// otherwise inherit a shared ambient backing store across them.
    private func isolateSharedStorage(_ values: inout DependencyValues) {
        values.defaultFileStorage = .inMemory
        values.defaultInMemoryStorage = InMemoryStorage()
    }

    // MARK: - Cold-start reconciliation resolves a completed session

    @Test
    func coldStartReconciliationResolvesCompletedSession() async {
        let pending = PendingSession(id: "session-resolved", productId: "com.example.premium.monthly", createdAt: Date(timeIntervalSince1970: 0))
        let verifiedAt = Date(timeIntervalSince1970: 1_699_999_000)

        let store = TestStore(initialState: ExternalPurchaseLifecycleFeature.State()) {
            ExternalPurchaseLifecycleFeature()
        } withDependencies: {
            isolateSharedStorage(&$0)
            $0.date = .constant(fixedDate)
            $0.externalPurchaseClient.token = { _ in nil }
            $0.bffClient.verifySession = { _ in VerifyResult(status: .paid, verifiedAt: verifiedAt) }
        }
        // Simulate the app having force-quit mid-checkout on a previous run:
        // a session was persisted before the app stopped running.
        store.state.$pendingSessions.withLock { $0 = [pending] }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.launch)
        await store.receive(\.reconciliationResult)
        #expect(store.state.pendingSessions.isEmpty)
        await store.receive(\.delegate)
        await store.finish()
    }

    // MARK: - Cold-start reconciliation leaves an unresolved session in place

    @Test
    func coldStartReconciliationLeavesStillPendingSessionInPlace() async {
        let pending = PendingSession(id: "session-still-pending", productId: "com.example.premium.monthly", createdAt: Date(timeIntervalSince1970: 0))

        let store = TestStore(initialState: ExternalPurchaseLifecycleFeature.State()) {
            ExternalPurchaseLifecycleFeature()
        } withDependencies: {
            isolateSharedStorage(&$0)
            $0.date = .constant(fixedDate)
            $0.externalPurchaseClient.token = { _ in nil }
            $0.bffClient.reportTokens = { _, _, _, _ in }
            $0.bffClient.verifySession = { _ in VerifyResult(status: .pending, verifiedAt: nil) }
        }
        store.state.$pendingSessions.withLock { $0 = [pending] }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.launch)
        await store.receive(\.reconciliationFinished)

        // Still unresolved server-side — stays on disk for the *next*
        // launch to retry, and no delegate fires (nothing to react to yet).
        #expect(store.state.pendingSessions == [pending])
        await store.finish()
    }

    // MARK: - Acquisition token: nil maps to "expected for returning customer", not an error

    @Test
    func returningCustomerAcquisitionTokenIsNotAnError() async {
        let store = TestStore(initialState: ExternalPurchaseLifecycleFeature.State()) {
            ExternalPurchaseLifecycleFeature()
        } withDependencies: {
            isolateSharedStorage(&$0)
            $0.date = .constant(fixedDate)
            $0.externalPurchaseClient.token = { _ in nil }
            $0.bffClient.reportTokens = { _, _, _, _ in }
        }
        store.exhaustivity = .off(showSkippedAssertions: false)

        await store.send(.launch)
        await store.receive(\.acquisitionTokenResponse) {
            $0.$tokenState.withLock { $0 = .unavailable(reason: .expectedForReturningCustomer) }
        }
        await store.finish()
    }
}
