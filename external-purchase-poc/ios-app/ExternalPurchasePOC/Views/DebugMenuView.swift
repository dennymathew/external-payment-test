import ComposableArchitecture
import ExternalPurchaseKit
import SwiftUI

struct DebugMenuView: View {
    @Bindable var store: StoreOf<DebugMenuFeature>
    let redactedCheckoutURL: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Mock ExternalPurchaseClient") {
                Toggle(
                    "Eligible for external purchase",
                    isOn: Binding(
                        get: { store.settings.isEligible },
                        set: { store.send(.eligibilityToggled($0)) }
                    )
                )
                Toggle(
                    "Acquisition token available",
                    isOn: Binding(
                        get: { store.settings.acquisitionTokenAvailable },
                        set: { store.send(.acquisitionTokenToggled($0)) }
                    )
                )
                Text("Off by default — simulates a returning customer, for whom Apple legitimately vends no ACQUISITION token.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(
                    "Force token fetch failure",
                    isOn: Binding(
                        get: { store.settings.forceTokenFetchFailure },
                        set: { store.send(.forceTokenFailureToggled($0)) }
                    )
                )
            }

            Section("Token State") {
                LabeledContent("ACQUISITION", value: description(for: store.acquisitionHealth))
                LabeledContent("Cached SERVICES", value: store.tokenSnapshot.services == nil ? "None" : "Cached")
            }

            Section("Mint a Debug Token (/debug/mint-token)") {
                Picker("Type", selection: Binding(
                    get: { store.mintTokenType },
                    set: { store.send(.mintTokenTypeChanged($0)) }
                )) {
                    ForEach(TokenType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                Picker("Variant", selection: Binding(
                    get: { store.mintTokenVariant },
                    set: { store.send(.mintTokenVariantChanged($0)) }
                )) {
                    ForEach(DebugTokenVariant.allCases, id: \.self) { variant in
                        Text(variant.rawValue).tag(variant)
                    }
                }
                Button {
                    store.send(.mintTokenTapped)
                } label: {
                    if store.isMinting {
                        ProgressView()
                    } else {
                        Text("Mint & Decode")
                    }
                }
                .disabled(store.isMinting)

                if let message = store.mintErrorMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                if let result = store.mintResult {
                    mintResultView(result)
                }
            }

            Section("Auth Handoff (/debug/handoff-mode)") {
                Picker("Mode", selection: Binding(
                    get: { store.handoffMode },
                    set: { store.send(.handoffModeChanged($0)) }
                )) {
                    ForEach(DebugMenuFeature.State.handoffModes, id: \.self) { mode in
                        Text(mode).tag(mode)
                    }
                }
                if store.isSettingHandoffMode {
                    ProgressView()
                }
                if let message = store.handoffModeMessage {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
                if let redactedCheckoutURL {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Currently loaded checkout URL").font(.caption).foregroundStyle(.secondary)
                        Text(redactedCheckoutURL).font(.caption2.monospaced())
                    }
                } else {
                    Text("No checkout URL currently loaded.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Pending Sessions (\(store.pendingSessions.count))") {
                if store.pendingSessions.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    ForEach(store.pendingSessions) { session in
                        VStack(alignment: .leading) {
                            Text(session.id).font(.caption.monospaced())
                            Text(session.productId).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Server") {
                Button(role: .destructive) {
                    store.send(.resetTapped)
                } label: {
                    if store.isResetting {
                        ProgressView()
                    } else {
                        Text("Hit /debug/reset")
                    }
                }
                .disabled(store.isResetting)
                if let message = store.resetMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Debug Menu")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    @ViewBuilder
    private func mintResultView(_ result: DebugMenuFeature.State.MintResult) -> some View {
        switch result {
        case .token(let token):
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("appAppleId", value: "\(token.payload.appAppleId)")
                LabeledContent("bundleId", value: token.payload.bundleId)
                LabeledContent("externalPurchaseId", value: token.payload.externalPurchaseId.uuidString)
                LabeledContent("tokenCreationDate", value: token.payload.tokenCreationDate.formatted())
                LabeledContent("tokenType", value: token.payload.tokenType?.rawValue ?? "nil")
                LabeledContent("tokenExpirationDate", value: token.payload.tokenExpirationDate?.formatted() ?? "nil")
                LabeledContent("Time to expiry", value: timeToExpiry(token))
            }
            .font(.caption)
        case .decodingFailed(let error):
            Text("Decode failed: \(error)")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func timeToExpiry(_ token: ExternalPurchaseToken) -> String {
        guard let expiresAt = token.expiresAt else { return "n/a" }
        let interval = expiresAt.timeIntervalSinceNow
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.unitsStyle = .abbreviated
        let formatted = formatter.string(from: abs(interval)) ?? "\(Int(abs(interval)))s"
        return interval < 0 ? "expired \(formatted) ago" : "in \(formatted)"
    }

    private func description(for health: TokenHealth) -> String {
        switch health {
        case .notRequested:
            return "Not requested"
        case .unavailable(.expectedForReturningCustomer):
            return "Unavailable (returning customer)"
        case .unavailable(.subsystemFailure(let message)):
            return "Subsystem failure: \(message)"
        case .available(let token, let fetchedAt):
            return "\(token.externalPurchaseId.uuidString.prefix(8)) (fetched \(fetchedAt.formatted(date: .omitted, time: .standard)))"
        case .malformed(let error):
            return "Malformed: \(error)"
        }
    }
}

#Preview {
    NavigationStack {
        DebugMenuView(
            store: Store(initialState: DebugMenuFeature.State()) { DebugMenuFeature() },
            redactedCheckoutURL: nil
        )
    }
}
