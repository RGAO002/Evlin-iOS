import Foundation
import XCTest
@testable import Evlin_iOS

final class BigKidParentClientTests: XCTestCase {
    override func tearDown() {
        BigKidParentClientURLProtocol.responseData = nil
        BigKidParentClientURLProtocol.capturedRequest = nil
        BigKidParentClientURLProtocol.capturedBody = nil
        super.tearDown()
    }

    func testUpdateTaskSendsPatchRequestBody() async throws {
        let taskId = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        BigKidParentClientURLProtocol.responseData = """
        {
          "id": "\(taskId.uuidString)",
          "title": "Read chapter",
          "description": "Read chapter 4 and write two notes",
          "category": "Homework",
          "due": "Tomorrow, 7:00 PM",
          "status": "todo",
          "phase": "input",
          "redo_reason": null,
          "evidence_photo_urls": [],
          "evidence_note": null,
          "bypass": null
        }
        """.data(using: .utf8)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BigKidParentClientURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let client = BigKidParentClient(
            baseURL: URL(string: "http://localhost:8000/api/v1")!,
            session: session
        )

        let updated = try await client.updateTask(
            taskId: taskId,
            title: "Read chapter",
            description: "Read chapter 4 and write two notes",
            category: .homework,
            due: "Tomorrow, 7:00 PM"
        )

        let request = try XCTUnwrap(BigKidParentClientURLProtocol.capturedRequest)
        XCTAssertEqual(request.httpMethod, "PATCH")
        XCTAssertEqual(
            request.url?.absoluteString,
            "http://localhost:8000/api/v1/parent/task/\(taskId.uuidString)"
        )

        let bodyData = try XCTUnwrap(BigKidParentClientURLProtocol.capturedBody)
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bodyData) as? [String: String]
        )
        XCTAssertEqual(body["title"], "Read chapter")
        XCTAssertEqual(body["description"], "Read chapter 4 and write two notes")
        XCTAssertEqual(body["category"], "Homework")
        XCTAssertEqual(body["due"], "Tomorrow, 7:00 PM")

        XCTAssertEqual(updated.title, "Read chapter")
        XCTAssertEqual(updated.description, "Read chapter 4 and write two notes")
        XCTAssertEqual(updated.category, .homework)
    }
}

private final class BigKidParentClientURLProtocol: URLProtocol {
    static var responseData: Data?
    static var capturedRequest: URLRequest?
    static var capturedBody: Data?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.capturedRequest = request
        Self.capturedBody = request.httpBody ?? readBodyStream(request.httpBodyStream)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData ?? Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func readBodyStream(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let count = stream.read(buffer, maxLength: bufferSize)
            if count > 0 {
                data.append(buffer, count: count)
            } else {
                break
            }
        }
        return data
    }
}
