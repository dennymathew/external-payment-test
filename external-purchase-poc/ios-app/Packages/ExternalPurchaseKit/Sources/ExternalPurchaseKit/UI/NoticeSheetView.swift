import SwiftUI

/// Visually approximates Apple's mandated external-purchase disclosure
/// sheet. In the real flow this exact sheet is presented and dismissed by
/// the system the moment the app calls the external purchase link API — the
/// app doesn't render it. `NoticeSheetPresenter` mimics that by presenting
/// this view outside of any app-owned navigation state.
public struct NoticeSheetView: View {
    let type: NoticeType
    let onContinue: () -> Void
    let onCancel: () -> Void

    public var body: some View {
        VStack(spacing: 20) {
            Capsule()
                .fill(.secondary.opacity(0.5))
                .frame(width: 36, height: 5)
                .padding(.top, 8)

            Image(systemName: "arrow.up.forward.app.fill")
                .font(.system(size: 40))
                .foregroundStyle(.blue)
                .padding(.top, 8)

            Text("You're About to Leave the App")
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            Text(bodyText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            VStack(spacing: 12) {
                Button(action: onContinue) {
                    Text("Continue to External Website")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(role: .cancel, action: onCancel) {
                    Text("Cancel")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .padding(.horizontal, 28)
            .padding(.top, 4)

            Text(
                "Purchases made outside the app are not processed by Apple, and Apple is not " +
                "responsible for the privacy or security of transactions made on this external website."
            )
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 28)
            .padding(.bottom, 24)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    private var bodyText: String {
        switch type {
        case .acquisition:
            return "This app allows purchases from the developer's website, which uses a " +
                "different privacy and security model than the App Store."
        case .services:
            return "You'll complete this purchase on the developer's website, outside of this app."
        }
    }
}

#Preview {
    NoticeSheetView(type: .acquisition, onContinue: {}, onCancel: {})
}
