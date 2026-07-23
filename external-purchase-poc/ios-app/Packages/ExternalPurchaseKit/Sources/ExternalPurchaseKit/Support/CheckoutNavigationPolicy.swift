import Foundation

/// Pure decision logic for the webview's `decidePolicyFor(navigationAction:)`
/// — kept separate from `CheckoutWebView.Coordinator` so it's testable
/// without standing up a real `WKWebView`.
enum CheckoutNavigationPolicy {
    enum Decision: Equatable {
        /// Our app's own return URL — cancel the navigation and let
        /// `CheckoutFeature` ask the BFF what actually happened.
        case cancelForRedirect
        case allow
        /// Not the checkout host or an approved PSP host — cancel and open
        /// externally (Safari) instead of navigating inside the sheet.
        case cancelAndOpenExternally
    }

    static func decision(
        for url: URL, allowedHosts: Set<String>,
        returnURLScheme: String = ExternalPurchaseKitConfig.returnURLScheme,
        returnURLHost: String = ExternalPurchaseKitConfig.returnURLHost
    ) -> Decision {
        if url.scheme == returnURLScheme, url.host == returnURLHost {
            return .cancelForRedirect
        }
        if let host = url.host, allowedHosts.contains(host) {
            return .allow
        }
        return .cancelAndOpenExternally
    }
}
