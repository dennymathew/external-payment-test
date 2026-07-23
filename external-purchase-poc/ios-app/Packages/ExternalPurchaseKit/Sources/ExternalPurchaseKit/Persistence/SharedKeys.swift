import ComposableArchitecture
import Foundation

/// Every `@Shared` key the package uses, centralized so the string/URL
/// identifiers backing them are defined exactly once.
extension SharedKey where Self == InMemoryKey<TokenHealth> {
    /// Outcome of the most recent ACQUISITION fetch/decode attempt.
    /// In-memory only — refetched every launch, never persisted to disk.
    public static var externalPurchaseAcquisitionHealth: Self {
        inMemory("externalPurchaseKit.acquisitionHealth")
    }
}

extension SharedKey where Self == InMemoryKey<TokenSnapshot> {
    /// The most recently fetched ACQUISITION + SERVICES tokens. In-memory
    /// only, so a fresh launch always re-asks rather than trusting a
    /// snapshot from a previous process.
    public static var externalPurchaseTokenSnapshot: Self {
        inMemory("externalPurchaseKit.tokenSnapshot")
    }
}

extension SharedKey where Self == InMemoryKey<MockExternalPurchaseSettings> {
    /// Debug-menu-controlled knobs for the mock `ExternalPurchaseClient`
    /// live implementation. Process-lifetime only.
    public static var mockExternalPurchaseSettings: Self {
        inMemory("externalPurchaseKit.mockSettings")
    }
}

extension SharedKey where Self == FileStorageKey<[PendingSession]>.Default {
    /// Sessions the user engaged with (saw the web checkout) whose outcome
    /// wasn't confirmed before the app stopped. Reconciled against the BFF
    /// at next launch before purchase UI is shown.
    public static var externalPurchasePendingSessions: Self {
        Self[.fileStorage(pendingSessionsURL), default: []]
    }

    private static var pendingSessionsURL: URL {
        URL.documentsDirectory.appending(path: "external-purchase-kit-pending-sessions.json")
    }
}

extension SharedKey where Self == FileStorageKey<DeviceIdentity>.Default {
    public static var externalPurchaseDeviceIdentity: Self {
        Self[.fileStorage(deviceIdentityURL), default: DeviceIdentity()]
    }

    private static var deviceIdentityURL: URL {
        URL.documentsDirectory.appending(path: "external-purchase-kit-device-identity.json")
    }
}
