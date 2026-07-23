import ComposableArchitecture
import Foundation

/// Wraps everything that will eventually be StoreKit's
/// `ExternalPurchaseCustomLink` API. Every touchpoint with the real API is
/// behind this client so swapping the mock for the real thing later is a
/// single implementation change (`liveValue` below), not a call-site rewrite.
///
/// `testValue` is intentionally left fully unimplemented — every endpoint
/// fails loudly if a test invokes it without first overriding it via
/// `withDependencies`. `previewValue` is fully mocked so SwiftUI previews
/// work without any setup.
@DependencyClient
public struct ExternalPurchaseClient: Sendable {
    public var isEligible: @Sendable () async -> Bool = { false }
    /// Raw base64, exactly as StoreKit vends it — decoding happens later,
    /// in `refreshTokens`, so this client stays a thin, StoreKit-shaped
    /// wrapper rather than owning any parsing.
    public var token: @Sendable (TokenType) async throws -> String?
    public var showNotice: @Sendable (NoticeType) async throws -> NoticeResult
}

extension ExternalPurchaseClient: DependencyKey {
    // MARK: - Live (mock)

    /// TODO: When the `com.apple.developer.storekit.external-purchase-link`
    /// entitlement is granted, replace this mock with the real StoreKit
    /// calls. Before this compiles you'll need, in addition to the
    /// entitlement itself:
    ///   - `SKExternalPurchaseCustomLinkRegions` added to Info.plist, listing
    ///     the storefront region codes (e.g. `["de", "nl", ...]` for the EU)
    ///     this app is approved to show external purchase links in.
    ///   - Your checkout domain registered with Apple as part of the
    ///     entitlement request — the URL you pass below must match exactly.
    ///
    /// Sketch of the real implementation (verify the exact API surface
    /// against the StoreKit docs current at implementation time — this
    /// entitlement's API shape has moved across betas):
    ///
    ///     import StoreKit
    ///
    ///     isEligible: {
    ///         ExternalPurchaseCustomLink.token != nil
    ///         // or the then-current eligibility check — Apple's API has
    ///         // evolved from a static eligibility flag toward token
    ///         // presence as the source of truth.
    ///     },
    ///     token: { type in
    ///         switch type {
    ///         case .acquisition:
    ///             return try await ExternalPurchaseCustomLink.token(for: .acquisition)?.value
    ///         case .services:
    ///             return try await ExternalPurchaseCustomLink.token(for: .services)?.value
    ///         }
    ///     },
    ///     showNotice: { _ in
    ///         // The real disclosure sheet is presented and dismissed by
    ///         // the system automatically the moment you call `.open(_:)`
    ///         // on the external purchase link — you don't drive it
    ///         // yourself the way `NoticeSheetPresenter` does below. This
    ///         // endpoint effectively disappears; `CheckoutFeature` calls
    ///         // `ExternalPurchaseCustomLink.open(url)` directly instead,
    ///         // and that call's own throw/return communicates decline.
    ///     }
    public static let liveValue: Self = {
        Self(
            isEligible: {
                @Shared(.mockExternalPurchaseSettings) var settings = MockExternalPurchaseSettings()
                return settings.isEligible
            },
            token: { type in
                @Shared(.mockExternalPurchaseSettings) var settings = MockExternalPurchaseSettings()
                if settings.forceTokenFetchFailure {
                    throw ExternalPurchaseError.tokenFetchFailed("Simulated failure (debug menu)")
                }
                switch type {
                case .services:
                    return Self.mockTokenValue(type: .services)
                case .acquisition:
                    guard settings.acquisitionTokenAvailable else { return nil }
                    return Self.mockTokenValue(type: .acquisition)
                }
            },
            showNotice: { type in
                try await NoticeSheetPresenter.shared.present(type: type)
            }
        )
    }()

    /// Builds a well-formed, base64-encoded token payload matching Apple's
    /// real wire shape, so the mock exercises the exact same decode path a
    /// real StoreKit token would.
    static func mockTokenValue(
        type: TokenType, externalPurchaseId: UUID = UUID(), createdAt: Date = Date(),
        lifetime: TimeInterval = 365 * 24 * 60 * 60
    ) -> String {
        let payload = ExternalPurchaseTokenPayload(
            appAppleId: 1_234_567_890,
            bundleId: "de.immowelt.app",
            tokenCreationDate: createdAt,
            externalPurchaseId: externalPurchaseId,
            tokenType: type,
            tokenExpirationDate: createdAt.addingTimeInterval(lifetime)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        // swiftlint:disable:next force_try — payload is package-controlled and always encodable.
        return try! encoder.encode(payload).base64EncodedString()
    }

    // MARK: - Test / Preview

    public static let testValue = Self()

    public static let previewValue = Self(
        isEligible: { true },
        token: { type in Self.mockTokenValue(type: type) },
        showNotice: { _ in .continue }
    )
}

extension DependencyValues {
    public var externalPurchaseClient: ExternalPurchaseClient {
        get { self[ExternalPurchaseClient.self] }
        set { self[ExternalPurchaseClient.self] = newValue }
    }
}
