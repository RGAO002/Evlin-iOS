import XCTest
@testable import Evlin_iOS

final class ChildEditFormMappingTests: XCTestCase {

    func test_createBody_maps_age_to_birth_year() {
        let body = ChildCRUDMapper.createBody(name: "Sam", age: 8, referenceYear: 2026)
        XCTAssertEqual(body.display_name, "Sam")
        XCTAssertEqual(body.birth_year, 2018)            // 2026 - 8
        XCTAssertNil(body.child_device_id)
    }

    func test_updateBody_maps_name_and_age() {
        let body = ChildCRUDMapper.updateBody(name: "Sam", age: 10, referenceYear: 2026)
        XCTAssertEqual(body.display_name, "Sam")
        XCTAssertEqual(body.birth_year, 2016)            // 2026 - 10
    }

    func test_deleteError_409_is_paired_device_message() {
        let msg = ChildCRUDMapper.deleteErrorMessage(for: APIError.serverError(409))
        XCTAssertTrue(msg.lowercased().contains("paired device"),
                      "409 must explain a linked device blocks deletion, got: \(msg)")
    }

    func test_deleteError_other_is_generic() {
        let msg = ChildCRUDMapper.deleteErrorMessage(for: APIError.serverError(500))
        XCTAssertFalse(msg.lowercased().contains("paired device"))
        XCTAssertFalse(msg.isEmpty)
    }
}
