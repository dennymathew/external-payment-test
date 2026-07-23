import ComposableArchitecture
import SwiftUI

/// Thin wrapper over `CheckoutFeature` — owns nothing beyond driving the
/// tap and presenting the web checkout sheet. The host app supplies the
/// store (so it decides where `CheckoutFeature.State` lives in its own
/// feature tree) and controls all styling via the label closure.
public struct ExternalPurchaseButton<Label: View>: View {
    @Bindable var store: StoreOf<CheckoutFeature>
    private let label: (CheckoutFeature.State.ButtonState) -> Label

    public init(
        store: StoreOf<CheckoutFeature>,
        @ViewBuilder label: @escaping (CheckoutFeature.State.ButtonState) -> Label
    ) {
        self.store = store
        self.label = label
    }

    public var body: some View {
        Button {
            store.send(.buttonTapped)
        } label: {
            label(store.buttonState)
        }
        .disabled(store.isBusy)
        .sheet(item: $store.scope(\.webCheckout, action: \.webCheckout)) { webStore in
            CheckoutSheetView(store: webStore)
        }
    }
}
