import Foundation

/// Runtime-configurable behavior for `ExternalPurchaseClient.liveValue`'s
/// mock implementation, driven from the host app's debug menu. Never
/// consulted by `testValue` or `previewValue` — TestStore tests override the
/// client's endpoints directly instead of going through this.
public struct MockExternalPurchaseSettings: Equatable, Sendable {
    public var isEligible: Bool = true
    /// Whether `token(.acquisition)` returns a value. Off by default,
    /// simulating a returning customer (the common case).
    public var acquisitionTokenAvailable: Bool = false
    public var forceTokenFetchFailure: Bool = false

    public init() {}
}
