import XCTest
import FamilyControls

@testable import Evlin_iOS

/// Pairing v2 client-side contract. Plan Task 1-2.
final class PairingV2Tests: XCTestCase {

    // MARK: - Scan payload

    func test_scannedInvite_parsesV2TokenAndLegacyAndRejectsJunk() {
        XCTAssertEqual(ScannedInvite.parse("evlin-invite:v2:abcDEF123_-"),
                       .v2Token("abcDEF123_-"))
        XCTAssertEqual(ScannedInvite.parse("483920"), .legacySixDigit("483920"))
        XCTAssertEqual(ScannedInvite.parse("  483920\n"), .legacySixDigit("483920"))
        XCTAssertNil(ScannedInvite.parse("evlin-invite:v2:"))
        XCTAssertNil(ScannedInvite.parse("48392"))
        XCTAssertNil(ScannedInvite.parse("hello world"))
    }

    // MARK: - Wire decoding

    func test_resolveResponse_decodesSnakeCaseWithAndWithoutRestore() throws {
        let withRestore = #"""
        {"resolve_session":"rs1",
         "invited":{"purpose":"add_device","child_display_name":"Son"},
         "restore":{"child_display_name":"Son"}}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(PairingResolveResponse.self,
                                               from: withRestore)
        XCTAssertEqual(decoded.resolveSession, "rs1")
        XCTAssertEqual(decoded.invited.purpose, .addDevice)
        XCTAssertEqual(decoded.invited.childDisplayName, "Son")
        XCTAssertEqual(decoded.restore?.childDisplayName, "Son")

        let noRestore = #"""
        {"resolve_session":"rs2",
         "invited":{"purpose":"new_child","child_display_name":null}}
        """#.data(using: .utf8)!
        let plain = try JSONDecoder().decode(PairingResolveResponse.self,
                                             from: noRestore)
        XCTAssertEqual(plain.invited.purpose, .newChild)
        XCTAssertNil(plain.invited.childDisplayName)
        XCTAssertNil(plain.restore)
    }

    // MARK: - Durable adoption record

    private func makeTempStore() throws -> (PendingAdoptionStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir,
                                                withIntermediateDirectories: true)
        return (PendingAdoptionStore(directoryURL: dir), dir)
    }

    func test_pendingAdoption_survivesReloadWithCanonicalBodyIntact() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(store.load())

        let record = PendingAdoptionRecord(
            inviteID: UUID(),
            resolveSession: "rs1",
            choice: .invited,
            oldUUID: nil,
            profile: .init(displayName: "Kid", birthYear: 2015, gender: nil),
            deviceSnapshot: ["install_id": "inst-1", "platform": "iOS"]
        )
        try store.save(record)

        // A fresh instance stands in for a relaunch.
        let reloaded = PendingAdoptionStore(directoryURL: dir).load()
        XCTAssertEqual(reloaded, record)
        // Without these two the replay cannot rebuild an identical request.
        XCTAssertEqual(reloaded?.profile?.displayName, "Kid")
        XCTAssertEqual(reloaded?.deviceSnapshot["install_id"], "inst-1")

        store.clear()
        XCTAssertNil(PendingAdoptionStore(directoryURL: dir).load())
    }

    func test_pendingAdoption_phaseAdvanceOverwritesInPlace() throws {
        let (store, dir) = try makeTempStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        var record = PendingAdoptionRecord(
            inviteID: UUID(), resolveSession: "rs1", choice: .restore,
            oldUUID: UUID()
        )
        try store.save(record)
        record.phase = .converging
        try store.save(record)
        XCTAssertEqual(store.load()?.phase, .converging)
        XCTAssertEqual(store.load()?.operationID, record.operationID)
    }

    // MARK: - Client request shaping

    func test_resolveBody_routesTypedCodesAndScannedTokensSeparately() {
        let scanned = PairingV2Client.resolveBody(invite: .v2Token("abc"),
                                                  device: ["platform": "iOS"])
        XCTAssertEqual(scanned["token"] as? String, "abc")
        XCTAssertNil(scanned["code"])

        let typed = PairingV2Client.resolveBody(invite: .legacySixDigit("483920"),
                                                device: [:])
        XCTAssertEqual(typed["code"] as? String, "483920")
        XCTAssertNil(typed["token"])
    }

    func test_commitBody_isDerivedOnlyFromTheStoredRecord() {
        let record = PairingV2Client.makeCommitRecord(
            inviteID: nil,
            resolveSession: "rs9",
            choice: .invited,
            profile: .init(displayName: "Kid", birthYear: nil, gender: nil),
            device: ["install_id": "i2"],
            oldUUID: nil
        )
        let body = PairingV2Client.commitBody(from: record)
        XCTAssertEqual(body["resolve_session"] as? String, "rs9")
        XCTAssertEqual(body["choice"] as? String, "invited")
        XCTAssertEqual((body["device"] as? [String: String])?["install_id"], "i2")
        let profile = body["profile"] as? [String: Any]
        XCTAssertEqual(profile?["display_name"] as? String, "Kid")
        // Absent optionals stay absent rather than becoming null — the server
        // digests this dictionary, so an extra key would break the replay match.
        XCTAssertNil(profile?["birth_year"])

        // Rebuilding from the same record must give the same body; that is what
        // makes a post-relaunch replay match the original digest.
        XCTAssertEqual(
            NSDictionary(dictionary: body),
            NSDictionary(dictionary: PairingV2Client.commitBody(from: record))
        )
    }

    // MARK: - Kid-side branching

    func test_kidFlow_restoreOfferBeatsTheInvitedBranch_butKeepsNewChildChoice() {
        let response = PairingResolveResponse(
            resolveSession: "rs",
            invited: .init(purpose: .newChild, childDisplayName: nil),
            restore: .init(childDisplayName: "Kid")
        )
        // Even on a new-child invite, a device with prior identity here must be
        // offered restore — otherwise it silently mints a duplicate child.
        XCTAssertEqual(KidJoinFlowModel.stage(for: response),
                       .offerRestore(childName: "Kid", canSetUpSomeoneNew: true))
    }

    func test_kidFlow_addDeviceRestoreCannotBecomeANewChild() {
        let response = PairingResolveResponse(
            resolveSession: "rs",
            invited: .init(purpose: .addDevice, childDisplayName: "Kid"),
            restore: .init(childDisplayName: "Kid")
        )

        XCTAssertEqual(KidJoinFlowModel.stage(for: response),
                       .offerRestore(childName: "Kid", canSetUpSomeoneNew: false))
    }

    func test_kidFlow_addDeviceConfirmsAndNewChildCollectsAProfile() {
        let addDevice = PairingResolveResponse(
            resolveSession: "rs",
            invited: .init(purpose: .addDevice, childDisplayName: "Kid"),
            restore: nil
        )
        XCTAssertEqual(KidJoinFlowModel.stage(for: addDevice),
                       .confirmAddDevice(childName: "Kid"))

        let newChild = PairingResolveResponse(
            resolveSession: "rs",
            invited: .init(purpose: .newChild, childDisplayName: nil),
            restore: nil
        )
        XCTAssertEqual(KidJoinFlowModel.stage(for: newChild),
                       .collectNewChildProfile)
    }

    // MARK: - Pairing metering bootstrap

    @MainActor
    func test_pairingPreparesPublishesAndRecoversBeforePollingCurrentPolicy() async {
        let childDeviceID = UUID()
        var steps: [String] = []
        var startedDeviceID: UUID?

        let bootstrap = KidJoinMeteringBootstrap(
            prepareIdentity: { deviceID in
                XCTAssertEqual(deviceID, childDeviceID)
                steps.append("prepare")
            },
            convergeAppLimitIdentity: { deviceID in
                XCTAssertEqual(deviceID, childDeviceID)
                XCTAssertEqual(steps, ["prepare"])
                steps.append("converge-app-limit")
            },
            publishSelection: {
                XCTAssertEqual(steps, ["prepare", "converge-app-limit"])
                steps.append("publish")
                return true
            },
            publishMatchedCatalog: {
                XCTAssertEqual(steps, ["prepare", "converge-app-limit", "publish"])
                steps.append("publish-matched")
                return true
            },
            recoverMetering: {
                XCTAssertEqual(
                    steps,
                    ["prepare", "converge-app-limit", "publish", "publish-matched"]
                )
                steps.append("recover")
            },
            startCommandOwner: { deviceID in
                steps.append("start")
                startedDeviceID = deviceID
            }
        )

        await bootstrap.run(for: childDeviceID)

        XCTAssertEqual(
            steps,
            ["prepare", "converge-app-limit", "publish", "publish-matched", "recover", "start"]
        )
        XCTAssertEqual(startedDeviceID, childDeviceID)
    }

    @MainActor
    func test_pairingStillStartsPolicyOwnerWhenRetainedSelectionIsEmpty() async {
        let childDeviceID = UUID()
        var started = false

        let bootstrap = KidJoinMeteringBootstrap(
            prepareIdentity: { _ in },
            convergeAppLimitIdentity: { _ in },
            publishSelection: { false },
            publishMatchedCatalog: { false },
            recoverMetering: {},
            startCommandOwner: { deviceID in
                XCTAssertEqual(deviceID, childDeviceID)
                started = true
            }
        )

        await bootstrap.run(for: childDeviceID)

        XCTAssertTrue(started)
    }

    @MainActor
    func test_pairingStillRecoversWhenMatchedCatalogRepublishFails() async {
        let childDeviceID = UUID()
        var recovered = false
        var started = false

        let bootstrap = KidJoinMeteringBootstrap(
            prepareIdentity: { _ in },
            convergeAppLimitIdentity: { _ in },
            publishSelection: { true },
            publishMatchedCatalog: { false },
            recoverMetering: { recovered = true },
            startCommandOwner: { _ in started = true }
        )

        await bootstrap.run(for: childDeviceID)

        XCTAssertTrue(recovered)
        XCTAssertTrue(started)
    }

    @MainActor
    func test_repairingUnderANewDevicePublishesSelectionWithoutOldAlias() {
        let oldDeviceID = UUID()
        let newDeviceID = UUID()
        let oldAlias = UUID()

        XCTAssertTrue(AppControlsBackendSync.shouldPublish(
            deviceID: newDeviceID,
            selectionSignature: "same-selection",
            lockedSetAliasKey: oldAlias,
            publishedDeviceID: oldDeviceID,
            publishedSignature: "same-selection"
        ))
        XCTAssertNil(AppControlsBackendSync.aliasKeyForUpload(
            deviceID: newDeviceID,
            lockedSetAliasKey: oldAlias,
            publishedDeviceID: oldDeviceID
        ))
    }

    @MainActor
    func test_sameDeviceUnchangedSelectionDoesNotRepublish() {
        let deviceID = UUID()
        let alias = UUID()

        XCTAssertFalse(AppControlsBackendSync.shouldPublish(
            deviceID: deviceID,
            selectionSignature: "same-selection",
            lockedSetAliasKey: alias,
            publishedDeviceID: deviceID,
            publishedSignature: "same-selection"
        ))
        XCTAssertEqual(AppControlsBackendSync.aliasKeyForUpload(
            deviceID: deviceID,
            lockedSetAliasKey: alias,
            publishedDeviceID: deviceID
        ), alias)
    }

    @MainActor
    func test_retainedAppControlsSelectionDoesNotOverwriteMeteringSelection() throws {
        let retained = FamilyActivitySelection()
        var loaded = false

        let returned = AppControlsBackendSync.retainedSelectionForCatalogUpload(
            load: {
                loaded = true
                return retained
            }
        )

        XCTAssertTrue(loaded)
        XCTAssertEqual(returned, retained)
    }

    // MARK: - Parent invite

    func test_settingsAddChildUsesUntargetedNewChildInvite() {
        XCTAssertEqual(ParentNewChildPairingPresentation.invitePurpose, .newChild)
        XCTAssertNil(ParentNewChildPairingPresentation.targetChildProfileID)
    }

    func test_inviteCreated_decodesTheMicrosecondsTheBackendActuallySends() throws {
        // Pydantic emits `...815296+00:00`. Stock .iso8601 throws on that, and
        // the throw surfaced as "Couldn't create a code" even though the server
        // had minted one — the shared decoder has to accept both shapes.
        let withMicroseconds = """
        {"invite_id":"\(UUID())","code_display":"483920",
         "qr_payload":"evlin-invite:v2:tok",
         "expires_at":"2026-07-29T05:12:55.815296+00:00"}
        """.data(using: .utf8)!
        let invite = try JSONDecoder.pairingV2.decode(PairingInviteCreated.self,
                                                      from: withMicroseconds)
        XCTAssertEqual(invite.codeDisplay, "483920")
        // Rendered verbatim into the QR, so the prefix has to survive decoding.
        XCTAssertEqual(invite.qrPayload, "evlin-invite:v2:tok")

        let withoutFraction = """
        {"invite_id":"\(UUID())","code_display":"111111",
         "qr_payload":"evlin-invite:v2:t2","expires_at":"2026-07-29T01:00:00Z"}
        """.data(using: .utf8)!
        XCTAssertNoThrow(
            try JSONDecoder.pairingV2.decode(PairingInviteCreated.self,
                                             from: withoutFraction)
        )
    }

    @MainActor
    func test_mintDoesNotReplaceACodeTheParentIsStillShowing() async {
        nonisolated(unsafe) var mints = 0
        let model = ParentInviteModel(api: ParentInviteAPI(
            ensureFamily: { UUID() },
            createInvite: { _, _ in
                mints += 1
                return PairingInviteCreated(
                    inviteID: UUID(), codeDisplay: "483920",
                    qrPayload: "evlin-invite:v2:tok",
                    expiresAt: Date().addingTimeInterval(600)
                )
            },
            fetchStatus: { _ in
                PairingInviteStatus(status: "pending", childDisplayName: nil,
                                    deviceLabel: nil, resolution: nil)
            }
        ))

        // .task re-runs whenever SwiftUI rebuilds the step, and publishing the
        // stage is itself a reason to rebuild — unguarded this minted eight
        // invites in four seconds, each invalidating the visible code.
        await model.mint(purpose: .newChild, target: nil)
        await model.mint(purpose: .newChild, target: nil)
        await model.mint(purpose: .newChild, target: nil)

        XCTAssertEqual(mints, 1)
        model.stopPolling()
    }

    func test_parentInviteStage_mapsPendingJoinedAndExpired() {
        let invite = PairingInviteCreated(
            inviteID: UUID(), codeDisplay: "483920",
            qrPayload: "evlin-invite:v2:tok", expiresAt: Date()
        )
        let pending = PairingInviteStatus(status: "pending", childDisplayName: nil,
                                          deviceLabel: nil, resolution: nil)
        XCTAssertEqual(ParentInviteModel.stage(for: pending, showing: invite),
                       .showing(invite))

        let joined = PairingInviteStatus(status: "joined", childDisplayName: "Kid",
                                         deviceLabel: "Kid's iPad",
                                         resolution: "restore")
        XCTAssertEqual(
            ParentInviteModel.stage(for: joined, showing: invite),
            .joined(childName: "Kid", deviceLabel: "Kid's iPad",
                    resolution: "restore")
        )

        let expired = PairingInviteStatus(status: "expired", childDisplayName: nil,
                                          deviceLabel: nil, resolution: nil)
        XCTAssertEqual(ParentInviteModel.stage(for: expired, showing: invite),
                       .expired)
    }

    func test_joinedInviteStatusDecodesTheChildDeviceNeededByParentWait() throws {
        let childDeviceID = UUID()
        let data = """
        {"status":"joined","child_device_id":"\(childDeviceID.uuidString)",
         "child_display_name":"Kid","device_label":"Kid's iPad",
         "resolution":"invited"}
        """.data(using: .utf8)!

        let status = try JSONDecoder.pairingV2.decode(
            PairingInviteStatus.self,
            from: data
        )

        XCTAssertEqual(status.childDeviceID, childDeviceID)
    }

    @MainActor
    func test_parentInvitePollingHandsTheJoinedDeviceToItsCoordinator() async {
        let familyID = UUID()
        let childDeviceID = UUID()
        let joined = expectation(description: "joined callback")
        let invite = PairingInviteCreated(
            inviteID: UUID(),
            codeDisplay: "483920",
            qrPayload: "evlin-invite:v2:tok",
            expiresAt: Date().addingTimeInterval(600)
        )
        let model = ParentInviteModel(
            api: ParentInviteAPI(
                ensureFamily: { familyID },
                createInvite: { _, _ in invite },
                fetchStatus: { _ in
                    PairingInviteStatus(
                        status: "joined",
                        childDisplayName: "Kid",
                        deviceLabel: "Kid's iPad",
                        resolution: "invited",
                        childDeviceID: childDeviceID
                    )
                }
            ),
            pollInterval: .milliseconds(1)
        )
        model.onJoined = { identity in
            XCTAssertEqual(identity.familyID, familyID)
            XCTAssertEqual(identity.childDeviceID, childDeviceID)
            joined.fulfill()
        }

        await model.mint(purpose: .newChild, target: nil)
        model.startPolling(invite: invite)

        await fulfillment(of: [joined], timeout: 0.5)
        model.stopPolling()
    }

    // MARK: - install_id migration

    func test_installIDMigration_keychainWinsWhenItAlreadyHasAValue() {
        let existing = UUID().uuidString
        let kept = InstallIDKeychainMigration.migrate(
            legacyValue: UUID().uuidString,
            keychainRead: { existing },
            keychainWrite: { _ in
                XCTFail("must not overwrite the established identity")
                return false
            },
            deleteLegacy: {},
            stashLegacy: { _ in }
        )
        XCTAssertEqual(kept, existing)
    }

    func test_installIDMigration_movesAValidLegacyValueAndDropsTheSource() {
        var stored: String?
        var legacyDeleted = false
        let legacy = UUID().uuidString

        let migrated = InstallIDKeychainMigration.migrate(
            legacyValue: legacy,
            keychainRead: { stored },
            keychainWrite: { stored = $0; return true },
            deleteLegacy: { legacyDeleted = true },
            stashLegacy: { _ in XCTFail("success path must not stash") }
        )

        XCTAssertEqual(migrated, legacy)
        XCTAssertEqual(stored, legacy)
        XCTAssertTrue(legacyDeleted)
    }

    func test_installIDMigration_mintsAFreshIDWhenTheLegacyValueIsMalformed() {
        var stored: String?
        let migrated = InstallIDKeychainMigration.migrate(
            legacyValue: "not-a-uuid",
            keychainRead: { stored },
            keychainWrite: { stored = $0; return true },
            deleteLegacy: {},
            stashLegacy: { _ in }
        )
        XCTAssertNotNil(UUID(uuidString: migrated))
        XCTAssertNotEqual(migrated, "not-a-uuid")
        XCTAssertEqual(stored, migrated)
    }

    func test_installIDMigration_keepsTheSourceWhenTheKeychainWriteFails() {
        var stashed: String?
        let survivor = UUID().uuidString

        let result = InstallIDKeychainMigration.migrate(
            legacyValue: survivor,
            keychainRead: { nil },
            keychainWrite: { _ in false },
            deleteLegacy: {
                XCTFail("a failed write must never drop the only copy")
            },
            stashLegacy: { stashed = $0 }
        )

        XCTAssertEqual(result, survivor)
        // Next launch retries with the same value instead of minting a new one.
        XCTAssertEqual(stashed, survivor)
    }

    func test_commitResult_decodesCredentialAlongsideIdentity() throws {
        let deviceID = UUID()
        let json = """
        {"family_id":"\(UUID())","child_device_id":"\(deviceID)",
         "child_profile_id":"\(UUID())","mode":"invited",
         "device_credential":{"scheme":"x-child-id-v1",
                              "child_device_id":"\(deviceID)"}}
        """.data(using: .utf8)!
        let result = try JSONDecoder().decode(PairingCommitResult.self, from: json)
        XCTAssertEqual(result.mode, "invited")
        XCTAssertEqual(result.deviceCredential.scheme, "x-child-id-v1")
        XCTAssertEqual(result.deviceCredential.childDeviceID, result.childDeviceID)
    }
}
