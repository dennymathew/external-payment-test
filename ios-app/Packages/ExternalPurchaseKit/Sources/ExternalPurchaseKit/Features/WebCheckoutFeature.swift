import ComposableArchitecture
import Foundation

/// Owns the state of the WKWebView checkout sheet. Deliberately does NOT
/// decide the purchase outcome — it only reports *why* the sheet went away.
/// `CheckoutFeature` treats every dismissal identically: verify against the
/// BFF before deciding anything.
@Reducer
public struct WebCheckoutFeature {
    @ObservableState
    public struct State: Equatable, Identifiable {
        public var id: String { sessionId }
        public let sessionId: String
        public let checkoutURL: URL
        public var isLoading: Bool = true
        public var loadFailed: Bool = false

        public init(sessionId: String, checkoutURL: URL) {
            self.sessionId = sessionId
            self.checkoutURL = checkoutURL
        }
    }

    public enum Action: Equatable {
        case navigationStarted
        case navigationFinished
        case navigationFailed
        case redirectIntercepted
        case doneButtonTapped
        case cancelButtonTapped
        /// The webview landed on the handoff-failure page (HTTP 401) —
        /// already redeemed, expired, wrong session, or rejected.
        case handoffRejected
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case dismissed(reason: DismissReason)
            case handoffRejected
        }
    }

    public init() {}

    public var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .navigationStarted:
                state.isLoading = true
                state.loadFailed = false
                return .none

            case .navigationFinished:
                state.isLoading = false
                return .none

            case .navigationFailed:
                state.isLoading = false
                state.loadFailed = true
                return .none

            case .redirectIntercepted:
                return .send(.delegate(.dismissed(reason: .redirectIntercepted)))

            case .doneButtonTapped:
                return .send(.delegate(.dismissed(reason: .doneTapped)))

            case .cancelButtonTapped:
                return .send(.delegate(.dismissed(reason: .cancelTapped)))

            case .handoffRejected:
                return .send(.delegate(.handoffRejected))

            case .delegate:
                return .none
            }
        }
    }
}
