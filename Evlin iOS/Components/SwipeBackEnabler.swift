import SwiftUI
import UIKit

// Re-enables iOS edge-swipe-back in NavigationStack even when toolbar is hidden
// (SwiftUI disables the gesture when .toolbar(.hidden) or similar is used).

private struct SwipeBackEnablerRepresentable: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        DispatchQueue.main.async {
            guard let nav = uiViewController.navigationController else { return }
            nav.interactivePopGestureRecognizer?.delegate = nil
            nav.interactivePopGestureRecognizer?.isEnabled = true
        }
    }
}

extension View {
    /// Force-enable iOS edge-swipe-back gesture inside a NavigationStack.
    /// Call on the view that is pushed (not the stack root).
    func enableSwipeBack() -> some View {
        self.background(SwipeBackEnablerRepresentable().frame(width: 0, height: 0))
    }
}
