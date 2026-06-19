import XCTest
@testable import Evlin_iOS

final class CombinedPickerValidatorTests: XCTestCase {
    func test_empty_isInvalid() {
        XCTAssertEqual(CombinedPickerValidator.validate(SelectionCounts(applicationTokens: 0, categoryTokens: 0, webDomainTokens: 0)).reason, .empty)
    }
    func test_webDomain_isInvalid() {
        XCTAssertEqual(CombinedPickerValidator.validate(SelectionCounts(applicationTokens: 1, categoryTokens: 0, webDomainTokens: 1)).reason, .webNotSupported)
    }
    func test_appsAndCategoriesMixed_isValid() {
        XCTAssertTrue(CombinedPickerValidator.validate(SelectionCounts(applicationTokens: 2, categoryTokens: 1, webDomainTokens: 0)).isValid)
    }
    func test_singleCategoryOnly_isValid() {
        XCTAssertTrue(CombinedPickerValidator.validate(SelectionCounts(applicationTokens: 0, categoryTokens: 1, webDomainTokens: 0)).isValid)
    }
}
