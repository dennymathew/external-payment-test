import Foundation
import Testing

@testable import ExternalPurchaseKit

struct CheckoutNavigationPolicyTests {
    private let allowedHosts: Set<String> = ["localhost", "checkout.example.com"]

    @Test
    func allowlistedHostIsAllowed() {
        let url = URL(string: "https://checkout.example.com/checkout/session-1/payment")!
        #expect(CheckoutNavigationPolicy.decision(for: url, allowedHosts: allowedHosts) == .allow)
    }

    @Test
    func nonAllowlistedHostIsCancelledAndOpenedExternally() {
        // Mirrors the mock checkout's "Open partner site" link.
        let url = URL(string: "https://example.com")!
        #expect(CheckoutNavigationPolicy.decision(for: url, allowedHosts: allowedHosts) == .cancelAndOpenExternally)
    }

    @Test
    func returnURLSchemeIsCancelledForRedirectHandling() {
        let url = URL(string: "immowelt://payment-complete?session_id=abc&status=paid")!
        let decision = CheckoutNavigationPolicy.decision(
            for: url, allowedHosts: allowedHosts,
            returnURLScheme: "immowelt", returnURLHost: "payment-complete"
        )
        #expect(decision == .cancelForRedirect)
    }
}
