// Evlin iOSTests/LazyTagTests.swift
import XCTest
@testable import Evlin_iOS

final class LazyTagCatalogModelTests: XCTestCase {
    private let appID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let categoryID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let listID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    func test_sectionsAlwaysAppearInAppCategoryListOrder() {
        let targets: [LazyTagCatalogTarget] = [
            .init(aliasKey: listID, type: .list, displayName: "Entertainment", aliases: ["fun"], memberCount: 3),
            .init(aliasKey: appID, type: .app, displayName: "Instagram", aliases: ["ig"], bundleID: "com.burbn.instagram", artworkURL: URL(string: "https://example.com/ig.png"), isManual: false),
            .init(aliasKey: categoryID, type: .category, displayName: "Games", aliases: ["gaming"])
        ]

        let sections = LazyTagCatalogModel.sections(from: targets, searchText: "")

        XCTAssertEqual(sections.map(\.type), [.app, .category, .list])
        XCTAssertEqual(sections.map(\.title), ["App", "Category", "List"])
        XCTAssertEqual(sections[0].targets.map(\.displayName), ["Instagram"])
        XCTAssertEqual(sections[1].targets.map(\.displayName), ["Games"])
        XCTAssertEqual(sections[2].targets.map(\.displayName), ["Entertainment"])
    }

    func test_sectionSearchMatchesDisplayNameAndAliasesWithoutDroppingSections() {
        let targets: [LazyTagCatalogTarget] = [
            .init(aliasKey: appID, type: .app, displayName: "Instagram", aliases: ["ig"]),
            .init(aliasKey: categoryID, type: .category, displayName: "Games", aliases: ["gaming"]),
            .init(aliasKey: listID, type: .list, displayName: "Entertainment", aliases: ["weekend"])
        ]

        let sections = LazyTagCatalogModel.sections(from: targets, searchText: "ig")

        XCTAssertEqual(sections.map(\.type), [.app, .category, .list])
        XCTAssertEqual(sections[0].targets.map(\.displayName), ["Instagram"])
        XCTAssertEqual(sections[1].targets, [])
        XCTAssertEqual(sections[2].targets, [])
    }

    func test_categorySubtitleUsesBroadCoverageCopy() {
        let target = LazyTagCatalogTarget(
            aliasKey: categoryID,
            type: .category,
            displayName: "Games",
            aliases: []
        )

        XCTAssertEqual(target.supportingText, "Current + future apps Apple classifies as Games")
    }

    func test_filteredCatalogWithNoCandidatesShowsInformOnlyCopyInsteadOfPickableRows() {
        let presentation = LazyTagCatalogModel.presentation(
            targets: [
                .init(aliasKey: appID, type: .app, displayName: "Instagram", aliases: ["ig"]),
                .init(aliasKey: categoryID, type: .category, displayName: "Games", aliases: ["gaming"]),
                .init(aliasKey: listID, type: .list, displayName: "Entertainment", aliases: ["weekend"])
            ],
            searchText: "抖音",
            unresolvedName: "抖音"
        )

        XCTAssertTrue(presentation.isInformOnly)
        XCTAssertEqual(
            presentation.informMessage,
            "抖音 isn’t in your kid’s list yet. Add it on their phone, or try block `抖音`."
        )
        XCTAssertEqual(presentation.sections.map(\.type), [.app, .category, .list])
        XCTAssertTrue(presentation.sections.allSatisfy { $0.targets.isEmpty })
    }

    func test_nonEmptyCatalogIsPickableNotInformOnly() {
        let presentation = LazyTagCatalogModel.presentation(
            targets: [.init(aliasKey: appID, type: .app, displayName: "Instagram", aliases: ["ig"])],
            searchText: "",
            unresolvedName: "ig"
        )

        XCTAssertFalse(presentation.isInformOnly)
        XCTAssertNil(presentation.informMessage)
    }

    func test_appStoreSearchRunsLiveAfterTwoCharactersWithAppMatchDebounce() {
        XCTAssertFalse(AppStoreSearchPresentation.shouldRunLiveSearch(for: ""))
        XCTAssertFalse(AppStoreSearchPresentation.shouldRunLiveSearch(for: "x"))
        XCTAssertTrue(AppStoreSearchPresentation.shouldRunLiveSearch(for: "ig"))
        XCTAssertTrue(AppStoreSearchPresentation.shouldRunLiveSearch(for: "抖音"))
        XCTAssertEqual(AppStoreSearchPresentation.liveSearchDebounceNanoseconds, 250_000_000)
    }

    // MARK: - Lock-setup save rules (Task 10, Step 3)

    func test_reservedCategoryWords_includeCanonicalKeys() {
        let reserved = LockSetupSaveRules.reservedCategoryWords
        XCTAssertTrue(reserved.contains("games"))
        XCTAssertTrue(reserved.contains("social"))
        XCTAssertTrue(reserved.contains("entertainment"))
        XCTAssertTrue(reserved.contains("education"))
        XCTAssertTrue(reserved.contains("productivity"))
    }

    func test_isReservedCategoryWord_isCaseAndWhitespaceInsensitive() {
        XCTAssertTrue(LockSetupSaveRules.isReservedCategoryWord("Games"))
        XCTAssertTrue(LockSetupSaveRules.isReservedCategoryWord("  SOCIAL  "))
        XCTAssertTrue(LockSetupSaveRules.isReservedCategoryWord("entertainment"))
        XCTAssertFalse(LockSetupSaveRules.isReservedCategoryWord("Homework"))
        XCTAssertFalse(LockSetupSaveRules.isReservedCategoryWord("after school"))
    }

    func test_validateListName_rejectsEmpty() {
        XCTAssertEqual(LockSetupSaveRules.validateListName("", existingNames: []), .empty)
        XCTAssertEqual(LockSetupSaveRules.validateListName("   ", existingNames: []), .empty)
    }

    func test_validateListName_rejectsReservedCategoryWord() {
        XCTAssertEqual(
            LockSetupSaveRules.validateListName("Games", existingNames: []),
            .reservedCategoryWord
        )
        XCTAssertEqual(
            LockSetupSaveRules.validateListName("  social  ", existingNames: []),
            .reservedCategoryWord
        )
    }

    func test_validateListName_rejectsDuplicateCaseInsensitively() {
        XCTAssertEqual(
            LockSetupSaveRules.validateListName("Homework", existingNames: ["homework"]),
            .duplicate
        )
        XCTAssertEqual(
            LockSetupSaveRules.validateListName("  Bedtime ", existingNames: ["BEDTIME"]),
            .duplicate
        )
    }

    func test_validateListName_acceptsCleanName() {
        XCTAssertEqual(
            LockSetupSaveRules.validateListName("After School", existingNames: ["homework"]),
            .valid
        )
    }

    func test_validateListName_isValidConvenienceMatchesValidCase() {
        XCTAssertTrue(LockSetupSaveRules.isValidListName("After School", existingNames: []))
        XCTAssertFalse(LockSetupSaveRules.isValidListName("games", existingNames: []))
        XCTAssertFalse(LockSetupSaveRules.isValidListName("", existingNames: []))
    }

    func test_appRowIsLabeled_requiresNonEmptyDisplayName() {
        XCTAssertFalse(LockSetupSaveRules.appRowIsLabeled(displayName: ""))
        XCTAssertFalse(LockSetupSaveRules.appRowIsLabeled(displayName: "   "))
        XCTAssertTrue(LockSetupSaveRules.appRowIsLabeled(displayName: "Instagram"))
    }

    func test_hasUnlabeledRows_detectsBlankNames() {
        XCTAssertTrue(LockSetupSaveRules.hasUnlabeledAppRows(displayNames: ["Instagram", ""]))
        XCTAssertTrue(LockSetupSaveRules.hasUnlabeledAppRows(displayNames: ["   "]))
        XCTAssertFalse(LockSetupSaveRules.hasUnlabeledAppRows(displayNames: ["Instagram", "TikTok"]))
        XCTAssertFalse(LockSetupSaveRules.hasUnlabeledAppRows(displayNames: []))
    }

    func test_appTargetIsSaveable_whenFamilyDictionaryConfirmed() {
        XCTAssertTrue(
            LockSetupSaveRules.appTargetIsSaveable(
                displayName: "Instagram",
                isFamilyDictionaryConfirmed: true,
                manualBundleID: nil
            )
        )
    }

    func test_appTargetIsSaveable_whenExplicitManualBundleID() {
        XCTAssertTrue(
            LockSetupSaveRules.appTargetIsSaveable(
                displayName: "Some App",
                isFamilyDictionaryConfirmed: false,
                manualBundleID: "com.example.app"
            )
        )
    }

    func test_appTargetNotSaveable_whenNeitherConfirmedNorManual() {
        XCTAssertFalse(
            LockSetupSaveRules.appTargetIsSaveable(
                displayName: "Mystery App",
                isFamilyDictionaryConfirmed: false,
                manualBundleID: nil
            )
        )
        XCTAssertFalse(
            LockSetupSaveRules.appTargetIsSaveable(
                displayName: "Mystery App",
                isFamilyDictionaryConfirmed: false,
                manualBundleID: "   "
            )
        )
    }

    func test_appTargetNotSaveable_whenUnlabeled() {
        XCTAssertFalse(
            LockSetupSaveRules.appTargetIsSaveable(
                displayName: "",
                isFamilyDictionaryConfirmed: true,
                manualBundleID: "com.example.app"
            )
        )
    }

    func test_categoryTargetIsSaveable_requiresToken() {
        XCTAssertTrue(LockSetupSaveRules.categoryTargetIsSaveable(hasCategoryToken: true))
        XCTAssertFalse(LockSetupSaveRules.categoryTargetIsSaveable(hasCategoryToken: false))
    }

    func test_listIsSaveable_acceptsMixedAppAndCategoryMembers() {
        XCTAssertTrue(
            LockSetupSaveRules.listIsSaveable(
                name: "After School",
                existingNames: [],
                appMemberCount: 2,
                categoryMemberCount: 1
            )
        )
        XCTAssertTrue(
            LockSetupSaveRules.listIsSaveable(
                name: "Just Categories",
                existingNames: [],
                appMemberCount: 0,
                categoryMemberCount: 1
            )
        )
    }

    func test_listNotSaveable_whenNoMembers() {
        XCTAssertFalse(
            LockSetupSaveRules.listIsSaveable(
                name: "Empty",
                existingNames: [],
                appMemberCount: 0,
                categoryMemberCount: 0
            )
        )
    }

    func test_listNotSaveable_whenNameInvalid() {
        XCTAssertFalse(
            LockSetupSaveRules.listIsSaveable(
                name: "games",
                existingNames: [],
                appMemberCount: 3,
                categoryMemberCount: 0
            )
        )
    }

    // MARK: - Task 11: app-control card parse + option→action routing

    /// Mirror of the backend `_app_control_card_response` payload for
    /// single_app_shield_advice.
    private func singleAppShieldAdvicePayload() -> [String: Any] {
        [
            "card_id": "single_app_shield_advice",
            "type": "single_app_shield_advice",
            "title": "Block is more reliable",
            "body": "Shielding a single app like Instagram can be unreliable.",
            "target_display": "Instagram",
            "target_kind": "app",
            "bundle_id": "com.burbn.instagram",
            "child_device_id": "22222222-2222-2222-2222-222222222222",
            "options": [
                ["action": "block_now", "label": "Block Instagram", "force_confirmations": ["block_now"]],
                ["action": "shield_anyway", "label": "Shield anyway", "force_confirmations": ["shield_anyway"]],
            ],
            "candidates": [],
        ]
    }

    func test_appControlCard_parsesSingleAppShieldAdvice() {
        let model = AppControlCardModel.parse(
            cardID: "single_app_shield_advice",
            payload: singleAppShieldAdvicePayload()
        )
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.kind, .singleAppShieldAdvice)
        XCTAssertEqual(model?.title, "Block is more reliable")
        XCTAssertEqual(model?.targetDisplay, "Instagram")
        XCTAssertEqual(model?.targetKind, "app")
        XCTAssertEqual(model?.bundleID, "com.burbn.instagram")
        XCTAssertEqual(model?.childDeviceID, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(model?.options.map(\.action), ["block_now", "shield_anyway"])
    }

    func test_appControlCard_parseReturnsNilForBrainCardId() {
        // HARD BOUNDARY: a Brain/verb-table id must NOT parse as an app-control
        // card, so the existing renderCard path keeps handling it.
        XCTAssertNil(AppControlCardModel.parse(cardID: "U1", payload: [:]))
        XCTAssertNil(AppControlCardModel.parse(cardID: "D4", payload: [:]))
        XCTAssertNil(AppControlCardModel.parse(cardID: "B1", payload: [:]))
    }

    func test_appControlCard_allSixIdsAreRecognised() {
        let ids = [
            "single_app_shield_advice", "shield_token_missing",
            "app_store_disambiguation", "app_not_found_terminal",
            "child_disambiguation", "category_rename_required",
        ]
        for id in ids {
            XCTAssertNotNil(
                AppControlCardKind(rawValue: id),
                "Expected \(id) to be a recognised app-control card kind"
            )
        }
    }

    func test_appControlRouting_blockNowResendsForceConfirmation() {
        let model = AppControlCardModel.parse(
            cardID: "single_app_shield_advice",
            payload: singleAppShieldAdvicePayload()
        )!
        let blockOption = model.options.first { $0.action == "block_now" }!
        XCTAssertEqual(
            AppControlRouter.route(option: blockOption, card: model),
            .resendForceConfirmations(["single_app_shield_advice:block_now"])
        )
    }

    func test_appControlRouting_shieldAnywayResendsForceConfirmation() {
        let model = AppControlCardModel.parse(
            cardID: "single_app_shield_advice",
            payload: singleAppShieldAdvicePayload()
        )!
        let shieldOption = model.options.first { $0.action == "shield_anyway" }!
        XCTAssertEqual(
            AppControlRouter.route(option: shieldOption, card: model),
            .resendForceConfirmations(["single_app_shield_advice:shield_anyway"])
        )
    }

    func test_appControlRouting_openLazyTagOpensPickerWithTarget() {
        let payload: [String: Any] = [
            "card_id": "shield_token_missing",
            "type": "shield_token_missing",
            "title": "Re-add this on the kid's phone",
            "body": "I can't shield Roblox yet.",
            "target_display": "Roblox",
            "target_kind": "app",
            "options": [["action": "open_lazy_tag", "label": "Pick the app to re-capture"]],
        ]
        let model = AppControlCardModel.parse(cardID: "shield_token_missing", payload: payload)!
        let opt = model.options[0]
        XCTAssertEqual(
            AppControlRouter.route(option: opt, card: model),
            .openLazyTag(target: "Roblox", kind: .app)
        )
    }

    func test_appControlRouting_openLazyTagUsesCategoryKindWhenCategoryTarget() {
        let payload: [String: Any] = [
            "card_id": "app_not_found_terminal",
            "type": "app_not_found_terminal",
            "title": "I couldn't find that app",
            "body": "No match.",
            "target_display": "games",
            "target_kind": "category",
            "options": [["action": "open_lazy_tag", "label": "Add it on the kid's phone"]],
        ]
        let model = AppControlCardModel.parse(cardID: "app_not_found_terminal", payload: payload)!
        XCTAssertEqual(
            AppControlRouter.route(option: model.options[0], card: model),
            .openLazyTag(target: "games", kind: .category)
        )
    }

    func test_appControlRouting_appNotFoundSearchOptionOpensAppSearch() {
        let payload: [String: Any] = [
            "card_id": "app_not_found_terminal",
            "type": "app_not_found_terminal",
            "title": "I couldn't find that app",
            "body": "No match.",
            "target_display": "be real",
            "target_kind": "app",
            "options": [
                ["action": "open_app_search", "label": "Search App Store"],
                ["action": "open_lazy_tag", "label": "Add it on the kid's phone"],
            ],
        ]
        let model = AppControlCardModel.parse(cardID: "app_not_found_terminal", payload: payload)!
        XCTAssertEqual(
            AppControlRouter.route(option: model.options[0], card: model),
            .openAppSearch(query: "be real")
        )
    }

    func test_appControlRouting_renameListSurfacesRenameGuidance() {
        let payload: [String: Any] = [
            "card_id": "category_rename_required",
            "type": "category_rename_required",
            "title": "Rename this list first",
            "body": "Your list name collides with a category.",
            "target_display": "games",
            "target_kind": "list",
            "options": [["action": "rename_list", "label": "Rename list"]],
        ]
        let model = AppControlCardModel.parse(cardID: "category_rename_required", payload: payload)!
        XCTAssertEqual(
            AppControlRouter.route(option: model.options[0], card: model),
            .renameList(target: "games")
        )
    }

    func test_appControlRouting_childDisambiguationCandidateScopesToChild() {
        let payload: [String: Any] = [
            "card_id": "child_disambiguation",
            "type": "child_disambiguation",
            "title": "Which child?",
            "body": "You have more than one kid device.",
            "target_display": "Instagram",
            "target_kind": "app",
            "options": [],
            "candidates": [
                ["display": "Liam", "child_device_id": "11111111-1111-1111-1111-111111111111", "target_type": "app"],
                ["display": "Maya", "child_device_id": "22222222-2222-2222-2222-222222222222", "target_type": "app"],
            ],
        ]
        let model = AppControlCardModel.parse(cardID: "child_disambiguation", payload: payload)!
        XCTAssertEqual(model.candidates.count, 2)
        XCTAssertEqual(
            AppControlRouter.route(candidate: model.candidates[0], card: model),
            .resendPhrase("Liam's phone")
        )
    }

    func test_appControlRouting_appStoreDisambiguationCandidateReplaysDisplay() {
        let payload: [String: Any] = [
            "card_id": "app_store_disambiguation",
            "type": "app_store_disambiguation",
            "title": "Which app do you mean?",
            "body": "I found a few apps.",
            "target_display": "messenger",
            "target_kind": "app",
            "options": [],
            "candidates": [
                [
                    "display": "Facebook Messenger",
                    "bundle_id": "com.facebook.Messenger",
                    "artwork_url": "https://example.com/messenger.png",
                    "target_type": "app",
                ],
                ["display": "Messenger Kids", "bundle_id": "com.facebook.MessengerKids", "target_type": "app"],
            ],
        ]
        let model = AppControlCardModel.parse(cardID: "app_store_disambiguation", payload: payload)!
        XCTAssertEqual(model.candidates[0].artworkURL, URL(string: "https://example.com/messenger.png"))
        XCTAssertEqual(
            AppControlRouter.route(candidate: model.candidates[0], card: model),
            .confirmAppAndResend(
                candidateDisplay: "Facebook Messenger",
                bundleID: "com.facebook.Messenger",
                artworkURL: URL(string: "https://example.com/messenger.png")
            )
        )
        XCTAssertEqual(
            AppControlRouter.route(candidate: model.candidates[1], card: model),
            .confirmAppAndResend(
                candidateDisplay: "Messenger Kids",
                bundleID: "com.facebook.MessengerKids",
                artworkURL: nil
            )
        )
    }

    func test_appControlRouting_appStoreCandidateStripsStoreSubtitleBeforeReplay() {
        let payload: [String: Any] = [
            "card_id": "app_store_disambiguation",
            "type": "app_store_disambiguation",
            "title": "Which app do you mean?",
            "body": "I found a few apps.",
            "target_display": "ttok",
            "target_kind": "app",
            "options": [],
            "candidates": [
                [
                    "display": "TikTok - Videos, Shop & LIVE",
                    "bundle_id": "com.zhiliaoapp.musically",
                    "target_type": "app",
                ],
            ],
        ]
        let model = AppControlCardModel.parse(cardID: "app_store_disambiguation", payload: payload)!

        XCTAssertEqual(
            AppControlRouter.route(candidate: model.candidates[0], card: model),
            .confirmAppAndResend(
                candidateDisplay: "TikTok",
                bundleID: "com.zhiliaoapp.musically",
                artworkURL: nil
            )
        )
        XCTAssertEqual(
            AppControlRouter.rewriteOriginalCommand(
                "lock ttok",
                replacing: "ttok",
                with: "TikTok - Videos, Shop & LIVE"
            ),
            "lock TikTok"
        )
    }

    func test_appControlRouting_openAppSearchOptionUsesOriginalTarget() {
        let payload: [String: Any] = [
            "card_id": "app_store_disambiguation",
            "type": "app_store_disambiguation",
            "title": "Which app do you mean?",
            "body": "I found a few apps.",
            "target_display": "fb",
            "target_kind": "app",
            "options": [["action": "open_app_search", "label": "Not in the list"]],
            "candidates": [
                ["display": "Facebook", "bundle_id": "com.facebook.Facebook", "target_type": "app"],
            ],
        ]
        let model = AppControlCardModel.parse(cardID: "app_store_disambiguation", payload: payload)!
        XCTAssertEqual(
            AppControlRouter.route(option: model.options[0], card: model),
            .openAppSearch(query: "fb")
        )
    }

    func test_appControlRouting_appStoreDisambiguationPreservesOriginalCommand() {
        XCTAssertEqual(
            AppControlRouter.rewriteOriginalCommand(
                "Lock cat quest for 15 mins",
                replacing: "Cat Quest",
                with: "Cat Quest III"
            ),
            "Lock Cat Quest III for 15 mins"
        )
        XCTAssertEqual(
            AppControlRouter.rewriteOriginalCommand(
                "lock ig",
                replacing: "ig",
                with: "Instagram"
            ),
            "lock Instagram"
        )
        XCTAssertEqual(
            AppControlRouter.rewriteOriginalCommand(
                "shield map",
                replacing: "map",
                with: "Google Maps"
            ),
            "shield Google Maps"
        )
    }

    func test_appControlRouting_unknownOptionActionIsNoOp() {
        let payload: [String: Any] = [
            "card_id": "app_not_found_terminal",
            "type": "app_not_found_terminal",
            "title": "x", "body": "y",
            "target_display": "z", "target_kind": "app",
            "options": [["action": "totally_unknown_verb", "label": "Huh"]],
        ]
        let model = AppControlCardModel.parse(cardID: "app_not_found_terminal", payload: payload)!
        XCTAssertEqual(
            AppControlRouter.route(option: model.options[0], card: model),
            AppControlAction.none
        )
    }

    // MARK: - Four new app-control cards (backend commit 93a0b6a)

    /// Mirror of the backend `cannot_block_category` / `category_shield_offer`
    /// payload: a shield_anyway option carrying force_confirmations, then a
    /// plain cancel option with none.
    private func categoryShieldPayload(cardID: String) -> [String: Any] {
        [
            "card_id": cardID,
            "type": cardID,
            "title": "Shield the whole category?",
            "body": "I can't hard-block a category, but I can shield it.",
            "target_display": "Games",
            "target_kind": "category",
            "options": [
                ["action": "shield_anyway", "label": "Shield anyway", "force_confirmations": ["shield_anyway"]],
                ["action": "cancel", "label": "Cancel"],
            ],
            "candidates": [],
        ]
    }

    /// Mirror of the backend `catalog_app_inactive` / `bundle_id_required`
    /// payload: a single open_lazy_tag option, app target.
    private func openLazyTagAppPayload(cardID: String) -> [String: Any] {
        [
            "card_id": cardID,
            "type": cardID,
            "title": "Re-capture this app",
            "body": "I need the kid's phone to tag this app.",
            "target_display": "Roblox",
            "target_kind": "app",
            "options": [["action": "open_lazy_tag", "label": "Open the picker"]],
            "candidates": [],
        ]
    }

    func test_appControlCard_parsesCannotBlockCategory() {
        let model = AppControlCardModel.parse(
            cardID: "cannot_block_category",
            payload: categoryShieldPayload(cardID: "cannot_block_category")
        )
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.kind, .cannotBlockCategory)
        XCTAssertEqual(model?.targetKind, "category")
        XCTAssertEqual(model?.options.map(\.action), ["shield_anyway", "cancel"])
        XCTAssertEqual(model?.options.first?.forceConfirmations, ["shield_anyway"])
        XCTAssertEqual(model?.options.last?.forceConfirmations, [])
    }

    func test_appControlCard_parsesCategoryShieldOffer() {
        let model = AppControlCardModel.parse(
            cardID: "category_shield_offer",
            payload: categoryShieldPayload(cardID: "category_shield_offer")
        )
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.kind, .categoryShieldOffer)
        XCTAssertEqual(model?.targetKind, "category")
        XCTAssertEqual(model?.options.map(\.action), ["shield_anyway", "cancel"])
    }

    func test_appControlCard_parsesCatalogAppInactive() {
        let model = AppControlCardModel.parse(
            cardID: "catalog_app_inactive",
            payload: openLazyTagAppPayload(cardID: "catalog_app_inactive")
        )
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.kind, .catalogAppInactive)
        XCTAssertEqual(model?.targetKind, "app")
        XCTAssertEqual(model?.options.map(\.action), ["open_lazy_tag"])
    }

    func test_appControlCard_parsesBundleIDRequired() {
        let model = AppControlCardModel.parse(
            cardID: "bundle_id_required",
            payload: openLazyTagAppPayload(cardID: "bundle_id_required")
        )
        XCTAssertNotNil(model)
        XCTAssertEqual(model?.kind, .bundleIDRequired)
        XCTAssertEqual(model?.targetKind, "app")
        XCTAssertEqual(model?.options.map(\.action), ["open_lazy_tag"])
    }

    func test_appControlCard_fourNewIdsAreRecognised() {
        let ids = [
            "cannot_block_category", "category_shield_offer",
            "catalog_app_inactive", "bundle_id_required",
        ]
        for id in ids {
            XCTAssertNotNil(
                AppControlCardKind(rawValue: id),
                "Expected \(id) to be a recognised app-control card kind"
            )
        }
    }

    func test_appControlRouting_categoryShieldAnywayResendsForceConfirmation() {
        let model = AppControlCardModel.parse(
            cardID: "category_shield_offer",
            payload: categoryShieldPayload(cardID: "category_shield_offer")
        )!
        let shield = model.options.first { $0.action == "shield_anyway" }!
        XCTAssertEqual(
            AppControlRouter.route(option: shield, card: model),
            .resendForceConfirmations(["category_shield_offer:shield_anyway"])
        )
    }

    func test_appControlRouting_cancelOptionIsNoOp() {
        let model = AppControlCardModel.parse(
            cardID: "cannot_block_category",
            payload: categoryShieldPayload(cardID: "cannot_block_category")
        )!
        let cancel = model.options.first { $0.action == "cancel" }!
        XCTAssertTrue(cancel.forceConfirmations.isEmpty)
        XCTAssertEqual(
            AppControlRouter.route(option: cancel, card: model),
            AppControlAction.none
        )
    }

    func test_appControlRouting_catalogAppInactiveOpenLazyTagUsesAppKind() {
        let model = AppControlCardModel.parse(
            cardID: "catalog_app_inactive",
            payload: openLazyTagAppPayload(cardID: "catalog_app_inactive")
        )!
        XCTAssertEqual(
            AppControlRouter.route(option: model.options[0], card: model),
            .openLazyTag(target: "Roblox", kind: .app)
        )
    }

    func test_appControlRouting_bundleIDRequiredOpenLazyTagUsesAppKind() {
        let model = AppControlCardModel.parse(
            cardID: "bundle_id_required",
            payload: openLazyTagAppPayload(cardID: "bundle_id_required")
        )!
        XCTAssertEqual(
            AppControlRouter.route(option: model.options[0], card: model),
            .openLazyTag(target: "Roblox", kind: .app)
        )
    }

    func test_appControlCard_parseReturnsNilForUnknownCardId() {
        // HARD BOUNDARY: an unknown id (not one of the ten app-control ids)
        // must NOT parse, so the Brain fall-through stays intact.
        XCTAssertNil(AppControlCardModel.parse(cardID: "totally_made_up_card", payload: [:]))
    }
}

final class LazyTagPersistenceTests: XCTestCase {
    func test_normalizedAlias_trimsAliasBeforeBackendSave() {
        let result = LazyTagPersistence.normalizedAlias("  抖音  ")
        switch result {
        case .success(let alias): XCTAssertEqual(alias, "抖音")
        case .failure: XCTFail("expected trimmed alias")
        }
    }

    func test_persistCatalogAlias_rejectsMissingFamilyBeforeNetwork() async {
        let target = LazyTagCatalogTarget(
            aliasKey: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            type: .app,
            displayName: "TikTok"
        )

        let result = await LazyTagPersistence.persistCatalogAlias(
            target: target,
            requestedAlias: "抖音",
            familyID: nil,
            childDeviceID: UUID()
        )

        switch result {
        case .failure(let err): XCTAssertEqual(err, .missingFamily)
        case .success: XCTFail("expected missingFamily failure")
        }
    }

    func test_persistCatalogAlias_rejectsMissingChildDeviceBeforeNetwork() async {
        let target = LazyTagCatalogTarget(
            aliasKey: UUID(uuidString: "DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD")!,
            type: .app,
            displayName: "TikTok"
        )

        let result = await LazyTagPersistence.persistCatalogAlias(
            target: target,
            requestedAlias: "抖音",
            familyID: UUID(),
            childDeviceID: nil
        )

        switch result {
        case .failure(let err): XCTAssertEqual(err, .missingChildDevice)
        case .success: XCTFail("expected missingChildDevice failure")
        }
    }

    /// Passing a non-token Any (e.g. String) for `.app` mode must produce
    /// `.wrongTokenType`. We can't mint real ApplicationToken in tests
    /// (FamilyControls auth is unavailable), so we test only the
    /// type-mismatch branch — the success branch is covered by manual E2E.
    func test_persistAlias_rejectsWrongTypeForApp() {
        let result = LazyTagPersistence.persistAlias(
            token: "not a token" as Any,
            kind: .app,
            target: "Instagram"
        )
        switch result {
        case .failure(let err): XCTAssertEqual(err, .wrongTokenType)
        case .success: XCTFail("expected wrongTokenType failure")
        }
    }

    func test_persistAlias_rejectsWrongTypeForCategory() {
        let result = LazyTagPersistence.persistAlias(
            token: 42 as Any,
            kind: .category,
            target: "games"
        )
        switch result {
        case .failure(let err): XCTAssertEqual(err, .wrongTokenType)
        case .success: XCTFail("expected wrongTokenType failure")
        }
    }

    func test_persistAlias_rejectsEmptyTarget() {
        let result = LazyTagPersistence.persistAlias(
            token: "x" as Any,
            kind: .app,
            target: "   "
        )
        switch result {
        case .failure(let err): XCTAssertEqual(err, .emptyTarget)
        case .success: XCTFail("expected emptyTarget failure")
        }
    }
}

final class LazyTagUniversalFallbackTests: XCTestCase {
    /// Contract: a lazy-tag for an app can only bind a real ApplicationToken.
    /// Unit tests cannot mint FamilyControls tokens, so this pins the guard
    /// that prevents bad picker output from creating a false app binding.
    func test_appKind_requiresApplicationToken() {
        let result = LazyTagPersistence.persistAlias(
            token: 7 as Any,
            kind: .app,
            target: "Bilibili"
        )
        switch result {
        case .failure(let error): XCTAssertEqual(error, .wrongTokenType)
        case .success: XCTFail("expected wrongTokenType")
        }
    }

    /// Blank names must never be persisted as aliases; otherwise future
    /// natural-language locks could resolve to an invisible bad binding.
    func test_emptyTarget_isRejected_soCatalogNeverBindsBlankName() {
        let result = LazyTagPersistence.persistAlias(
            token: "x" as Any,
            kind: .app,
            target: " "
        )
        switch result {
        case .failure(let error): XCTAssertEqual(error, .emptyTarget)
        case .success: XCTFail("expected emptyTarget")
        }
    }
}

final class ExtractAliasTargetTests: XCTestCase {
    private func proposal(tool: String, args: [String: Any]) -> ProposalDTO {
        let typed = args.mapValues { AnyCodable($0) }
        return ProposalDTO(
            tool: tool,
            args: typed,
            label: "test",
            danger: "low",
            token: UUID().uuidString
        )
    }

    func test_returnsAppTarget_forShieldAppLegacy_withAppKind() {
        let p = proposal(tool: "shield_app_legacy", args: [
            "target": "Instagram",
            "target_kind": "app"
        ])
        let result = ChatViewModel.extractAliasTarget(from: p)
        XCTAssertEqual(result?.target, "Instagram")
        XCTAssertEqual(result?.kind, .app)
    }

    func test_returnsCategoryTarget_forShieldAppLegacy_withCategoryKind() {
        let p = proposal(tool: "shield_app_legacy", args: [
            "target": "games",
            "target_kind": "category"
        ])
        let result = ChatViewModel.extractAliasTarget(from: p)
        XCTAssertEqual(result?.target, "games")
        XCTAssertEqual(result?.kind, .category)
    }

    func test_returnsNil_forNonShieldTool() {
        let p = proposal(tool: "propose_reflection", args: [
            "target": "anything"
        ])
        XCTAssertNil(ChatViewModel.extractAliasTarget(from: p))
    }

    func test_returnsNil_whenTargetMissing() {
        let p = proposal(tool: "shield_app_legacy", args: [
            "target_kind": "app"
        ])
        XCTAssertNil(ChatViewModel.extractAliasTarget(from: p))
    }

    func test_returnsNil_forUnknownKind() {
        let p = proposal(tool: "shield_app_legacy", args: [
            "target": "x",
            "target_kind": "weird"
        ])
        XCTAssertNil(ChatViewModel.extractAliasTarget(from: p))
    }
}
