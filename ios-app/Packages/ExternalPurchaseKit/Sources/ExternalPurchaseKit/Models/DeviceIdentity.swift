import Foundation

/// Generated once and persisted to disk, and sent as the `Device-Id` header
/// on every `/tokens` report. Idempotency itself is no longer a
/// client-generated key — it's derived from the purchase IDs themselves
/// (see `TokenSnapshot.idempotencyKey`), so the BFF's own cache naturally
/// no-ops a resubmission of the same token pair.
public struct DeviceIdentity: Equatable, Sendable, Codable {
    public var deviceId: String = UUID().uuidString

    public init() {}
}
