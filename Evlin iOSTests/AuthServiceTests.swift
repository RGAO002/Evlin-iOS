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
    @MainActor private func makeAuth(
        terminalSessionPersistence: (() -> Void)? = nil,
        terminalSessionTeardown: (() -> Void)? = nil
    ) -> AuthService {
        let svc = AuthService(
            api: APIClient(),
            terminalSessionPersistence: terminalSessionPersistence,
            terminalSessionTeardown: terminalSessionTeardown
        )
        Self.retained.append(svc)
        return svc
    }

    override func setUp() { super.setUp(); KeychainStore.shared.clear() }
    override func tearDown() {
        KeychainStore.shared.clear()
        for key in Self.familyScopedDefaultsKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    private static let familyScopedDefaultsKeys = [
        "evlin.accountID",
        "evlin.parentProfileID",
        "evlin.childProfileID",
        "evlin.familyID",
        "evlin.parentDeviceID",
        "evlin.childDeviceID",
        "evlin.childProfileName",
        "evlin.childBirthYear",
        "evlin.childGender",
        "evlin.protectionMode",
        "evlin.clientInstallID",
        "onboardingComplete",
        "appMode",
    ]

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

    func testSignOutLocallyClearsFamilyScopedDefaults() {
        let defaults = UserDefaults.standard
        defaults.set(UUID().uuidString, forKey: "evlin.accountID")
        defaults.set(UUID().uuidString, forKey: "evlin.parentProfileID")
        defaults.set(UUID().uuidString, forKey: "evlin.childProfileID")
        defaults.set(UUID().uuidString, forKey: "evlin.familyID")
        defaults.set(UUID().uuidString, forKey: "evlin.parentDeviceID")
        defaults.set(UUID().uuidString, forKey: "evlin.childDeviceID")
        defaults.set("Liam", forKey: "evlin.childProfileName")
        defaults.set(2017, forKey: "evlin.childBirthYear")
        defaults.set("boy", forKey: "evlin.childGender")
        defaults.set("max", forKey: "evlin.protectionMode")
        defaults.set(true, forKey: "onboardingComplete")
        defaults.set("parent", forKey: "appMode")

        makeAuth().signOutLocally()

        for key in Self.familyScopedDefaultsKeys where key != "evlin.clientInstallID" {
            XCTAssertNil(defaults.object(forKey: key), "\(key) should be cleared on sign-out")
        }
    }

    func testSignOutLocallyRotatesKidCreateInstallID() {
        let first = APIClient.clientInstallID
        XCTAssertNotNil(UserDefaults.standard.string(forKey: "evlin.clientInstallID"))

        makeAuth().signOutLocally()

        XCTAssertNil(UserDefaults.standard.string(forKey: "evlin.clientInstallID"))
        let second = APIClient.clientInstallID
        XCTAssertNotEqual(first, second, "fresh onboarding must not reuse the old child install id")
    }

    func testPostAuthFamilyCleanupPreservesOnboardingRole() {
        let defaults = UserDefaults.standard
        defaults.set("parent", forKey: "appMode")
        defaults.set(false, forKey: "onboardingComplete")
        defaults.set(UUID().uuidString, forKey: "evlin.familyID")
        defaults.set(UUID().uuidString, forKey: "evlin.childDeviceID")

        AuthService.clearFamilyScopedLocalState(clearOnboardingShell: false)

        XCTAssertEqual(defaults.string(forKey: "appMode"), "parent")
        XCTAssertEqual(defaults.object(forKey: "onboardingComplete") as? Bool, false)
        XCTAssertNil(defaults.object(forKey: "evlin.familyID"))
        XCTAssertNil(defaults.object(forKey: "evlin.childDeviceID"))
    }

    func testFamilyScopedCleanupStopsEarnedBeforeClearingMirroredChild() throws {
        let suiteName = "AuthServiceTests.\(UUID().uuidString)"
        let appGroup = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { appGroup.removePersistentDomain(forName: suiteName) }
        appGroup.set(UUID().uuidString, forKey: "evlin.childId")
        var events: [String] = []

        AuthService.clearFamilyScopedLocalState(
            appGroupDefaults: appGroup,
            teardownEarned: {
                events.append("stop")
                XCTAssertNotNil(appGroup.string(forKey: "evlin.childId"))
            }
        )
        events.append("cleared")

        XCTAssertEqual(events, ["stop", "cleared"])
        XCTAssertNil(appGroup.string(forKey: "evlin.childId"))
    }

    func testTerminalSessionNotificationSynchronouslyPersistsFailClosedBeforePostReturns() async throws {
        let suiteName = "AuthServiceTests.\(UUID().uuidString)"
        let appGroup = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { appGroup.removePersistentDomain(forName: suiteName) }
        let deviceID = UUID()
        let generation = EarnedActivityGeneration.Generation(
            activityName: EarnedActivityGeneration.generatedActivityName(id: UUID()),
            deviceID: deviceID.uuidString,
            offsetMinutes: 0,
            usageDate: "2026-07-12",
            timezoneIdentifier: "America/New_York"
        )
        XCTAssertTrue(EarnedActivityGeneration.persistLifecycle(
            .init(active: generation, pending: nil),
            defaults: appGroup
        ))
        appGroup.set(deviceID.uuidString, forKey: "evlin.childId")
        let epochURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-terminal-identity-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: epochURL) }
        let epochStore = DeviceEpochStore(
            fileURL: epochURL,
            ownerProvider: {
                appGroup.string(forKey: "evlin.childId").flatMap(UUID.init(uuidString:))
            }
        )
        let usageStore = EarnedTimeStore(suiteName: suiteName)
        let teardown = expectation(description: "main teardown")
        let auth = makeAuth(
            terminalSessionPersistence: {
                AuthService.persistTerminalFailClosed(
                    appGroupDefaults: appGroup,
                    epochStore: epochStore,
                    usageStore: usageStore
                )
            },
            terminalSessionTeardown: {
                teardown.fulfill()
            }
        )
        let postReturned = expectation(description: "background post returned")
        DispatchQueue.global().async {
            NotificationCenter.default.post(name: .evlinSessionSignedOut, object: nil)
            XCTAssertNil(appGroup.string(forKey: "evlin.childId"))
            let lifecycle = EarnedActivityGeneration.loadLifecycle(defaults: appGroup)
            XCTAssertEqual(lifecycle?.isStopped, true)
            XCTAssertNil(lifecycle?.active)
            XCTAssertTrue(lifecycle?.retiringActivityNames.contains(generation.activityName) == true)
            postReturned.fulfill()
        }

        await fulfillment(of: [postReturned, teardown], timeout: 1.0)

        XCTAssertEqual(auth.state, .signedOut)
    }

    func testTerminalObserverDeinitRemovesNotificationToken() {
        var callbackCount = 0
        var observer: AuthTerminalSessionObserver? = AuthTerminalSessionObserver(
            center: .default,
            onNotification: { callbackCount += 1 }
        )

        NotificationCenter.default.post(name: .evlinSessionSignedOut, object: nil)
        XCTAssertEqual(callbackCount, 1)

        observer = nil
        XCTAssertNil(observer)
        NotificationCenter.default.post(name: .evlinSessionSignedOut, object: nil)

        XCTAssertEqual(callbackCount, 1)
    }

    func testCompletedOnboardingRepairsMissingParentModeFromStoredSession() {
        let familyID = UUID()
        let repaired = ContentView.repairedCompletedOnboardingMode(
            onboardingComplete: true,
            currentAppMode: "",
            storedTokens: StoredTokens(
                accessToken: "a",
                refreshToken: "r",
                accountID: UUID().uuidString,
                familyID: familyID.uuidString,
                displayName: "Parent",
                needsFamily: false
            ),
            childDeviceID: nil
        )

        XCTAssertEqual(repaired, "parent")
    }
}
