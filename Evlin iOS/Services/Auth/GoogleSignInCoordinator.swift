import Foundation
#if canImport(GoogleSignIn)
import GoogleSignIn
import UIKit

/// Wraps GoogleSignIn to obtain an id_token + display name, forwarded to
/// AuthService.signInWithGoogle. §6.1. Requires the GoogleSignIn SPM package,
/// a GIDClientID, and the reversed-client-id URL scheme (Task 12 / §14.6).
@MainActor
final class GoogleSignInCoordinator {
    struct GoogleCredential {
        let idToken: String
        let fullName: String?
    }

    struct PresenterWindowSnapshot: Equatable {
        let isForegroundActive: Bool
        let isForegroundInactive: Bool
        let isKeyWindow: Bool
        let isHidden: Bool
        let hasRootViewController: Bool

        init(
            isForegroundActive: Bool,
            isForegroundInactive: Bool,
            isKeyWindow: Bool,
            isHidden: Bool,
            hasRootViewController: Bool = true
        ) {
            self.isForegroundActive = isForegroundActive
            self.isForegroundInactive = isForegroundInactive
            self.isKeyWindow = isKeyWindow
            self.isHidden = isHidden
            self.hasRootViewController = hasRootViewController
        }
    }

    enum GoogleSignInError: Error, Equatable {
        case cancelled
        case missingToken
        case noPresenter
        case failed(String)

        var diagnosticMessage: String? {
            switch self {
            case .cancelled:
                return nil
            case .missingToken:
                return "Google sign-in failed: missing id token"
            case .noPresenter:
                return "Google sign-in failed: no presenter"
            case .failed(let detail):
                return "Google sign-in failed: \(detail)"
            }
        }
    }

    func signIn() async throws -> GoogleCredential {
        guard let presenter = Self.topViewController() else {
            throw GoogleSignInError.noPresenter
        }
        let result: GIDSignInResult
        do {
            result = try await GIDSignIn.sharedInstance.signIn(
                withPresenting: presenter)
        } catch {
            // GoogleSignIn surfaces a cancel error code; treat as non-fatal.
            let ns = error as NSError
            if ns.domain == "com.google.GIDSignIn" && ns.code == -5 {
                throw GoogleSignInError.cancelled
            }
            throw GoogleSignInError.failed("\(ns.domain) \(ns.code): \(ns.localizedDescription)")
        }
        guard let idToken = result.user.idToken?.tokenString else {
            throw GoogleSignInError.missingToken
        }
        let name = result.user.profile?.name
        return GoogleCredential(idToken: idToken, fullName: name)
    }

    static func choosePresenterWindowIndex(_ windows: [PresenterWindowSnapshot]) -> Int? {
        windows.indices
            .filter { windows[$0].hasRootViewController && !windows[$0].isHidden }
            .min { lhs, rhs in
                ranking(windows[lhs]) < ranking(windows[rhs])
            }
    }

    private static func ranking(_ window: PresenterWindowSnapshot) -> (Int, Int) {
        let sceneRank: Int
        if window.isForegroundActive {
            sceneRank = 0
        } else if window.isForegroundInactive {
            sceneRank = 1
        } else {
            sceneRank = 2
        }
        let keyRank = window.isKeyWindow ? 0 : 1
        return (sceneRank, keyRank)
    }

    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
        let windows = scenes.flatMap { scene in
            scene.windows.map { window in
                (
                    window,
                    PresenterWindowSnapshot(
                        isForegroundActive: scene.activationState == .foregroundActive,
                        isForegroundInactive: scene.activationState == .foregroundInactive,
                        isKeyWindow: window.isKeyWindow,
                        isHidden: window.isHidden,
                        hasRootViewController: window.rootViewController != nil
                    )
                )
            }
        }
        let root = choosePresenterWindowIndex(windows.map(\.1))
            .flatMap { windows[$0].0.rootViewController }
            ?? windows.compactMap { $0.0.rootViewController }.first
        var top = root
        while let presented = top?.presentedViewController { top = presented }
        return top
    }

    /// Forward an incoming OAuth-redirect URL to GoogleSignIn. Called from the
    /// app's `.onOpenURL`. Returns true if GoogleSignIn handled it.
    @discardableResult
    static func handleURL(_ url: URL) -> Bool {
        GIDSignIn.sharedInstance.handle(url)
    }
}
#else
/// Build-time fallback used until the GoogleSignIn SPM package is added
/// (Task 12 / §12). Keeps the project compiling; the real path activates
/// once `import GoogleSignIn` resolves.
@MainActor
final class GoogleSignInCoordinator {
    struct GoogleCredential { let idToken: String; let fullName: String? }
    struct PresenterWindowSnapshot: Equatable {
        let isForegroundActive: Bool
        let isForegroundInactive: Bool
        let isKeyWindow: Bool
        let isHidden: Bool
        let hasRootViewController: Bool

        init(
            isForegroundActive: Bool,
            isForegroundInactive: Bool,
            isKeyWindow: Bool,
            isHidden: Bool,
            hasRootViewController: Bool = true
        ) {
            self.isForegroundActive = isForegroundActive
            self.isForegroundInactive = isForegroundInactive
            self.isKeyWindow = isKeyWindow
            self.isHidden = isHidden
            self.hasRootViewController = hasRootViewController
        }
    }
    enum GoogleSignInError: Error, Equatable {
        case cancelled
        case missingToken
        case noPresenter
        case failed(String)
        case notConfigured

        var diagnosticMessage: String? {
            switch self {
            case .cancelled:
                return nil
            case .missingToken:
                return "Google sign-in failed: missing id token"
            case .noPresenter:
                return "Google sign-in failed: no presenter"
            case .failed(let detail):
                return "Google sign-in failed: \(detail)"
            case .notConfigured:
                return "Google sign-in failed: GoogleSignIn package is not linked"
            }
        }
    }
    func signIn() async throws -> GoogleCredential {
        throw GoogleSignInError.notConfigured
    }
    static func choosePresenterWindowIndex(_ windows: [PresenterWindowSnapshot]) -> Int? {
        windows.indices
            .filter { windows[$0].hasRootViewController && !windows[$0].isHidden }
            .min { lhs, rhs in
                ranking(windows[lhs]) < ranking(windows[rhs])
            }
    }
    private static func ranking(_ window: PresenterWindowSnapshot) -> (Int, Int) {
        let sceneRank: Int
        if window.isForegroundActive {
            sceneRank = 0
        } else if window.isForegroundInactive {
            sceneRank = 1
        } else {
            sceneRank = 2
        }
        let keyRank = window.isKeyWindow ? 0 : 1
        return (sceneRank, keyRank)
    }
    /// No-op until the GoogleSignIn SPM package is added.
    @discardableResult
    static func handleURL(_ url: URL) -> Bool { false }
}
#endif
