import ComposableArchitecture
import SwiftUI
import WebKit

/// The sheet presented for `CheckoutFeature.State.webCheckout`. Shows a
/// loading state while the page loads and a Done/Cancel toolbar; every exit
/// path — redirect, Done, Cancel, or swipe-to-dismiss (handled by
/// `CheckoutFeature`'s `.ifLet` via `PresentationAction.dismiss`) — funnels
/// through the same "always verify" logic in the parent feature.
public struct CheckoutSheetView: View {
    @Bindable var store: StoreOf<WebCheckoutFeature>
    /// Owned here (not by `CheckoutWebView`) so it survives for the
    /// lifetime of the sheet and can be explicitly wiped on dismissal,
    /// regardless of how the sheet closed.
    private let dataStore = WKWebsiteDataStore.nonPersistent()

    public init(store: StoreOf<WebCheckoutFeature>) {
        self.store = store
    }

    public var body: some View {
        NavigationStack {
            ZStack {
                CheckoutWebView(
                    url: store.checkoutURL,
                    dataStore: dataStore,
                    allowedHosts: allowedHosts,
                    onNavigationStarted: { store.send(.navigationStarted) },
                    onNavigationFinished: { store.send(.navigationFinished) },
                    onNavigationFailed: { store.send(.navigationFailed) },
                    onRedirectIntercepted: { store.send(.redirectIntercepted) },
                    onHandoffRejected: { store.send(.handoffRejected) }
                )

                if store.isLoading {
                    ProgressView()
                }

                if store.loadFailed {
                    ContentUnavailableView(
                        "Couldn't Load Checkout",
                        systemImage: "wifi.exclamationmark",
                        description: Text("Check that the server is reachable and try again.")
                    )
                    .background(.background)
                }
            }
            .navigationTitle("Checkout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.send(.cancelButtonTapped) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { store.send(.doneButtonTapped) }
                }
            }
        }
        .onDisappear {
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        }
    }

    private var allowedHosts: Set<String> {
        Set([store.checkoutURL.host].compactMap { $0 } + ExternalPurchaseKitConfig.additionalCheckoutHosts)
    }
}
