import ComposableArchitecture
import ExternalPurchaseKit
import Foundation

private let demoProduct = PurchasableProduct(
    id: "com.example.premium.monthly",
    userId: "demo-user-1",
    displayName: "Premium Placement",
    priceText: "€29.99 / month"
)

@Reducer
struct AppFeature {
    @ObservableState
    struct State: Equatable {
        var lifecycle = ExternalPurchaseLifecycleFeature.State()
        var paywall = PaywallFeature.State(checkout: CheckoutFeature.State(product: demoProduct))
        var debugMenu = DebugMenuFeature.State()
        var eventLog: [EventLogEntry] = []
        var showDebugMenu = false
    }

    enum Action {
        case task
        case lifecycle(ExternalPurchaseLifecycleFeature.Action)
        case paywall(PaywallFeature.Action)
        case debugMenu(DebugMenuFeature.Action)
        case debugMenuButtonTapped
        case debugMenuDismissed
    }

    @Dependency(\.date.now) var now

    var body: some Reducer<State, Action> {
        Scope(\.lifecycle, action: \.lifecycle) {
            ExternalPurchaseLifecycleFeature()
        }
        Scope(\.paywall, action: \.paywall) {
            PaywallFeature()
        }
        Scope(\.debugMenu, action: \.debugMenu) {
            DebugMenuFeature()
        }
        Reduce { state, action in
            switch action {
            case .task:
                state.eventLog.append(EventLogEntry(timestamp: now, message: "App launched — fetching tokens & reconciling pending sessions."))
                return .send(.lifecycle(.launch))

            case .lifecycle(.delegate(.sessionResolved(let session, let outcome))):
                state.eventLog.append(EventLogEntry(
                    timestamp: now,
                    message: "Reconciled pending session \(session.id): \(outcome)"
                ))
                if case .completed = outcome {
                    state.paywall.isUnlocked = true
                }
                return .none

            case .lifecycle(let action):
                if let message = Self.describe(lifecycle: action) {
                    state.eventLog.append(EventLogEntry(timestamp: now, message: message))
                }
                return .none

            case .paywall(.checkout(let action)):
                if let message = Self.describe(checkout: action) {
                    state.eventLog.append(EventLogEntry(timestamp: now, message: message))
                }
                return .none

            case .paywall:
                return .none

            case .debugMenu:
                return .none

            case .debugMenuButtonTapped:
                state.showDebugMenu = true
                return .none

            case .debugMenuDismissed:
                state.showDebugMenu = false
                return .none
            }
        }
    }

    private static func describe(lifecycle action: ExternalPurchaseLifecycleFeature.Action) -> String? {
        switch action {
        case .launch:
            return "Lifecycle: launch"
        case .acquisitionTokenHealth(.available):
            return "Lifecycle: acquisition token available"
        case .acquisitionTokenHealth(.unavailable(.expectedForReturningCustomer)):
            return "Lifecycle: acquisition token unavailable (returning customer)"
        case .acquisitionTokenHealth(.unavailable(.subsystemFailure(let message))):
            return "Lifecycle: acquisition token fetch failed — \(message)"
        case .acquisitionTokenHealth(.malformed(let error)):
            return "Lifecycle: acquisition token malformed — \(error)"
        case .acquisitionTokenHealth(.notRequested):
            return nil
        case .reconciliationResult(let sessionId, let result):
            return "Lifecycle: reconcile \(sessionId) → \(result)"
        case .reconciliationFinished:
            return "Lifecycle: reconciliation finished"
        case .delegate:
            return nil
        }
    }

    private static func describe(checkout action: CheckoutFeature.Action) -> String? {
        switch action {
        case .buttonTapped:
            return "Checkout: buy tapped"
        case .eligibilityResponse(let eligible):
            return "Checkout: eligibility → \(eligible)"
        case .tokensPrepared(let outcome):
            return "Checkout: tokens prepared — acquisition: \(outcome.acquisitionHealth), services: \(outcome.servicesHealth)"
        case .tokensReported(.success):
            return "Checkout: tokens reported to BFF"
        case .tokensReported(.failure(let error)):
            return "Checkout: token report failed — \(error.localizedDescription)"
        case .noticeResponse(.success(let result)):
            return "Checkout: notice → \(result)"
        case .noticeResponse(.failure(let error)):
            return "Checkout: notice failed — \(error.localizedDescription)"
        case .sessionResponse(.success(let session)):
            return "Checkout: session created (\(session.sessionId))"
        case .sessionResponse(.failure(let error)):
            return "Checkout: session creation failed — \(error.localizedDescription)"
        case .webCheckout(.presented(.redirectIntercepted)):
            return "Checkout: web view redirect intercepted"
        case .webCheckout(.presented(.doneButtonTapped)):
            return "Checkout: Done tapped"
        case .webCheckout(.presented(.cancelButtonTapped)):
            return "Checkout: Cancel tapped"
        case .webCheckout(.presented(.handoffRejected)):
            return "Checkout: handoff rejected by server"
        case .webCheckout(.dismiss):
            return "Checkout: web view dismissed (swipe)"
        case .webCheckout:
            return nil
        case .verifyResponse(let result, let reason):
            return "Checkout: verify (\(reason)) → \(result)"
        case .reset:
            return "Checkout: reset"
        case .delegate(.outcome(let outcome)):
            return "Checkout: outcome → \(outcome)"
        }
    }
}
