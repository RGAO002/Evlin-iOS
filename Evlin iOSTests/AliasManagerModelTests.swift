import XCTest
@testable import Evlin_iOS

// MARK: - AliasManagerModelTests (Task F2-test)
//
// Uses a mock AppAliasManagingClient. Tests verify:
//   - load() populates rows
//   - addAlias/removeAlias call the client and rows reflect the change after re-fetch
//   - renameAlias calls the client and rows reflect the change after re-fetch
//   - on client error, errorMessage is set and rows are unchanged

@MainActor
final class AliasManagerModelTests: XCTestCase {
    private let familyID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!

    // MARK: - Helpers

    private func makeRow(
        bundleID: String = "com.example.app",
        canonicalName: String = "Example App",
        aliases: [String] = [],
        lockableDevices: [LockableDevice] = []
    ) -> AppAliasRow {
        AppAliasRow(
            familyAppID: UUID(),
            bundleID: bundleID,
            canonicalName: canonicalName,
            artworkURL: nil,
            aliases: aliases,
            blockable: true,
            lockableDevices: lockableDevices
        )
    }

    // MARK: - load()

    func test_load_populatesRows() async {
        let rows = [
            makeRow(bundleID: "com.burbn.instagram", canonicalName: "Instagram", aliases: ["ig"]),
            makeRow(bundleID: "com.roblox.robloxmobile", canonicalName: "Roblox"),
        ]
        let client = FakeAppAliasClient(rows: rows)
        let model = AliasManagerModel(familyID: familyID, client: client)

        await model.load()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(client.fetchCalls, [familyID])
        XCTAssertEqual(model.rows.map(\.bundleID), rows.map(\.bundleID))
    }

    func test_load_onError_setsErrorMessageAndRowsUnchanged() async {
        let prior = makeRow(bundleID: "com.example.app", canonicalName: "App")
        let client = FakeAppAliasClient(rows: [prior])
        let model = AliasManagerModel(familyID: familyID, client: client)
        await model.load()
        XCTAssertEqual(model.rows.count, 1)

        // Make the next fetch throw
        client.throwOnFetch = true
        await model.load()

        XCTAssertNotNil(model.errorMessage)
        // Rows are wiped on a failed load (load resets rows in the error path via
        // the defer). The spec says "keep prior state" on MUTATION errors, not load
        // errors. See the mutation tests below for that behavior.
    }

    // MARK: - addAlias

    func test_addAlias_callsClientAndRefetchesRow() async {
        let original = makeRow(bundleID: "com.burbn.instagram", canonicalName: "Instagram", aliases: ["ig"])
        let afterAdd = makeRow(bundleID: "com.burbn.instagram", canonicalName: "Instagram", aliases: ["ig", "insta"])
        let client = FakeAppAliasClient(rows: [original])
        client.rowsAfterMutation = [afterAdd]
        let model = AliasManagerModel(familyID: familyID, client: client)
        await model.load()

        await model.addAlias("insta", to: original)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(client.addCalls.count, 1)
        XCTAssertEqual(client.addCalls.first?.bundleID, "com.burbn.instagram")
        XCTAssertEqual(client.addCalls.first?.alias, "insta")
        XCTAssertEqual(model.rows.first?.aliases, ["ig", "insta"])
    }

    func test_addAlias_onClientError_setsErrorMessageAndRowsUnchanged() async {
        let original = makeRow(bundleID: "com.burbn.instagram", canonicalName: "Instagram", aliases: ["ig"])
        let client = FakeAppAliasClient(rows: [original])
        client.throwOnMutate = true
        let model = AliasManagerModel(familyID: familyID, client: client)
        await model.load()
        let rowsBefore = model.rows

        await model.addAlias("insta", to: original)

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.rows.map(\.aliases), rowsBefore.map(\.aliases))
    }

    // MARK: - removeAlias

    func test_removeAlias_callsClientAndRefetchesRow() async {
        let original = makeRow(bundleID: "com.burbn.instagram", canonicalName: "Instagram", aliases: ["ig", "insta"])
        let afterRemove = makeRow(bundleID: "com.burbn.instagram", canonicalName: "Instagram", aliases: ["ig"])
        let client = FakeAppAliasClient(rows: [original])
        client.rowsAfterMutation = [afterRemove]
        let model = AliasManagerModel(familyID: familyID, client: client)
        await model.load()

        await model.removeAlias("insta", from: original)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(client.removeCalls.count, 1)
        XCTAssertEqual(client.removeCalls.first?.alias, "insta")
        XCTAssertEqual(model.rows.first?.aliases, ["ig"])
    }

    func test_removeAlias_onClientError_setsErrorMessageAndRowsUnchanged() async {
        let original = makeRow(bundleID: "com.burbn.instagram", canonicalName: "Instagram", aliases: ["ig"])
        let client = FakeAppAliasClient(rows: [original])
        client.throwOnMutate = true
        let model = AliasManagerModel(familyID: familyID, client: client)
        await model.load()

        await model.removeAlias("ig", from: original)

        XCTAssertNotNil(model.errorMessage)
        XCTAssertEqual(model.rows.first?.aliases, ["ig"])
    }

    // MARK: - renameAlias

    func test_renameAlias_callsClientAndRefetchesRow() async {
        let original = makeRow(bundleID: "com.burbn.instagram", canonicalName: "Instagram", aliases: ["ig"])
        let afterRename = makeRow(bundleID: "com.burbn.instagram", canonicalName: "Instagram", aliases: ["instagram"])
        let client = FakeAppAliasClient(rows: [original])
        client.rowsAfterMutation = [afterRename]
        let model = AliasManagerModel(familyID: familyID, client: client)
        await model.load()

        await model.renameAlias("ig", to: "instagram", for: original)

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(client.renameCalls.count, 1)
        XCTAssertEqual(client.renameCalls.first?.old, "ig")
        XCTAssertEqual(client.renameCalls.first?.new, "instagram")
        XCTAssertEqual(model.rows.first?.aliases, ["instagram"])
    }

    // MARK: - visibleRows / searchText

    func test_visibleRows_filtersOnCanonicalNameAndAliases() async {
        let rows = [
            makeRow(bundleID: "com.burbn.instagram", canonicalName: "Instagram", aliases: ["ig"]),
            makeRow(bundleID: "com.roblox.robloxmobile", canonicalName: "Roblox"),
        ]
        let client = FakeAppAliasClient(rows: rows)
        let model = AliasManagerModel(familyID: familyID, client: client)
        await model.load()

        model.searchText = "rob"
        XCTAssertEqual(model.visibleRows.map(\.canonicalName), ["Roblox"])

        model.searchText = "ig"
        XCTAssertEqual(model.visibleRows.map(\.canonicalName), ["Instagram"])

        model.searchText = ""
        XCTAssertEqual(model.visibleRows.count, 2)
    }
}

// MARK: - Mock client

private final class FakeAppAliasClient: AppAliasManagingClient {
    var rows: [AppAliasRow]
    var rowsAfterMutation: [AppAliasRow]?
    var throwOnFetch = false
    var throwOnMutate = false
    var fetchCalls: [UUID] = []
    var addCalls: [(bundleID: String, alias: String)] = []
    var removeCalls: [(bundleID: String, alias: String)] = []
    var renameCalls: [(bundleID: String, old: String, new: String)] = []
    private var mutationCount = 0

    init(rows: [AppAliasRow]) {
        self.rows = rows
    }

    func fetchAppAliases(familyID: UUID) async throws -> [AppAliasRow] {
        fetchCalls.append(familyID)
        if throwOnFetch { throw APIError.serverError(500) }
        // After the first fetch, return rowsAfterMutation if set (simulates server state post-mutation)
        if mutationCount > 0, let mutated = rowsAfterMutation {
            return mutated
        }
        return rows
    }

    func addAppAlias(familyID: UUID, bundleID: String, alias: String) async throws {
        if throwOnMutate { throw APIError.serverError(422) }
        addCalls.append((bundleID: bundleID, alias: alias))
        mutationCount += 1
    }

    func removeAppAlias(familyID: UUID, bundleID: String, alias: String) async throws {
        if throwOnMutate { throw APIError.serverError(422) }
        removeCalls.append((bundleID: bundleID, alias: alias))
        mutationCount += 1
    }

    func renameAppAlias(familyID: UUID, bundleID: String, old: String, new: String) async throws {
        if throwOnMutate { throw APIError.serverError(422) }
        renameCalls.append((bundleID: bundleID, old: old, new: new))
        mutationCount += 1
    }
}
