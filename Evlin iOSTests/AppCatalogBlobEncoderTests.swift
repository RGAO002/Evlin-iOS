import XCTest
@testable import Evlin_iOS

final class AppCatalogBlobEncoderTests: XCTestCase {

    /// Stand-in for a FamilyControls token: a Codable value the encoder must
    /// handle the same way. We cannot mint a real ApplicationToken in tests.
    private struct FakeToken: Codable, Equatable {
        let id: String
        let when: Date
    }

    func test_encodeBase64_isNonEmptyAndValidBase64() throws {
        let blob = try AppCatalogBlobEncoder.base64(FakeToken(id: "abc", when: Date(timeIntervalSince1970: 100)))
        XCTAssertFalse(blob.isEmpty)
        XCTAssertNotNil(Data(base64Encoded: blob))
    }

    func test_encodeBase64_roundTripsThroughJSON() throws {
        let original = FakeToken(id: "tiktok", when: Date(timeIntervalSince1970: 1_700_000_000))
        let blob = try AppCatalogBlobEncoder.base64(original)
        let data = try XCTUnwrap(Data(base64Encoded: blob))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(FakeToken.self, from: data)
        XCTAssertEqual(back, original)
    }

    func test_usesISO8601Dates_matchingLocalAliasStore() throws {
        let blob = try AppCatalogBlobEncoder.base64(FakeToken(id: "x", when: Date(timeIntervalSince1970: 0)))
        let json = String(data: try XCTUnwrap(Data(base64Encoded: blob)), encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("1970-01-01T00:00:00Z"), "expected ISO8601 date, got: \(json)")
    }

    func test_encode_twoDistinctValues_produceDistinctBlobs() throws {
        let a = try AppCatalogBlobEncoder.base64(FakeToken(id: "a", when: Date(timeIntervalSince1970: 1)))
        let b = try AppCatalogBlobEncoder.base64(FakeToken(id: "b", when: Date(timeIntervalSince1970: 1)))
        XCTAssertNotEqual(a, b)
    }
}
