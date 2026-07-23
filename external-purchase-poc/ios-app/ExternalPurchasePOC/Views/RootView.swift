import ComposableArchitecture
import SwiftUI

struct RootView: View {
    @Bindable var store: StoreOf<AppFeature>

    var body: some View {
        TabView {
            NavigationStack {
                PaywallView(
                    store: store.scope(\.paywall, action: \.paywall),
                    isReconciling: store.lifecycle.isReconciling
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            store.send(.debugMenuButtonTapped)
                        } label: {
                            Image(systemName: "ladybug")
                        }
                    }
                }
            }
            .tabItem { Label("Store", systemImage: "bag") }

            NavigationStack {
                EventLogView(entries: store.eventLog)
            }
            .tabItem { Label("Event Log", systemImage: "list.bullet.rectangle") }
        }
        .task { await store.send(.task).finish() }
        .sheet(
            isPresented: Binding(
                get: { store.showDebugMenu },
                set: { isPresented in if !isPresented { store.send(.debugMenuDismissed) } }
            )
        ) {
            NavigationStack {
                DebugMenuView(
                    store: store.scope(\.debugMenu, action: \.debugMenu),
                    redactedCheckoutURL: store.paywall.checkout.session?.redactedCheckoutURL
                )
            }
        }
    }
}
