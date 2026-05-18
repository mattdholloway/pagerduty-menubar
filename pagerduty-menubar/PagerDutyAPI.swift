import Foundation

// MARK: - Models

struct PDReference: Codable, Hashable, Identifiable {
    let id: String
    let summary: String?
    let html_url: String?
    let type: String?
}

struct PDUser: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let email: String?
    let html_url: String?
    let avatar_url: String?
    let time_zone: String?
    let teams: [PDReference]?
}

struct PDService: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let html_url: String?
    let status: String?
    let escalation_policy: PDReference?
    let teams: [PDReference]?
}

struct PDOnCall: Codable, Hashable {
    let escalation_policy: PDReference
    let escalation_level: Int
    let schedule: PDReference?
    let user: PDReference
    let start: Date?
    let end: Date?
}

// MARK: - API response envelopes

private struct UserEnvelope: Decodable { let user: PDUser }
private struct ServicesEnvelope: Decodable {
    let services: [PDService]
    let more: Bool?
    let offset: Int?
}
private struct EscalationPoliciesEnvelope: Decodable {
    struct EP: Decodable { let id: String; let name: String; let html_url: String? }
    let escalation_policies: [EP]
    let more: Bool?
}

private struct OnCallsEnvelope: Decodable {
    let oncalls: [PDOnCall]
    let more: Bool?
    let offset: Int?
}

// MARK: - Errors

enum PDError: LocalizedError {
    case missingToken
    case http(Int, String)
    case decoding(String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .missingToken: return "No PagerDuty API token set. Open Settings to add one."
        case .http(let code, let msg): return "PagerDuty API error \(code): \(msg)"
        case .decoding(let msg): return "Failed to decode response: \(msg)"
        case .transport(let msg): return "Network error: \(msg)"
        }
    }
}

// MARK: - Client

actor PagerDutyAPI {
    private let session: URLSession
    private let base = URL(string: "https://api.pagerduty.com")!
    private let decoder: JSONDecoder

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.default
            cfg.timeoutIntervalForRequest = 20
            cfg.waitsForConnectivity = true
            self.session = URLSession(configuration: cfg)
        }

        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let isoNoFrac = ISO8601DateFormatter()
            isoNoFrac.formatOptions = [.withInternetDateTime]
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = iso.date(from: s) ?? isoNoFrac.date(from: s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
        }
        self.decoder = d
    }

    // MARK: - Public endpoints

    func currentUser(token: String) async throws -> PDUser {
        let url = base.appending(path: "/users/me")
            .appending(queryItems: [URLQueryItem(name: "include[]", value: "teams")])
        let env: UserEnvelope = try await get(url: url, token: token)
        return env.user
    }

    func services(token: String, teamIDs: [String]) async throws -> [PDService] {
        if teamIDs.isEmpty { return [] }
        var all: [PDService] = []
        var offset = 0
        let limit = 100
        while true {
            var items: [URLQueryItem] = [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
                URLQueryItem(name: "include[]", value: "escalation_policies"),
                URLQueryItem(name: "include[]", value: "teams"),
            ]
            items.append(contentsOf: teamIDs.map { URLQueryItem(name: "team_ids[]", value: $0) })
            let url = base.appending(path: "/services").appending(queryItems: items)
            let env: ServicesEnvelope = try await get(url: url, token: token)
            all.append(contentsOf: env.services)
            if env.more == true { offset += limit } else { break }
            if offset > 1000 { break } // safety
        }
        return all
    }

    /// All escalation policies on the account (paginated). Used to surface
    /// 'Other policies' the user isn't directly associated with.
    func allEscalationPolicies(token: String) async throws -> [PDReference] {
        var all: [PDReference] = []
        var offset = 0
        let limit = 100
        while true {
            let items: [URLQueryItem] = [
                URLQueryItem(name: "limit", value: String(limit)),
                URLQueryItem(name: "offset", value: String(offset)),
            ]
            let url = base.appending(path: "/escalation_policies").appending(queryItems: items)
            let env: EscalationPoliciesEnvelope = try await get(url: url, token: token)
            for ep in env.escalation_policies {
                all.append(PDReference(id: ep.id, summary: ep.name, html_url: ep.html_url, type: "escalation_policy_reference"))
            }
            if env.more == true { offset += limit } else { break }
            if offset > 5000 { break }
        }
        return all
    }

    func onCalls(token: String, escalationPolicyIDs: [String], since: Date? = nil, until: Date? = nil) async throws -> [PDOnCall] {
        if escalationPolicyIDs.isEmpty { return [] }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        var all: [PDOnCall] = []
        for chunk in escalationPolicyIDs.chunked(into: 25) {
            var offset = 0
            let limit = 100
            while true {
                var items: [URLQueryItem] = [
                    URLQueryItem(name: "limit", value: String(limit)),
                    URLQueryItem(name: "offset", value: String(offset)),
                    URLQueryItem(name: "earliest", value: "false"),
                    URLQueryItem(name: "include[]", value: "users"),
                ]
                if let since { items.append(URLQueryItem(name: "since", value: iso.string(from: since))) }
                if let until { items.append(URLQueryItem(name: "until", value: iso.string(from: until))) }
                items.append(contentsOf: chunk.map { URLQueryItem(name: "escalation_policy_ids[]", value: $0) })
                let url = base.appending(path: "/oncalls").appending(queryItems: items)
                let env: OnCallsEnvelope = try await get(url: url, token: token)
                all.append(contentsOf: env.oncalls)
                if env.more == true { offset += limit } else { break }
                if offset > 2000 { break }
            }
        }
        return all
    }

    // MARK: - Internal

    private func get<T: Decodable>(url: URL, token: String) async throws -> T {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/vnd.pagerduty+json;version=2", forHTTPHeaderField: "Accept")
        req.setValue("Token token=\(token)", forHTTPHeaderField: "Authorization")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw PDError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw PDError.transport("Non-HTTP response")
        }
        guard (200...299).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let snippet = body.count > 200 ? String(body.prefix(200)) + "…" : body
            throw PDError.http(http.statusCode, snippet)
        }
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            throw PDError.decoding(String(describing: error))
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
