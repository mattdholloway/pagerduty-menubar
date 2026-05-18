import XCTest
@testable import pagerduty_menubar

final class PagerDutyAPITests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    private func makeAPI() -> PagerDutyAPI {
        PagerDutyAPI(session: .stubbed())
    }

    // MARK: - currentUser

    func test_currentUser_decodesUserAndTeams_andSendsAuthAndAcceptHeaders() async throws {
        let json = """
        {
          "user": {
            "id": "PXXX",
            "name": "Alice Smith",
            "email": "alice@example.com",
            "html_url": "https://example.pagerduty.com/users/PXXX",
            "teams": [{"id":"T1","summary":"Platform","type":"team_reference"}]
          }
        }
        """
        StubURLProtocol.register(
            { $0.path == "/users/me" },
            response: .init(body: Data(json.utf8))
        )
        let api = makeAPI()
        let user = try await api.currentUser(token: "tok")
        XCTAssertEqual(user.id, "PXXX")
        XCTAssertEqual(user.name, "Alice Smith")
        XCTAssertEqual(user.teams?.first?.id, "T1")

        let headers = StubURLProtocol.capturedHeaders().first ?? [:]
        XCTAssertEqual(headers["Authorization"], "Token token=tok")
        XCTAssertEqual(headers["Accept"], "application/vnd.pagerduty+json;version=2")

        // include[]=teams should be on the URL
        let url = StubURLProtocol.capturedURLs().first
        XCTAssertNotNil(url)
        XCTAssertTrue(url!.absoluteString.contains("include%5B%5D=teams"))
    }

    // MARK: - services pagination

    func test_services_paginatesUntilMoreIsFalse() async throws {
        // Two pages then stop
        let page1: [[String: Any]] = (0..<100).map { i in
            ["id": "S\(i)", "name": "svc\(i)", "escalation_policy": ["id":"EP1","summary":"EP1","type":"escalation_policy_reference"]]
        }
        let page2: [[String: Any]] = (0..<5).map { i in
            ["id": "S\(100+i)", "name": "svc\(100+i)", "escalation_policy": ["id":"EP1","summary":"EP1","type":"escalation_policy_reference"]]
        }
        let env1: [String: Any] = ["services": page1, "more": true, "offset": 0]
        let env2: [String: Any] = ["services": page2, "more": false, "offset": 100]
        StubURLProtocol.register(
            { $0.path == "/services" && ($0.queryItems?.first { $0.name == "offset" }?.value ?? "") == "0" },
            response: .init(body: try! JSONSerialization.data(withJSONObject: env1))
        )
        StubURLProtocol.register(
            { $0.path == "/services" && ($0.queryItems?.first { $0.name == "offset" }?.value ?? "") == "100" },
            response: .init(body: try! JSONSerialization.data(withJSONObject: env2))
        )
        let api = makeAPI()
        let services = try await api.services(token: "t", teamIDs: ["T1"])
        XCTAssertEqual(services.count, 105)
        XCTAssertEqual(services.first?.id, "S0")
        XCTAssertEqual(services.last?.id, "S104")
    }

    func test_services_emptyTeamIDsReturnsEmpty_withoutNetwork() async throws {
        let api = makeAPI()
        let services = try await api.services(token: "t", teamIDs: [])
        XCTAssertTrue(services.isEmpty)
        XCTAssertTrue(StubURLProtocol.capturedURLs().isEmpty)
    }

    // MARK: - escalation policies

    func test_allEscalationPolicies_decodesAndPaginates() async throws {
        let page1: [String: Any] = [
            "escalation_policies": (0..<100).map { ["id":"EP\($0)","name":"Policy \($0)","html_url":"https://example/EP\($0)"] },
            "more": true
        ]
        let page2: [String: Any] = [
            "escalation_policies": [["id":"EP100","name":"Last","html_url":NSNull()]],
            "more": false
        ]
        StubURLProtocol.register(
            { $0.path == "/escalation_policies" && ($0.queryItems?.first { $0.name == "offset" }?.value ?? "") == "0" },
            response: .init(body: try! JSONSerialization.data(withJSONObject: page1))
        )
        StubURLProtocol.register(
            { $0.path == "/escalation_policies" && ($0.queryItems?.first { $0.name == "offset" }?.value ?? "") == "100" },
            response: .init(body: try! JSONSerialization.data(withJSONObject: page2))
        )
        let api = makeAPI()
        let refs = try await api.allEscalationPolicies(token: "t")
        XCTAssertEqual(refs.count, 101)
        // summary should be 'name' from the API
        XCTAssertEqual(refs.first?.summary, "Policy 0")
        XCTAssertEqual(refs.last?.id, "EP100")
    }

    // MARK: - oncalls chunking + since/until

    func test_onCalls_chunksEPIDsBy25_andEncodesSinceUntil() async throws {
        let emptyEnv = #"{"oncalls":[],"more":false}"#
        StubURLProtocol.register(
            { $0.path == "/oncalls" },
            response: .init(body: Data(emptyEnv.utf8))
        )
        let ids = (0..<60).map { "EP\($0)" }
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let until = Date(timeIntervalSince1970: 1_700_086_400)
        let api = makeAPI()
        _ = try await api.onCalls(token: "t", escalationPolicyIDs: ids, since: since, until: until)

        // Should have made 3 chunk requests (25 + 25 + 10).
        let urls = StubURLProtocol.capturedURLs()
        XCTAssertEqual(urls.count, 3, "expected 3 chunked requests, got \(urls.count)")

        // Each URL must contain since= and until= encoded as ISO8601.
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let sinceStr = iso.string(from: since)
        let untilStr = iso.string(from: until)
        for url in urls {
            let s = url.absoluteString
            XCTAssertTrue(s.contains("since="), "missing since= in \(s)")
            XCTAssertTrue(s.contains("until="), "missing until= in \(s)")
            // The colons in ISO8601 are URL-encoded; check the date portion.
            XCTAssertTrue(s.contains(sinceStr.prefix(10)), "missing since date prefix")
            XCTAssertTrue(s.contains(untilStr.prefix(10)), "missing until date prefix")
        }

        // Each chunk should contain at most 25 escalation_policy_ids[]
        for url in urls {
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            let count = (comps.queryItems ?? []).filter { $0.name == "escalation_policy_ids[]" }.count
            XCTAssertLessThanOrEqual(count, 25)
            XCTAssertGreaterThan(count, 0)
        }
    }

    // MARK: - error mapping

    func test_httpError_isReportedWithStatusAndBodySnippet() async {
        StubURLProtocol.register(
            { $0.path == "/users/me" },
            response: .init(status: 401, body: Data(#"{"error":"Unauthorized"}"#.utf8))
        )
        let api = makeAPI()
        do {
            _ = try await api.currentUser(token: "bad")
            XCTFail("expected throw")
        } catch let PDError.http(code, msg) {
            XCTAssertEqual(code, 401)
            XCTAssertTrue(msg.contains("Unauthorized"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
