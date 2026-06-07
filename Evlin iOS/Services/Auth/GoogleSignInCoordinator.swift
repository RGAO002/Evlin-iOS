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

    enum GoogleSignInError: Error { case cancelled, missingToken, noPresenter, failed }

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
            throw GoogleSignInError.cancelled
        }
        guard let idToken = result.user.idToken?.tokenString else {
            throw GoogleSignInError.missingToken
        }
        let name = result.user.profile?.name
        return GoogleCredential(idToken: idToken, fullName: name)
    }

    private static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}
#else
/// Build-time fallback used until the GoogleSignIn SPM package is added
/// (Task 12 / §12). Keeps the project compiling; the real path activates
/// once `import GoogleSignIn` resolves.
@MainActor
final class GoogleSignInCoordinator {
    struct GoogleCredential { let idToken: String; let fullName: String? }
    enum GoogleSignInError: Error { case notConfigured }
    func signIn() async throws -> GoogleCredential {
        throw GoogleSignInError.notConfigured
    }
}
#endif
