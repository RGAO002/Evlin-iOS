import AuthenticationServices
import CryptoKit
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
        let rawNonce: String
    }

    private var continuation: CheckedContinuation<AppleCredential, Error>?
    private var currentRawNonce: String?

    enum AppleSignInError: Error { case cancelled, missingToken, failed }

    func signIn() async throws -> AppleCredential {
        try await withCheckedThrowingContinuation { cont in
            self.continuation = cont
            let raw = randomNonceString()
            self.currentRawNonce = raw
            let request = ASAuthorizationAppleIDProvider().createRequest()
            request.requestedScopes = [.fullName, .email]
            request.nonce = sha256Hex(raw)
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
            fullName: name.isEmpty ? nil : name,
            rawNonce: currentRawNonce ?? ""
        ))
        continuation = nil
        currentRawNonce = nil
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

    private func randomNonceString(length: Int = 32) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        let charset: [Character] =
            Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(bytes.map { charset[Int($0) % charset.count] })
    }

    private func sha256Hex(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}
