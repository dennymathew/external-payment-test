import ComposableArchitecture
import ExternalPurchaseKit
import Foundation

@Reducer
struct PaywallFeature {
    @ObservableState
    struct State: Equatable {
        var checkout: CheckoutFeature.State
        var isUnlocked = false
        var banner: Banner?

        struct Banner: Equatable {
            enum Style: Equatable { case success, info, error }
            let style: Style
            let message: String
        }
    }

    enum Action {
        case checkout(CheckoutFeature.Action)
        case bannerDismissed
    }

    var body: some Reducer<State, Action> {
        Scope(\.checkout, action: \.checkout) {
            CheckoutFeature()
        }
        Reduce { state, action in
            switch action {
            case .checkout(.delegate(.outcome(let outcome))):
                switch outcome {
                case .completed:
                    state.isUnlocked = true
                    state.banner = .init(style: .success, message: "Purchase complete — content unlocked.")
                case .cancelled:
                    state.banner = nil
                case .declined:
                    state.banner = nil
                case .pendingVerification:
                    state.banner = .init(style: .info, message: "We're confirming your payment — check back soon.")
                case .failed(let error):
                    state.banner = .init(style: .error, message: error.localizedDescription)
                }
                return .none

            case .checkout:
                return .none

            case .bannerDismissed:
                state.banner = nil
                return .none
            }
        }
    }
}
