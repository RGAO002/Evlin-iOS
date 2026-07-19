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
        let owner = UUID()
        appGroup.set(owner.uuidString, forKey: "evlin.childId")
        let appLimitURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-app-limit-ordering-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: appLimitURL) }
        let appLimitStore = AppLimitEpochStore(
            fileURL: appLimitURL,
            ownerProvider: {
                appGroup.string(forKey: "evlin.childId").flatMap(UUID.init(uuidString:))
            },
            legacyDefaults: nil
        )
        _ = try appLimitStore.transaction(source: .poll, expectedOwner: owner) { _ in }
        var events: [String] = []

        AuthService.clearFamilyScopedLocalState(
            appGroupDefaults: appGroup,
            appLimitStore: appLimitStore,
            teardownEarned: {
                events.append("stop")
                XCTAssertNotNil(appGroup.string(forKey: "evlin.childId"))
                XCTAssertFalse(FileManager.default.fileExists(atPath: appLimitURL.path))
            }
        )
        events.append("cleared")

        XCTAssertEqual(events, ["stop", "cleared"])
        XCTAssertNil(appGroup.string(forKey: "evlin.childId"))
    }

    func testFamilyScopedCleanupFailsClosedWhenAppLimitTeardownIsUnauthorized() throws {
        let suiteName = "AuthServiceTests.\(UUID().uuidString)"
        let appGroup = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { appGroup.removePersistentDomain(forName: suiteName) }
        let owner = UUID()
        appGroup.set(owner.uuidString, forKey: "evlin.childId")
        let appLimitURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-app-limit-fail-closed-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: appLimitURL) }
        let bindingStore = AppLimitEpochStore(
            fileURL: appLimitURL,
            ownerProvider: { owner },
            legacyDefaults: nil
        )
        _ = try bindingStore.transaction(source: .poll, expectedOwner: owner) { _ in }
        let boundBytes = try Data(contentsOf: appLimitURL)
        let unauthorizedStore = AppLimitEpochStore(
            fileURL: appLimitURL,
            ownerProvider: { UUID() },
            legacyDefaults: nil
        )
        var earnedTeardownCalled = false

        AuthService.clearFamilyScopedLocalState(
            appGroupDefaults: appGroup,
            appLimitStore: unauthorizedStore,
            teardownEarned: { earnedTeardownCalled = true }
        )

        XCTAssertFalse(earnedTeardownCalled)
        XCTAssertEqual(appGroup.string(forKey: "evlin.childId"), owner.uuidString)
        XCTAssertEqual(try Data(contentsOf: appLimitURL), boundBytes)
    }

    func testFamilyScopedCleanupFailsClosedWhenOwnerMirrorIsMissingButRootIsBound() throws {
        let suiteName = "AuthServiceTests.\(UUID().uuidString)"
        let appGroup = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { appGroup.removePersistentDomain(forName: suiteName) }
        let owner = UUID()
        let appLimitURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-app-limit-missing-owner-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: appLimitURL) }
        let appLimitStore = AppLimitEpochStore(
            fileURL: appLimitURL,
            ownerProvider: { owner },
            legacyDefaults: nil
        )
        _ = try appLimitStore.transaction(source: .poll, expectedOwner: owner) { _ in }
        let boundBytes = try Data(contentsOf: appLimitURL)
        var earnedTeardownCalled = false

        AuthService.clearFamilyScopedLocalState(
            appGroupDefaults: appGroup,
            appLimitStore: appLimitStore,
            teardownEarned: { earnedTeardownCalled = true }
        )

        XCTAssertFalse(earnedTeardownCalled)
        XCTAssertEqual(try Data(contentsOf: appLimitURL), boundBytes)
    }

    func testFamilyScopedCleanupAllowsInvalidMirrorWhenAppLimitRootIsUnbound() throws {
        let suiteName = "AuthServiceTests.\(UUID().uuidString)"
        let appGroup = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { appGroup.removePersistentDomain(forName: suiteName) }
        appGroup.set("not-a-uuid", forKey: "evlin.childId")
        let appLimitURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-app-limit-unbound-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: appLimitURL) }
        let appLimitStore = AppLimitEpochStore(
            fileURL: appLimitURL,
            ownerProvider: { nil },
            legacyDefaults: nil
        )
        var earnedTeardownCalled = false

        AuthService.clearFamilyScopedLocalState(
            appGroupDefaults: appGroup,
            appLimitStore: appLimitStore,
            teardownEarned: { earnedTeardownCalled = true }
        )

        XCTAssertTrue(earnedTeardownCalled)
        XCTAssertNil(appGroup.string(forKey: "evlin.childId"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: appLimitURL.path))
    }

    func testFamilyScopedCleanupFailsClosedWhenOwnerMirrorIsMissingAndRootIsNonempty() throws {
        let suiteName = "AuthServiceTests.\(UUID().uuidString)"
        let appGroup = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { appGroup.removePersistentDomain(forName: suiteName) }
        let appLimitURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-app-limit-unbound-nonempty-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: appLimitURL) }
        let appLimitStore = AppLimitEpochStore(
            fileURL: appLimitURL,
            ownerProvider: { nil },
            legacyDefaults: nil
        )
        let ruleID = UUID()
        _ = try appLimitStore.transaction(source: .poll, expectedOwner: nil) { state in
            state.slots[ruleID] = AppLimitVersionSlot(
                ruleID: ruleID,
                latestOrderingToken: 1,
                latestKind: .clear,
                latestPayloadDigest: "clear-1",
                activeRule: nil,
                clearTombstone: AppLimitClearTombstone(
                    ruleID: ruleID,
                    orderingToken: 1,
                    payloadDigest: "clear-1",
                    source: .poll,
                    clearedAt: Date(timeIntervalSince1970: 1_700_000_000)
                ),
                pendingOwnerWork: nil,
                appliedReceipt: nil
            )
        }
        let rootBytes = try Data(contentsOf: appLimitURL)
        var earnedTeardownCalled = false

        AuthService.clearFamilyScopedLocalState(
            appGroupDefaults: appGroup,
            appLimitStore: appLimitStore,
            teardownEarned: { earnedTeardownCalled = true }
        )

        XCTAssertFalse(earnedTeardownCalled)
        XCTAssertEqual(try Data(contentsOf: appLimitURL), rootBytes)
    }

    func testTerminalSessionNotificationSynchronouslyPersistsFailClosedBeforePostReturns() async throws {
        let suiteName = "AuthServiceTests.\(UUID().uuidString)"
        let appGroup = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { appGroup.removePersistentDomain(forName: suiteName) }
        let deviceID = UUID()
        let generation = LegacyGenerationProvenance(
            activityName: LegacyMeteringActivity.generatedActivityName(id: UUID()),
            deviceID: deviceID.uuidString,
            offsetMinutes: 0,
            usageDate: "2026-07-12",
            timezoneIdentifier: "America/New_York"
        )
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
        let appLimitURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("auth-terminal-app-limit-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: appLimitURL) }
        let appLimitStore = AppLimitEpochStore(
            fileURL: appLimitURL,
            ownerProvider: {
                appGroup.string(forKey: "evlin.childId").flatMap(UUID.init(uuidString:))
            },
            legacyDefaults: nil
        )
        _ = try appLimitStore.transaction(source: .poll, expectedOwner: deviceID) { _ in }
        try epochStore.transaction(expectedOwner: deviceID) { state in
            state.legacy = LegacyCompatibilityMonitorState(
                ownerChildDeviceID: deviceID,
                lifecycleVersion: 2,
                active: generation,
                pending: nil,
                retiringActivityNames: [],
                breadcrumbActivityNames: [],
                scalarActiveActivityName: generation.activityName,
                isStopped: false,
                phase: .activeV1,
                stopAcknowledgedAt: nil
            )
        }
        let usageStore = EarnedTimeStore(suiteName: suiteName)
        let teardown = expectation(description: "main teardown")
        let auth = makeAuth(
            terminalSessionPersistence: {
                AuthService.persistTerminalFailClosed(
                    appGroupDefaults: appGroup,
                    epochStore: epochStore,
                    appLimitStore: appLimitStore,
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
            XCTAssertFalse(FileManager.default.fileExists(atPath: appLimitURL.path))
            let state = try? epochStore.read()
            XCTAssertTrue(
                state?.identityCleanupWork?.oldActivityNames.contains(generation.activityName) == true
            )
            XCTAssertNil(LegacyMeteringActivity.authorizedCallback(
                activityName: generation.activityName,
                currentDeviceID: appGroup.string(forKey: "evlin.childId"),
                state: state?.legacy
            ))
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
