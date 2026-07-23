import ExternalPurchaseKit
import Foundation

enum AppConfig {
    /// The Simulator shares the Mac's network stack, so "localhost" reaches
    /// the FastAPI server directly. A physical device cannot resolve
    /// "localhost" to your Mac — edit the LAN IP below for device testing.
    /// Find it with: ipconfig getifaddr en0
    #if targetEnvironment(simulator)
    static let backendBaseURL = URL(string: "http://localhost:8000")!
    #else
    static let backendBaseURL = URL(string: "http://192.168.1.23:8000")!  // EDIT ME for device testing
    #endif

    /// Applies the above to `ExternalPurchaseKit` — call once at launch,
    /// before any dependency client touches the network.
    static func configureExternalPurchaseKit() {
        ExternalPurchaseKitConfig.baseURL = backendBaseURL
        ExternalPurchaseKitConfig.returnURLScheme = "immowelt"
        ExternalPurchaseKitConfig.returnURLHost = "payment-complete"
    }
}
