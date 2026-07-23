import ComposableArchitecture
import ExternalPurchaseKit
import Foundation

@Reducer
struct DebugMenuFeature {
    @ObservableState
    struct State: Equatable {
        @Shared(.mockExternalPurchaseSettings) var settings = MockExternalPurchaseSettings()
        @Shared(.externalPurchaseAcquisitionHealth) var acquisitionHealth = TokenHealth.notRequested
        @Shared(.externalPurchaseTokenSnapshot) var tokenSnapshot = TokenSnapshot()
        @Shared(.externalPurchasePendingSessions) var pendingSessions: [PendingSession] = []
        var isResetting = false
        var resetMessage: String?

        var mintTokenType: TokenType = .services
        var mintTokenVariant: DebugTokenVariant = .valid
        var isMinting = false
        var mintResult: MintResult?
        var mintErrorMessage: String?

        enum MintResult: Equatable {
            case token(ExternalPurchaseToken)
            case decodingFailed(TokenDecodingError)
        }

        static let handoffModes = ["normal", "already_redeemed", "expired", "wrong_session", "reject"]
        var handoffMode: String = "normal"
        var isSettingHandoffMode = false
        var handoffModeMessage: String?
    }

    enum Action {
        case eligibilityToggled(Bool)
        case acquisitionTokenToggled(Bool)
        case forceTokenFailureToggled(Bool)
        case mintTokenTypeChanged(TokenType)
        case mintTokenVariantChanged(DebugTokenVariant)
        case mintTokenTapped
        case mintTokenResponse(Result<String, ExternalPurchaseError>)
        case handoffModeChanged(String)
        case handoffModeResponse(Result<Void, ExternalPurchaseError>)
        case resetTapped
        case resetResponse(Result<Void, ExternalPurchaseError>)
        case dismissResetMessage
    }

    @Dependency(\.bffClient) var bffClient

    var body: some Reducer<State, Action> {
        Reduce { state, action in
            switch action {
            case .eligibilityToggled(let value):
                state.$settings.withLock { $0.isEligible = value }
                return .none

            case .acquisitionTokenToggled(let value):
                state.$settings.withLock { $0.acquisitionTokenAvailable = value }
                return .none

            case .forceTokenFailureToggled(let value):
                state.$settings.withLock { $0.forceTokenFetchFailure = value }
                return .none

            case .mintTokenTypeChanged(let type):
                state.mintTokenType = type
                return .none

            case .mintTokenVariantChanged(let variant):
                state.mintTokenVariant = variant
                return .none

            case .mintTokenTapped:
                state.isMinting = true
                state.mintResult = nil
                state.mintErrorMessage = nil
                let bffClient = bffClient
                let type = state.mintTokenType
                let variant = state.mintTokenVariant
                return .run { send in
                    do {
                        let value = try await bffClient.debugMintToken(type, variant)
                        await send(.mintTokenResponse(.success(value)))
                    } catch let error as ExternalPurchaseError {
                        await send(.mintTokenResponse(.failure(error)))
                    } catch {
                        await send(.mintTokenResponse(.failure(.network(String(describing: error)))))
                    }
                }

            case .mintTokenResponse(.success(let rawValue)):
                state.isMinting = false
                do {
                    let token = try ExternalPurchaseToken(rawValue: rawValue, expecting: state.mintTokenType)
                    state.mintResult = .token(token)
                } catch let error as TokenDecodingError {
                    state.mintResult = .decodingFailed(error)
                } catch {
                    state.mintResult = .decodingFailed(.malformedPayload(description: String(describing: error)))
                }
                return .none

            case .mintTokenResponse(.failure(let error)):
                state.isMinting = false
                state.mintErrorMessage = error.localizedDescription
                return .none

            case .handoffModeChanged(let mode):
                state.handoffMode = mode
                state.isSettingHandoffMode = true
                state.handoffModeMessage = nil
                let bffClient = bffClient
                return .run { send in
                    do {
                        try await bffClient.debugSetHandoffMode(mode)
                        await send(.handoffModeResponse(.success(())))
                    } catch let error as ExternalPurchaseError {
                        await send(.handoffModeResponse(.failure(error)))
                    } catch {
                        await send(.handoffModeResponse(.failure(.network(String(describing: error)))))
                    }
                }

            case .handoffModeResponse(.success):
                state.isSettingHandoffMode = false
                return .none

            case .handoffModeResponse(.failure(let error)):
                state.isSettingHandoffMode = false
                state.handoffModeMessage = "Update failed: \(error.localizedDescription)"
                return .none

            case .resetTapped:
                state.isResetting = true
                state.resetMessage = nil
                let bffClient = bffClient
                return .run { send in
                    do {
                        try await bffClient.debugReset()
                        await send(.resetResponse(.success(())))
                    } catch let error as ExternalPurchaseError {
                        await send(.resetResponse(.failure(error)))
                    } catch {
                        await send(.resetResponse(.failure(.network(String(describing: error)))))
                    }
                }

            case .resetResponse(.success):
                state.isResetting = false
                state.resetMessage = "Server state reset."
                state.$pendingSessions.withLock { $0.removeAll() }
                state.handoffMode = "normal"
                return .none

            case .resetResponse(.failure(let error)):
                state.isResetting = false
                state.resetMessage = "Reset failed: \(error.localizedDescription)"
                return .none

            case .dismissResetMessage:
                state.resetMessage = nil
                return .none
            }
        }
    }
}
