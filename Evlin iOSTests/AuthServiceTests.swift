import XCTest
@testable import Evlin_iOS

@MainActor
final class AuthServiceTests: XCTestCase {
    // AuthService is `@MainActor @Observable`, so it has an isolated `deinit`.
    // With this project's sub-iOS-18 deployment target the isolated-deinit
    // back-deployment shim (`swift_task_deinitOnExecutorMainActorBackDeploy`,
    // Swift 6.2) aborts with a malloc/heap-corruption SIGABRT when the instance
    // is released, crashing the test host before any assertion can run. We dodge
    // that toolchain defect by retaining every instance for the test process's
    // lifetime so the broken deinit hop never executes during testing. The
    // AuthService production type is unchanged; this is purely a test-harness
    // workaround for the runtime bug.
    private static var retained: [AuthService] = []
    @MainActor private func makeAuth() -> AuthService {
        let svc = AuthService(api: APIClient())
        Self.retained.append(svc)
        return svc
    }

    override func setUp() { super.setUp(); KeychainStore.shared.clear() }
    override func tearDown() { KeychainStore.shared.clear(); super.tearDown() }

    func testRestoreRebuildsCanonicalAccountFromKeychain() throws {
        let fam = UUID(); let acct = UUID()
        try KeychainStore.shared.save(StoredTokens(
            accessToken: "a", refreshToken: "r", accountID: acct.uuidString,
            familyID: fam.uuidString, displayName: "Pat", needsFamily: false))
        let auth = makeAuth()
        auth.restore()
        // §15.7: familyID + displayName survive; auth.account is the canonical DTO.
        XCTAssertEqual(auth.account?.id, acct)
        XCTAssertEqual(auth.account?.familyID, fam)
        XCTAssertEqual(auth.account?.displayName, "Pat")
        XCTAssertEqual(auth.account?.needsFamily, false)
        XCTAssertEqual(auth.state, .signedIn(auth.account!))
    }

    func testHasStoredSessionReflectsKeychain() throws {
        let auth = makeAuth()
        XCTAssertFalse(auth.hasStoredSession)
        try KeychainStore.shared.save(StoredTokens(
            accessToken: "a", refreshToken: "r", accountID: UUID().uuidString,
            familyID: nil, displayName: nil, needsFamily: true))
        XCTAssertTrue(auth.hasStoredSession)
    }
}
