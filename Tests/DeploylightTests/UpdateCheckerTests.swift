import XCTest
@testable import Deploylight

private final class ReleaseProtocol: URLProtocol {
    static var response = #"{"tag_name":"v0.10.0","prerelease":false,"draft":false}"#
    static var status = 200
    static var requests: [URLRequest] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests.append(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.response.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class UpdateCheckerTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let suite = "DeploylightUpdateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func checker(version: String = "0.4.0", userDefaults: UserDefaults? = nil) -> UpdateChecker {
        ReleaseProtocol.response = #"{"tag_name":"v0.10.0","prerelease":false,"draft":false}"#
        ReleaseProtocol.status = 200
        ReleaseProtocol.requests = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReleaseProtocol.self]
        return UpdateChecker(version: version, session: URLSession(configuration: configuration), userDefaults: userDefaults ?? defaults())
    }

    func testStableReleaseCheckIsUnauthenticatedDailyAndCanBeDisabled() async {
        let checker = checker()
        let now = Date()
        await checker.checkIfDue(enabled: true, now: now)?.value
        XCTAssertEqual(checker.available?.version.tag, "v0.10.0")
        XCTAssertEqual(checker.available?.url.absoluteString, "https://github.com/andrewk17/deploylight/releases/tag/v0.10.0")
        XCTAssertEqual(ReleaseProtocol.requests.count, 1)
        XCTAssertEqual(ReleaseProtocol.requests[0].url?.absoluteString, "https://api.github.com/repos/andrewk17/deploylight/releases/latest")
        XCTAssertNil(ReleaseProtocol.requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(ReleaseProtocol.requests[0].value(forHTTPHeaderField: "User-Agent"), "Deploylight-Update-Check")
        XCTAssertLessThanOrEqual(ReleaseProtocol.requests[0].timeoutInterval, 10)
        XCTAssertNil(checker.checkIfDue(enabled: true, now: now.addingTimeInterval(3600)))
        await checker.checkIfDue(enabled: true, now: now.addingTimeInterval(86400))?.value
        XCTAssertEqual(ReleaseProtocol.requests.count, 2)
        checker.checkIfDue(enabled: false)
        XCTAssertNil(checker.available)
        XCTAssertNil(checker.checkIfDue(enabled: false, now: now.addingTimeInterval(172800)))
        XCTAssertEqual(ReleaseProtocol.requests.count, 2)
    }

    func testOldEqualPrereleaseAndInvalidResponsesAreIgnored() async {
        for tag in ["v0.3.9", "v0.4.0", "v0.5.0-beta.1", "invalid"] {
            let checker = checker()
            ReleaseProtocol.response = "{\"tag_name\":\"\(tag)\",\"prerelease\":false,\"draft\":false}"
            await checker.checkIfDue(enabled: true)?.value
            XCTAssertNil(checker.available)
        }
        for body in [#"{"tag_name":"v1.0.0","prerelease":true,"draft":false}"#,
                     #"{"tag_name":"v1.0.0","prerelease":false,"draft":true}"#, "not json"] {
            let checker = checker()
            ReleaseProtocol.response = body
            await checker.checkIfDue(enabled: true)?.value
            XCTAssertNil(checker.available)
        }
        let failed = checker()
        ReleaseProtocol.status = 403
        await failed.checkIfDue(enabled: true)?.value
        XCTAssertNil(failed.available)
        XCTAssertNil(failed.checkIfDue(enabled: true))
    }

    func testDailyThrottleSurvivesRelaunchIncludingFailedChecks() async {
        for status in [200, 403] {
            let defaults = defaults()
            let first = checker(userDefaults: defaults)
            ReleaseProtocol.status = status
            let now = Date()
            await first.checkIfDue(enabled: true, now: now)?.value
            XCTAssertNotNil(defaults.object(forKey: UpdateChecker.lastAttemptKey))
            let relaunched = checker(userDefaults: defaults)
            XCTAssertNil(relaunched.checkIfDue(enabled: true, now: now.addingTimeInterval(3600)))
            XCTAssertTrue(ReleaseProtocol.requests.isEmpty)
            await relaunched.checkIfDue(enabled: true, now: now.addingTimeInterval(86400))?.value
            XCTAssertEqual(ReleaseProtocol.requests.count, 1)
        }
    }

    func testSemanticComparisonUsesNumbers() {
        XCTAssertLessThan(ReleaseVersion("v0.9.9")!, ReleaseVersion("0.10.0")!)
        XCTAssertEqual(ReleaseVersion("1.2.3+build"), ReleaseVersion("v1.2.3"))
        for invalid in ["1.2", "1.2.3.4", "1.2.3-rc.1", "01.2.3", "1.2.3+"] {
            XCTAssertNil(ReleaseVersion(invalid))
        }
    }
}
