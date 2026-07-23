import SwiftUI
import UIKit
import WebKit

/// Custom `UIViewRepresentable` around `WKWebView` — deliberately not
/// `ASWebAuthenticationSession` or `SFSafariViewController`. Those hand
/// control of navigation to the system; the real external-purchase flow (and
/// this mock) needs a `WKNavigationDelegate` so it can intercept the return
/// URL itself and handle a checkout that spans multiple page loads.
struct CheckoutWebView: UIViewRepresentable {
    let url: URL
    let dataStore: WKWebsiteDataStore
    let allowedHosts: Set<String>
    let onNavigationStarted: () -> Void
    let onNavigationFinished: () -> Void
    let onNavigationFailed: () -> Void
    let onRedirectIntercepted: () -> Void
    let onHandoffRejected: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        // The checkout session must not outlive the purchase, and stale
        // cookies must not survive an account switch — a persistent store
        // would let both happen.
        configuration.websiteDataStore = dataStore
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: CheckoutWebView

        init(_ parent: CheckoutWebView) {
            self.parent = parent
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            // Never trust anything about *what* this URL claims (its query
            // string) — only which host/scheme it's on.
            switch CheckoutNavigationPolicy.decision(for: url, allowedHosts: parent.allowedHosts) {
            case .cancelForRedirect:
                decisionHandler(.cancel)
                parent.onRedirectIntercepted()
            case .allow:
                decisionHandler(.allow)
            case .cancelAndOpenExternally:
                decisionHandler(.cancel)
                UIApplication.shared.open(url)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if let http = navigationResponse.response as? HTTPURLResponse, http.statusCode == 401 {
                decisionHandler(.cancel)
                parent.onHandoffRejected()
                return
            }
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.onNavigationStarted()
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.onNavigationFinished()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.onNavigationFailed()
        }

        func webView(
            _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
        ) {
            parent.onNavigationFailed()
        }
    }
}
