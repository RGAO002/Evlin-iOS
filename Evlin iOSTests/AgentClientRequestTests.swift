import XCTest
@testable import Evlin_iOS

final class AgentClientRequestTests: XCTestCase {
    private let client = AgentClient(baseURL: "https://api.example.com")

    func test_makeExecRequest_shape() throws {
        let req = try client.makeExecRequest(token: "tok123")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://api.example.com/parent/agent/exec")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(req.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(json["token"], "tok123")
    }

    func test_makeRevertRequest_shape() {
        let req = client.makeRevertRequest(actionID: "abc")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.url?.absoluteString, "https://api.example.com/parent/actions/abc/revert")
    }

    func test_attachBearer_addsAuthorizationHeader() throws {
        let req = try client.makeExecRequest(token: "tok123")
        let authed = AgentClient.attachBearer(req, accessToken: "acc-1")
        XCTAssertEqual(authed.value(forHTTPHeaderField: "Authorization"), "Bearer acc-1")
    }

    func test_attachBearer_nilOrEmptyToken_leavesRequestUnchanged() throws {
        let req = try client.makeExecRequest(token: "tok123")
        XCTAssertNil(AgentClient.attachBearer(req, accessToken: nil)
            .value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(AgentClient.attachBearer(req, accessToken: "")
            .value(forHTTPHeaderField: "Authorization"))
    }

    func test_targetResponseDecodesResumeChatDevice() throws {
        let data = Data("""
        {
          "ok": true,
          "resume_chat": {
            "message": "lock fb",
            "child_device_id": "22222222-2222-2222-2222-222222222222"
          }
        }
        """.utf8)

        let response = try JSONDecoder().decode(
            AgentClient.AgentCardResponse.self,
            from: data
        )

        XCTAssertEqual(response.resume_chat?.message, "lock fb")
        XCTAssertEqual(
            response.resume_chat?.child_device_id,
            "22222222-2222-2222-2222-222222222222"
        )
    }
}
