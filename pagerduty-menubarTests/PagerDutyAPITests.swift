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

// MARK: - Incidents

extension PagerDutyAPITests {

    func test_incidents_encodesStatuses_andServiceIDs_andPaginates() async throws {
        // Two pages.
        let page1: [String: Any] = [
            "incidents": (0..<100).map { i -> [String: Any] in
                [
                    "id": "I\(i)",
                    "incident_number": 1000 + i,
                    "title": "Incident \(i)",
                    "status": i % 2 == 0 ? "triggered" : "acknowledged",
                    "urgency": "high",
                    "created_at": "2026-05-18T12:00:00Z",
                    "service": ["id": "S1", "summary": "Web", "type": "service_reference"],
                    "assignments": [["at": "2026-05-18T12:00:00Z", "assignee": ["id":"U1","summary":"Alice","type":"user_reference"]]],
                    "html_url": "https://example/I\(i)"
                ]
            },
            "more": true,
        ]
        let page2: [String: Any] = ["incidents": [], "more": false]
        StubURLProtocol.register(
            { $0.path == "/incidents" && ($0.queryItems?.first { $0.name == "offset" }?.value ?? "") == "0" },
            response: .init(body: try! JSONSerialization.data(withJSONObject: page1))
        )
        StubURLProtocol.register(
            { $0.path == "/incidents" && ($0.queryItems?.first { $0.name == "offset" }?.value ?? "") == "100" },
            response: .init(body: try! JSONSerialization.data(withJSONObject: page2))
        )
        let api = PagerDutyAPI(session: .stubbed())
        let list = try await api.incidents(token: "t", serviceIDs: ["S1"], statuses: ["triggered", "acknowledged"])
        XCTAssertEqual(list.count, 100)
        XCTAssertEqual(list.first?.id, "I0")

        // Verify the encoded query items on the first request.
        let url = StubURLProtocol.capturedURLs().first!
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let statuses = (comps.queryItems ?? []).filter { $0.name == "statuses[]" }.map(\.value)
        XCTAssertEqual(Set(statuses.compactMap { $0 }), Set(["triggered", "acknowledged"]))
        XCTAssertTrue((comps.queryItems ?? []).contains { $0.name == "service_ids[]" && $0.value == "S1" })
        XCTAssertTrue((comps.queryItems ?? []).contains { $0.name == "sort_by" && $0.value == "created_at:desc" })
    }

    func test_updateIncident_sendsFromHeader_andStatusPayload() async throws {
        let respJSON: [String: Any] = [
            "incident": [
                "id": "I42",
                "incident_number": 42,
                "title": "Test",
                "status": "acknowledged",
                "urgency": "high"
            ]
        ]
        StubURLProtocol.register(
            { $0.path == "/incidents/I42" },
            response: .init(body: try! JSONSerialization.data(withJSONObject: respJSON))
        )
        let api = PagerDutyAPI(session: .stubbed())
        let updated = try await api.updateIncident(token: "t", id: "I42", status: "acknowledged", from: "alice@example.com")
        XCTAssertEqual(updated.id, "I42")
        XCTAssertEqual(updated.status, "acknowledged")

        let req = StubURLProtocol.capturedHeaders().first ?? [:]
        XCTAssertEqual(req["From"], "alice@example.com")
        XCTAssertEqual(req["Content-Type"], "application/json")
        XCTAssertEqual(req["Accept"], "application/vnd.pagerduty+json;version=2")
    }
}

// MARK: - ETag + rate limit

extension PagerDutyAPITests {

    func test_etag_isReturnedOnFirstCallAndSentOnSecond() async throws {
        let body = #"{"user":{"id":"PXXX","name":"Alice","email":null,"html_url":null,"avatar_url":null,"time_zone":null,"teams":null}}"#
        StubURLProtocol.register(
            { $0.path == "/users/me" },
            response: .init(status: 200, body: Data(body.utf8),
                            headers: ["Content-Type": "application/json", "ETag": "W/\"abc123\""])
        )
        let api = PagerDutyAPI(session: .stubbed())
        _ = try await api.currentUser(token: "t")

        // Second call must send the cached ETag back via If-None-Match.
        // Register a fresh 304 stub so the call succeeds and reuses cache.
        StubURLProtocol.register(
            { $0.path == "/users/me" },
            response: .init(status: 304, body: Data(),
                            headers: ["ETag": "W/\"abc123\""])
        )
        _ = try await api.currentUser(token: "t")

        let secondHeaders = StubURLProtocol.capturedHeaders().dropFirst().first ?? [:]
        XCTAssertEqual(secondHeaders["If-None-Match"], "W/\"abc123\"")
    }

    func test_rateLimit_429setsBlockedWindow_andSecondCallShortCircuits() async throws {
        // First request: 429 with Retry-After=1.
        StubURLProtocol.register(
            { $0.path == "/users/me" },
            response: .init(status: 429, body: Data("{}".utf8),
                            headers: ["Retry-After": "1"])
        )
        let api = PagerDutyAPI(session: .stubbed())
        do {
            _ = try await api.currentUser(token: "t")
            XCTFail("expected rateLimited error")
        } catch let PDError.rateLimited(retry) {
            XCTAssertGreaterThan(retry, 0)
        } catch {
            XCTFail("wrong error: \(error)")
        }

        // Second immediate request should be short-circuited (still in the
        // block window), so we shouldn't even hit the network.
        let before = StubURLProtocol.capturedURLs().count
        do {
            _ = try await api.currentUser(token: "t")
            XCTFail("expected rateLimited error")
        } catch PDError.rateLimited {
            XCTAssertEqual(StubURLProtocol.capturedURLs().count, before, "no new request should have been made while blocked")
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }

    func test_rateLimitHeaders_areRecordedAfterSuccess() async throws {
        let body = #"{"user":{"id":"PXXX","name":"Alice","email":null,"html_url":null,"avatar_url":null,"time_zone":null,"teams":null}}"#
        StubURLProtocol.register(
            { $0.path == "/users/me" },
            response: .init(status: 200, body: Data(body.utf8),
                            headers: ["Content-Type": "application/json",
                                      "X-RateLimit-Remaining": "42",
                                      "X-RateLimit-Reset": "30"])
        )
        let api = PagerDutyAPI(session: .stubbed())
        _ = try await api.currentUser(token: "t")
        let snapshot = await api.lastRateLimit
        XCTAssertEqual(snapshot?.remaining, 42)
        XCTAssertNotNil(snapshot?.reset)
    }
}

extension PagerDutyAPITests {

    func test_concurrentRequests_areCoalesced_intoSingleNetworkCall() async throws {
        let body = #"{"user":{"id":"PXXX","name":"Alice","email":null,"html_url":null,"avatar_url":null,"time_zone":null,"teams":null}}"#
        StubURLProtocol.register(
            { $0.path == "/users/me" },
            response: .init(status: 200, body: Data(body.utf8))
        )
        let api = PagerDutyAPI(session: .stubbed())
        // Fire 5 concurrent identical requests.
        async let a = api.currentUser(token: "t")
        async let b = api.currentUser(token: "t")
        async let c = api.currentUser(token: "t")
        async let d = api.currentUser(token: "t")
        async let e = api.currentUser(token: "t")
        _ = try await (a, b, c, d, e)
        XCTAssertEqual(StubURLProtocol.capturedURLs().count, 1, "concurrent identical GETs should coalesce")
    }
}
