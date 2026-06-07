import AuthenticationServices
import Foundation

/// Wraps ASAuthorizationController for Sign in with Apple. Produces the
/// identity token + authorization code + first-auth full name, which the
/// caller forwards to AuthService.signInWithApple. §6.1 / §1.8.
///
/// Requires the `com.apple.developer.applesignin` entitlement (Task 12 / §12).
@MainActor
final class AppleSignInCoordinator: NSObject, ASAuthorizationControllerDelegate {
    struct AppleCredential {
        let identityToken: String
        let authorizationCode: String?
        let fullName: String?
    }

    private var continuation: CheckedContinuation<AppleCredential, Error>?

    enum AppleSignInError: Error { case cancelled, missingToken, failed }

    func signIn() async throws -> AppleCredential {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.performRequests()
        }
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let cred = authorization.credential
                as? ASAuthorizationAppleIDCredential,
              let tokenData = cred.identityToken,
              let token = String(data: tokenData, encoding: .utf8) else {
            continuation?.resume(throwing: AppleSignInError.missingToken)
            continuation = nil
            return
        }
        let code = cred.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
        let name = [cred.fullName?.givenName, cred.fullName?.familyName]
            .compactMap { $0 }.joined(separator: " ")
        continuation?.resume(returning: AppleCredential(
            identityToken: token,
            authorizationCode: code,
            fullName: name.isEmpty ? nil : name
        ))
        continuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController, didCompleteWithError error: Error
    ) {
        // User-cancel is a non-error terminal state (§4.1 / §9): surface .cancelled.
        if let asError = error as? ASAuthorizationError, asError.code == .canceled {
            continuation?.resume(throwing: AppleSignInError.cancelled)
        } else {
            continuation?.resume(throwing: AppleSignInError.failed)
        }
        continuation = nil
    }
}
