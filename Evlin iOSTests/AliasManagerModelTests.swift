import XCTest
@testable import Evlin_iOS

@MainActor
final class AliasManagerModelTests: XCTestCase {
    private let familyID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let childDeviceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let appID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
    private let categoryID = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
    private let listID = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!

    func test_loadGroupsBackendCatalogTargetsIntoAppCategoryListSections() async {
        let client = FakeAliasManagerClient(targets: [
            .init(aliasKey: listID, type: .list, displayName: "Entertainment", aliases: ["fun"], memberCount: 3),
            .init(aliasKey: categoryID, type: .category, displayName: "Games", aliases: ["gaming"]),
            .init(aliasKey: appID, type: .app, displayName: "Instagram", aliases: ["ig"], bundleID: "com.burbn.instagram"),
        ])
        let model = AliasManagerModel(
            familyID: familyID,
            childDeviceID: childDeviceID,
            client: client
        )

        await model.load()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(client.fetches, [childDeviceID])
        XCTAssertEqual(model.sections.map(\.type), [.app, .category, .list])
        XCTAssertEqual(model.sections[0].targets.map(\.displayName), ["Instagram"])
        XCTAssertEqual(model.sections[1].targets.map(\.displayName), ["Games"])
        XCTAssertEqual(model.sections[2].targets.map(\.displayName), ["Entertainment"])
    }

    func test_addAndRemoveAliasRoundTripThroughBackendAndUpdateTargetInPlace() async {
        let original = LazyTagCatalogTarget(
            aliasKey: appID,
            type: .app,
            displayName: "Instagram",
            aliases: ["ig"],
            bundleID: "com.burbn.instagram"
        )
        let client = FakeAliasManagerClient(targets: [original])
        client.saveResult = LazyTagCatalogTarget(
            aliasKey: appID,
            type: .app,
            displayName: "Instagram",
            aliases: ["ig", "insta"],
            bundleID: "com.burbn.instagram"
        )
        client.removeResult = original
        let model = AliasManagerModel(
            familyID: familyID,
            childDeviceID: childDeviceID,
            client: client
        )
        await model.load()

        await model.addAlias(" insta ", to: original)

        XCTAssertEqual(client.savedAliases, [" insta "])
        XCTAssertEqual(model.targets.first?.aliases, ["ig", "insta"])

        await model.removeAlias("insta", from: model.targets[0])

        XCTAssertEqual(client.removedAliases, ["insta"])
        XCTAssertEqual(model.targets.first?.aliases, ["ig"])
    }
}

private final class FakeAliasManagerClient: AliasManagingClient {
    var targets: [LazyTagCatalogTarget]
    var fetches: [UUID] = []
    var savedAliases: [String] = []
    var removedAliases: [String] = []
    var saveResult: LazyTagCatalogTarget?
    var removeResult: LazyTagCatalogTarget?

    init(targets: [LazyTagCatalogTarget]) {
        self.targets = targets
    }

    func fetchLazyTagCatalogTargets(
        childDeviceID: UUID,
        query: String?
    ) async throws -> [LazyTagCatalogTarget] {
        fetches.append(childDeviceID)
        return targets
    }

    func saveLazyTagAlias(
        familyID: UUID,
        childDeviceID: UUID,
        target: LazyTagCatalogTarget,
        alias: String
    ) async throws -> LazyTagCatalogTarget {
        savedAliases.append(alias)
        return saveResult ?? target
    }

    func removeLazyTagAlias(
        familyID: UUID,
        childDeviceID: UUID,
        target: LazyTagCatalogTarget,
        alias: String
    ) async throws -> LazyTagCatalogTarget {
        removedAliases.append(alias)
        return removeResult ?? target
    }
}
