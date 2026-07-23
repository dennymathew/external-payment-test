import ComposableArchitecture
import ExternalPurchaseKit
import SwiftUI

struct PaywallView: View {
    @Bindable var store: StoreOf<PaywallFeature>
    let isReconciling: Bool

    var body: some View {
        VStack(spacing: 20) {
            if let banner = store.banner {
                BannerView(banner: banner) {
                    store.send(.bannerDismissed)
                }
            }

            Spacer()

            if store.isUnlocked {
                unlockedContent
            } else {
                productContent
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Store")
    }

    private var productContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "star.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.orange)
            Text(store.checkout.product.displayName)
                .font(.title2.bold())
            Text(store.checkout.product.priceText)
                .font(.title3)
                .foregroundStyle(.secondary)

            if isReconciling {
                ProgressView("Checking for a pending purchase…")
                    .padding(.top, 8)
            } else {
                ExternalPurchaseButton(store: store.scope(\.checkout, action: \.checkout)) { buttonState in
                    HStack {
                        if buttonState != .idle {
                            ProgressView()
                                .tint(.white)
                        }
                        Text(label(for: buttonState))
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding()
                .background(.blue)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.top, 8)
            }
        }
    }

    private var unlockedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("Unlocked!")
                .font(.title2.bold())
            Text("Thanks for your purchase.")
                .foregroundStyle(.secondary)
        }
    }

    private func label(for buttonState: CheckoutFeature.State.ButtonState) -> String {
        switch buttonState {
        case .idle: return "Buy"
        case .working: return "Preparing…"
        case .presenting: return "Checking out…"
        case .verifying: return "Verifying…"
        }
    }
}

private struct BannerView: View {
    let banner: PaywallFeature.State.Banner
    let onDismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: icon)
            Text(banner.message)
                .font(.subheadline)
            Spacer()
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(color.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var icon: String {
        switch banner.style {
        case .success: return "checkmark.circle.fill"
        case .info: return "clock.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var color: Color {
        switch banner.style {
        case .success: return .green
        case .info: return .blue
        case .error: return .red
        }
    }
}

#Preview {
    NavigationStack {
        PaywallView(
            store: Store(
                initialState: PaywallFeature.State(
                    checkout: CheckoutFeature.State(
                        product: PurchasableProduct(
                            id: "com.example.premium.monthly", userId: "preview-user",
                            displayName: "Premium Placement", priceText: "€29.99 / month"
                        )
                    )
                )
            ) {
                PaywallFeature()
            },
            isReconciling: false
        )
    }
}
