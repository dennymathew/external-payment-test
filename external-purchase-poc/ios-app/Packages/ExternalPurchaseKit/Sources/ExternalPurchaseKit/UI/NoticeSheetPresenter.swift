import SwiftUI
import UIKit

/// Presents `NoticeSheetView` imperatively over the key window, outside of
/// any app-owned TCA navigation state — mirroring how Apple's real
/// disclosure sheet is presented and dismissed by the system itself, not by
/// app code. This is why `ExternalPurchaseClient.showNotice` is a plain
/// async function rather than a `CheckoutFeature` presentation state.
@MainActor
public final class NoticeSheetPresenter: NSObject {
    public static let shared = NoticeSheetPresenter()

    private override init() {}

    public func present(type: NoticeType) async throws -> NoticeResult {
        guard let presenter = Self.topMostViewController() else {
            throw ExternalPurchaseError.presentationFailed("No view controller available to present from.")
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<NoticeResult, Never>) in
            let box = ResumeBox(continuation: continuation)

            let hostingController = UIHostingController(
                rootView: NoticeSheetView(
                    type: type,
                    onContinue: { box.resume(.continue, dismissing: true) },
                    onCancel: { box.resume(.cancel, dismissing: true) }
                )
            )
            hostingController.sheetPresentationController?.detents = [.medium(), .large()]
            hostingController.sheetPresentationController?.prefersGrabberVisible = true

            let delegate = DismissDelegate { box.resume(.cancel, dismissing: false) }
            hostingController.presentationController?.delegate = delegate
            // Keep the delegate alive for the lifetime of the presentation.
            objc_setAssociatedObject(hostingController, &DismissDelegate.associationKey, delegate, .OBJC_ASSOCIATION_RETAIN)

            box.viewController = hostingController
            presenter.present(hostingController, animated: true)
        }
    }

    private static func topMostViewController() -> UIViewController? {
        let keyWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)
        guard var top = keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    /// Guards against the completion firing twice (e.g. a button tap racing
    /// swipe-to-dismiss).
    private final class ResumeBox {
        private let continuation: CheckedContinuation<NoticeResult, Never>
        private var didResume = false
        weak var viewController: UIViewController?

        init(continuation: CheckedContinuation<NoticeResult, Never>) {
            self.continuation = continuation
        }

        func resume(_ result: NoticeResult, dismissing: Bool) {
            guard !didResume else { return }
            didResume = true
            if dismissing {
                viewController?.dismiss(animated: true) { [continuation] in
                    continuation.resume(returning: result)
                }
            } else {
                continuation.resume(returning: result)
            }
        }
    }

    private final class DismissDelegate: NSObject, UIAdaptivePresentationControllerDelegate {
        static var associationKey = 0
        let onDismiss: () -> Void

        init(onDismiss: @escaping () -> Void) {
            self.onDismiss = onDismiss
        }

        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            onDismiss()
        }
    }
}
