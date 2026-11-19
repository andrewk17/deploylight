import Foundation

struct FixtureResponse {
    var body = ""
    var status = 200
    var headers: [String: String] = [:]
}

final class FixtureHTTP: URLProtocol {
    private static let lock = NSLock()
    private static var handler: ((URLRequest) -> FixtureResponse)?
    private static var requests: [URLRequest] = []

    static func session(_ handler: @escaping (URLRequest) -> FixtureResponse) -> URLSession {
        lock.lock()
        self.handler = handler
        requests = []
        lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.protocolClasses = [self]
        return URLSession(configuration: configuration)
    }

    static func capturedRequests() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        let fixture = Self.handler?(request) ?? FixtureResponse(status: 500)
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: fixture.status, httpVersion: nil, headerFields: fixture.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(fixture.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
