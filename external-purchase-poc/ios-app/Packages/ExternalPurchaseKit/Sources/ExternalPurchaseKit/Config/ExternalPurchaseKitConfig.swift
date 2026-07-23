import Foundation

/// The single editable constant for the BFF / checkout server used by every
/// dependency client's `liveValue`. The host app sets this once at launch
/// (see the demo app's `AppConfig`) — Simulator can reach `localhost`
/// directly, a physical device needs the Mac's LAN IP.
public enum ExternalPurchaseKitConfig {
    /// `nonisolated(unsafe)` because this is, by design, a single mutable
    /// global the host app sets exactly once at launch (before any network
    /// call reads it) — see the demo app's `AppConfig`.
    public nonisolated(unsafe) static var baseURL = URL(string: "http://localhost:8000")!

    /// Must match `APP_URL_SCHEME` in the mock server and the
    /// `CFBundleURLSchemes` entry in the host app's Info.plist.
    public nonisolated(unsafe) static var returnURLScheme = "immowelt"

    /// Must match the host component the mock server redirects to
    /// (`immowelt://payment-complete?...`).
    public nonisolated(unsafe) static var returnURLHost = "payment-complete"

    /// Extra hosts (beyond the checkout session's own host) the webview's
    /// navigation allowlist permits — e.g. a real PSP domain (Stripe, Adyen)
    /// the checkout page redirects to mid-flow. Anything not on the
    /// checkout host or this list is cancelled and opened in Safari instead.
    public nonisolated(unsafe) static var additionalCheckoutHosts: [String] = []
}
