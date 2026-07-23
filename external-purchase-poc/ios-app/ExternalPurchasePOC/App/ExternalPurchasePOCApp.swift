import ComposableArchitecture
import SwiftUI

@main
struct ExternalPurchasePOCApp: App {
    let store: StoreOf<AppFeature>

    init() {
        AppConfig.configureExternalPurchaseKit()
        self.store = Store(initialState: AppFeature.State()) {
            AppFeature()
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView(store: store)
        }
    }
}
