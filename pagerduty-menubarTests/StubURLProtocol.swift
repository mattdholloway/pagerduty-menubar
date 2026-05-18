import Foundation

/// URLProtocol that returns canned responses keyed by URL path matching.
final class StubURLProtocol: URLProtocol {
    struct Response {
        let status: Int
        let body: Data
        let headers: [String: String]
        init(status: Int = 200, body: Data, headers: [String: String] = ["Content-Type": "application/json"]) {
            self.status = status; self.body = body; self.headers = headers
        }
    }

    /// (path, query-matcher) -> Response. The matcher is called with the full
    /// URLComponents; returning true means "use this response".
    typealias Matcher = (URLComponents) -> Bool
    nonisolated(unsafe) static var responders: [(Matcher, Response)] = []
    nonisolated(unsafe) static var capturedRequests: [URLRequest] = []
    static let queue = DispatchQueue(label: "stub-url-protocol")

    static func reset() {
        queue.sync {
            responders = []
            capturedRequests = []
        }
    }

    static func register(_ matcher: @escaping Matcher, response: Response) {
        queue.sync { responders.append((matcher, response)) }
    }

    static func capturedURLs() -> [URL] {
        queue.sync { capturedRequests.compactMap(\.url) }
    }

    static func capturedHeaders() -> [[String: String]] {
        queue.sync {
            capturedRequests.map { req in
                Dictionary(uniqueKeysWithValues: (req.allHTTPHeaderFields ?? [:]).map { ($0.key, $0.value) })
            }
        }
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.queue.sync { Self.capturedRequests.append(self.request) }
        guard let url = request.url,
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let match = Self.queue.sync { Self.responders.first { $0.0(comps) }?.1 }
        guard let response = match else {
            let err = URLError(.fileDoesNotExist, userInfo: [NSLocalizedDescriptionKey: "No stub matched \(url.absoluteString)"])
            client?.urlProtocol(self, didFailWithError: err)
            return
        }
        let http = HTTPURLResponse(
            url: url,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headers
        )!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

extension URLSession {
    static func stubbed() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubURLProtocol.self] + (cfg.protocolClasses ?? [])
        return URLSession(configuration: cfg)
    }
}
