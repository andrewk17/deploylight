import Combine
import XCTest
@testable import Deploylight

final class GitHubActionsIntegrationTests: XCTestCase {
    private let deployWorkflows = #"{"workflows":[{"id":1,"name":"DEPLOY Worker","path":".github/workflows/publish.yml"},{"id":2,"name":"Push to Cloudflare","path":".github/workflows/Deploy-Worker.yml"},{"id":3,"name":"Build","path":".github/workflows/build.yml"}]}"#

    func testWorkflowResponsesProduceFilteredDeploymentsAndReuseUnchangedHistory() async throws {
        let cases: [(String, String?, Deployment.State?)] = [
            ("queued", nil, .queued), ("waiting", nil, .queued), ("requested", nil, .queued), ("pending", nil, .queued),
            ("in_progress", nil, .building), ("completed", "success", .ready), ("completed", "failure", .error),
            ("completed", "timed_out", .error), ("completed", "startup_failure", .error),
            ("completed", "action_required", .error), ("completed", "cancelled", .canceled),
            ("completed", "skipped", nil), ("completed", "neutral", nil), ("completed", "stale", nil),
        ]
        let fixtureRuns = cases.enumerated().map { index, item in
            let isOnDefaultBranch = index != 4 && index != 6
            let event = ["push", "workflow_dispatch", "schedule", "release", "push", "pull_request"][index % 6]
            return run(id: 100 + index, status: item.0, conclusion: item.1, event: event,
                       branch: isOnDefaultBranch ? "main" : "topic", start: index == 0 ? nil : "2026-09-01T09:01:00Z")
        }
        let first = runPage(Array(fixtureRuns.prefix(10)))
        let second = runPage(Array(fixtureRuns.dropFirst(10)))
        let build = runPage([run(id: 300, status: "completed", conclusion: "success")])
        let workflows = deployWorkflows
        let session = FixtureHTTP.session { request in
            switch request.url!.path {
            case "/user/repos": return FixtureResponse(body: self.repoPage(["owner/worker"]))
            case "/repos/owner/worker/actions/workflows": return FixtureResponse(body: workflows)
            case "/repos/owner/worker/actions/workflows/1/runs", "/repos/owner/worker/actions/workflows/2/runs":
                let isFirstWorkflow = request.url!.path.contains("/1/runs")
                let etag = isFirstWorkflow ? #"W/"worker-1""# : #""worker-2""#
                if request.value(forHTTPHeaderField: "If-None-Match") == etag { return FixtureResponse(status: 304) }
                return FixtureResponse(body: isFirstWorkflow ? first : second, headers: ["ETag": etag])
            case "/repos/owner/worker/actions/workflows/3/runs": return FixtureResponse(body: build)
            default: return FixtureResponse(status: 404)
            }
        }
        let service = DeploymentService(providers: [GitHubActionsProvider(client: GitHubClient(session: session))])
        var preferences = Preferences.default
        preferences.githubToken = "fixture-token"
        XCTAssertEqual(service.configuredProviders(preferences), [.github])
        let snapshot = await service.fetch(preferences: preferences)
        XCTAssertTrue(snapshot.errors.isEmpty)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.deployments.map { ($0.id, $0) })
        XCTAssertEqual(byID.count, 11)
        for (index, item) in cases.enumerated() {
            XCTAssertEqual(byID[String(100 + index)]?.state, item.2)
        }
        for identifier in 100...103 { XCTAssertEqual(byID[String(identifier)]?.target, .production) }
        XCTAssertEqual(byID["104"]?.target, .preview)
        XCTAssertEqual(byID["105"]?.target, .preview)
        XCTAssertEqual(byID["106"]?.target, .preview)
        XCTAssertEqual(byID["104"]?.branch, "topic")
        XCTAssertEqual(byID["100"]?.projectName, "worker · DEPLOY Worker")
        XCTAssertEqual(byID["110"]?.projectName, "worker · Push to Cloudflare")
        XCTAssertNil(byID["300"])
        let date = ISO8601DateFormatter()
        XCTAssertEqual(byID["100"]?.createdAt, date.date(from: "2026-09-01T09:00:00Z"))
        XCTAssertEqual(byID["100"]?.buildStartedAt, byID["100"]?.createdAt)
        XCTAssertEqual(byID["104"]?.buildStartedAt, date.date(from: "2026-09-01T09:01:00Z"))
        XCTAssertNil(byID["104"]?.finishedAt)
        XCTAssertEqual(byID["105"]?.finishedAt, date.date(from: "2026-09-01T09:03:00Z"))
        XCTAssertEqual(byID["105"]?.commitMessage, "Deploy Worker")
        XCTAssertEqual(byID["105"]?.link?.absoluteString, "https://github.com/owner/worker/actions/runs/105")

        let refreshed = await service.fetch(preferences: preferences)
        XCTAssertTrue(refreshed.errors.isEmpty)
        XCTAssertEqual(refreshed.deployments, snapshot.deployments)
        let requests = FixtureHTTP.capturedRequests()
        XCTAssertEqual(requests.filter { !$0.url!.path.hasSuffix("/runs") }.count, 2)
        let runRequests = requests.filter { $0.url!.path.hasSuffix("/runs") }
        XCTAssertEqual(runRequests.count, 4)
        XCTAssertEqual(runRequests.filter { $0.value(forHTTPHeaderField: "If-None-Match") != nil }.count, 2)
        XCTAssertTrue(runRequests.allSatisfy { $0.url!.query == "per_page=10" })
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Deploylight")
        }

        preferences.githubWorkflows = "owner/worker#3"
        let specific = await service.fetch(preferences: preferences)
        XCTAssertEqual(specific.deployments.map(\.projectName), ["worker"])
        XCTAssertEqual(specific.deployments.map(\.id), ["300"])
        XCTAssertEqual(FixtureHTTP.capturedRequests().filter { !$0.url!.path.hasSuffix("/runs") }.count, 2)

        preferences.githubWorkflows = ""
        preferences.gitBranches = "main"
        preferences.showPreview = false
        preferences.showQueued = false
        preferences.showCanceled = false
        preferences.limitByCount = 1
        let filtered = DeploymentFilter(preferences: preferences).apply(to: snapshot.deployments)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.branch, "main")
        XCTAssertEqual(filtered.first?.target, .production)
        XCTAssertEqual(filtered.first?.state, .error)
    }

    func testPaginatedDiscoveryCapsPollingAtNewestPushedRepositories() async throws {
        let oldRepo = repoPage(["owner/old"], pushed: "2026-01-01T09:00:00Z")
        let newRepo = repoPage(["owner/new"], pushed: "2026-09-01T09:00:00Z")
        let workflows = (1...31).map { #"{"id":\#($0),"name":"Deploy \#($0)","path":".github/workflows/file.yml"}"# }
        let session = FixtureHTTP.session { request in
            switch request.url!.path {
            case "/user/repos" where request.url!.query!.contains("&page=2"):
                return FixtureResponse(body: newRepo)
            case "/user/repos":
                return FixtureResponse(body: oldRepo, headers: ["Link": #"<https://api.github.com/user/repos?sort=pushed&page=2>; rel="next""#])
            case "/repos/owner/new/actions/workflows":
                return FixtureResponse(body: #"{"workflows":[\#(workflows.joined(separator: ","))]}"#)
            case let path where path.hasPrefix("/repos/owner/new/") && path.hasSuffix("/runs"):
                return FixtureResponse(body: #"{"workflow_runs":[]}"#)
            default: return FixtureResponse(status: 500)
            }
        }
        let service = DeploymentService(providers: [GitHubActionsProvider(client: GitHubClient(session: session))])
        var preferences = Preferences.default
        preferences.githubToken = "fixture-token"
        let snapshot = await service.fetch(preferences: preferences)
        XCTAssertTrue(snapshot.errors.isEmpty)
        let paths = FixtureHTTP.capturedRequests().compactMap { $0.url?.path }
        XCTAssertEqual(paths.filter { $0 == "/user/repos" }.count, 2)
        XCTAssertEqual(Set(paths.filter { $0.hasSuffix("/runs") }),
                       Set((1...30).map { "/repos/owner/new/actions/workflows/\($0)/runs" }))
        XCTAssertFalse(paths.contains { $0.contains("owner/old") })
    }

    func testAuthorizationAndRateLimitFailuresReachDeploymentService() async throws {
        let reset = Date(timeIntervalSince1970: 1_900_000_000)
        for status in [401, 403, 429] {
            let session = FixtureHTTP.session { _ in
                FixtureResponse(status: status, headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1900000000"])
            }
            let service = DeploymentService(providers: [GitHubActionsProvider(client: GitHubClient(session: session))])
            var preferences = Preferences.default
            preferences.githubToken = "fixture-token"
            let snapshot = await service.fetch(preferences: preferences)
            let error = try XCTUnwrap(snapshot.errors[.github] as? GitHubAPIError)
            switch error {
            case .invalidToken where status == 401:
                XCTAssertEqual(error.localizedDescription, "Invalid GitHub token.")
            case let .rateLimited(actualReset) where status != 401:
                XCTAssertEqual(actualReset, reset)
                XCTAssertTrue(error.localizedDescription.hasPrefix("GitHub rate limit reached, resets at "))
                _ = await service.fetch(preferences: preferences)
                XCTAssertEqual(FixtureHTTP.capturedRequests().count, 1)
            default: XCTFail("Unexpected error for HTTP \(status): \(error)")
            }
        }
    }

    func testLiveOpenPlacesDeployWorkflow() async throws {
        guard let token = ProcessInfo.processInfo.environment["DEPLOYLIGHT_LIVE_GITHUB_TOKEN"], !token.isEmpty else {
            throw XCTSkip("Set DEPLOYLIGHT_LIVE_GITHUB_TOKEN to enable the live GitHub Actions check.")
        }
        let repositoryName = "andrewk17/open-places-api"
        let client = GitHubClient()
        let repos = try await client.repositories(token: token).filter { $0.fullName == repositoryName }
        let workflows = try await client.watches(in: repos, token: token)
        let deploy = try XCTUnwrap(workflows.first {
            $0.workflow.name == "Deploy" && $0.workflow.path == ".github/workflows/deploy.yml"
        })
        var preferences = Preferences.default
        preferences.githubToken = token
        preferences.githubRepositories = repositoryName
        preferences.githubWorkflows = deploy.id
        let snapshot = await DeploymentService().fetch(preferences: preferences)
        if let error = snapshot.errors[.github] { throw error }
        XCTAssertGreaterThanOrEqual(snapshot.deployments.count, 3)
        let date = ISO8601DateFormatter()
        for row in snapshot.deployments.prefix(3) {
            XCTAssertEqual(row.provider, .github)
            XCTAssertTrue(row.projectName.hasPrefix("open-places-api"))
            XCTAssertTrue(row.link?.path.hasPrefix("/andrewk17/open-places-api/actions/runs/") == true)
            print("LIVE_GITHUB_ROW | \(row.projectName) | \(row.state) | \(row.target?.rawValue ?? "-") | \(row.branch ?? "-") | created \(date.string(from: row.createdAt)) | started \(date.string(from: row.buildStartedAt)) | finished \(row.finishedAt.map { date.string(from: $0) } ?? "-")")
        }
    }

    func testProductionLabelsForReleasesPagesAndDefaultBranchEvents() async throws {
        let workflows = #"{"workflows":[{"id":7,"name":"pages build and deployment","path":"dynamic/pages/pages-build-deployment"},{"id":8,"name":"Deploy","path":".github/workflows/deploy.yml"},{"id":9,"name":"Dependabot","path":"dynamic/dependabot/dependabot-updates"},{"id":10,"name":"pages build and deployment","path":".github/workflows/pages.yml"}]}"#
        let cases: [(workflow: Int, event: String, branch: String, target: Deployment.Target)] = [
            (7, "dynamic", "main", .production),
            (7, "dynamic", "gh-pages", .production),
            (8, "release", "v0.5.0", .production),
            (8, "workflow_run", "main", .production),
            (8, "workflow_run", "topic", .preview),
            (8, "pull_request", "main", .preview),
            (8, "push", "v0.5.0", .preview),
            (9, "dynamic", "main", .preview),
            (9, "dynamic", "dependabot/fix", .preview),
            (10, "dynamic", "gh-pages", .preview),
        ]
        let runs = Dictionary(grouping: cases.enumerated(), by: { $0.element.workflow }).mapValues { items in
            runPage(items.map { index, item in
                run(id: 400 + index, status: "completed", conclusion: "success", event: item.event, branch: item.branch)
            })
        }
        let session = FixtureHTTP.session { request in
            switch request.url!.path {
            case "/user/repos": return FixtureResponse(body: self.repoPage(["owner/site"]))
            case "/repos/owner/site/actions/workflows": return FixtureResponse(body: workflows)
            default:
                guard let id = request.url?.pathComponents.dropLast().last.flatMap(Int.init),
                      let page = runs[id] else { return FixtureResponse(status: 404) }
                return FixtureResponse(body: page)
            }
        }
        let service = DeploymentService(providers: [GitHubActionsProvider(client: GitHubClient(session: session))])
        var preferences = Preferences.default
        preferences.githubToken = "fixture-token"
        preferences.githubWorkflows = "owner/site#7, owner/site#8, owner/site#9, owner/site#10"
        let snapshot = await service.fetch(preferences: preferences)
        XCTAssertTrue(snapshot.errors.isEmpty)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.deployments.map { ($0.id, $0) })
        XCTAssertEqual(byID.count, cases.count)
        for (index, item) in cases.enumerated() {
            XCTAssertEqual(byID[String(400 + index)]?.target, item.target, "\(item.event) on \(item.branch)")
        }
    }

    func testPartialRunFailuresReuseHistoryAndAllFailuresSurfaceAnError() async throws {
        let firstRuns = "/repos/owner/worker/actions/workflows/1/runs"
        let secondRuns = "/repos/owner/worker/actions/workflows/2/runs"
        var firstRequests = 0
        var secondRequests = 0
        let session = FixtureHTTP.session { request in
            switch request.url!.path {
            case "/user/repos": return FixtureResponse(body: self.repoPage(["owner/worker"]))
            case "/repos/owner/worker/actions/workflows": return FixtureResponse(body: self.deployWorkflows)
            case firstRuns:
                firstRequests += 1
                if firstRequests > 1 { return FixtureResponse(status: 503) }
                return FixtureResponse(body: self.runPage([self.run(id: 500, status: "completed", conclusion: "success")]),
                                       headers: ["ETag": #""last-good""#])
            case secondRuns:
                secondRequests += 1
                if secondRequests > 2 { return FixtureResponse(error: URLError(.timedOut)) }
                return FixtureResponse(body: self.runPage([self.run(id: 500 + secondRequests, status: "queued", conclusion: nil)]))
            default: return FixtureResponse(status: 404)
            }
        }
        let provider = GitHubActionsProvider(client: GitHubClient(session: session))
        var preferences = Preferences.default
        preferences.githubToken = "fixture-token"
        let first = try await provider.fetchDeployments(preferences: preferences)
        XCTAssertEqual(Set(first.map(\.id)), ["500", "501"])
        let partial = try await provider.fetchDeployments(preferences: preferences)
        XCTAssertEqual(Set(partial.map(\.id)), ["500", "502"])
        XCTAssertEqual(partial.first { $0.id == "500" }, first.first { $0.id == "500" })
        let retry = FixtureHTTP.capturedRequests().last { $0.url?.path == firstRuns }
        XCTAssertEqual(retry?.value(forHTTPHeaderField: "If-None-Match"), #""last-good""#)
        do {
            _ = try await provider.fetchDeployments(preferences: preferences)
            XCTFail("All run requests failed")
        } catch let error as GitHubAPIError {
            guard case .response(status: 503, message: _) = error else { throw error }
        } catch let error as URLError {
            XCTAssertEqual(error.code, .timedOut)
        }
    }

    func testWorkflowDiscoveryRetriesTransientFailuresAndCachesUnavailableRepositories() async throws {
        var retries: [String: Int] = [:]
        let session = FixtureHTTP.session { request in
            let path = request.url!.path
            switch path {
            case "/user/repos":
                return FixtureResponse(body: self.repoPage(["owner/healthy", "owner/retry-server", "owner/retry-timeout", "owner/unavailable"]))
            case "/repos/owner/healthy/actions/workflows":
                return FixtureResponse(body: self.deployWorkflows)
            case "/repos/owner/retry-server/actions/workflows", "/repos/owner/retry-timeout/actions/workflows":
                retries[path, default: 0] += 1
                if retries[path] == 1 {
                    return path.contains("server")
                        ? FixtureResponse(status: 503)
                        : FixtureResponse(error: URLError(.timedOut))
                }
                return FixtureResponse(body: self.deployWorkflows)
            case "/repos/owner/unavailable/actions/workflows":
                return FixtureResponse(status: 403)
            default:
                if path.hasSuffix("/runs") { return FixtureResponse(body: self.runPage([])) }
                return FixtureResponse(status: 404)
            }
        }
        let provider = GitHubActionsProvider(client: GitHubClient(session: session))
        var preferences = Preferences.default
        preferences.githubToken = "fixture-token"
        _ = try await provider.fetchDeployments(preferences: preferences)
        _ = try await provider.fetchDeployments(preferences: preferences)
        let paths = FixtureHTTP.capturedRequests().compactMap { $0.url?.path }
        for name in ["healthy", "unavailable", "retry-server", "retry-timeout"] {
            let lists = paths.filter { $0 == "/repos/owner/\(name)/actions/workflows" }
            XCTAssertEqual(lists.count, name.hasPrefix("retry-") ? 2 : 1)
        }
        XCTAssertEqual(paths.filter { $0.hasSuffix("/runs") }.count, 8)
    }

    func testRunAuthenticationAndSecondaryRateLimitsInterruptPartialRefreshes() async throws {
        let responses: [(FixtureResponse, TimeInterval?)] = [
            (FixtureResponse(status: 401), nil),
            (FixtureResponse(status: 403, headers: ["Retry-After": "120", "X-RateLimit-Remaining": "20"]), 120),
            (FixtureResponse(body: #"{"message":"You have exceeded a secondary rate limit."}"#,
                             status: 429, headers: ["X-RateLimit-Remaining": "20"]), 60),
        ]
        for (response, delay) in responses {
            let session = FixtureHTTP.session { request in
                switch request.url!.path {
                case "/user/repos": return FixtureResponse(body: self.repoPage(["owner/worker"]))
                case "/repos/owner/worker/actions/workflows": return FixtureResponse(body: self.deployWorkflows)
                case "/repos/owner/worker/actions/workflows/1/runs": return FixtureResponse(body: self.runPage([]))
                case "/repos/owner/worker/actions/workflows/2/runs": return response
                default: return FixtureResponse(status: 404)
                }
            }
            let service = DeploymentService(providers: [GitHubActionsProvider(client: GitHubClient(session: session))])
            var preferences = Preferences.default
            preferences.githubToken = "fixture-token"
            let before = Date()
            let snapshot = await service.fetch(preferences: preferences)
            let error = try XCTUnwrap(snapshot.errors[.github] as? GitHubAPIError)
            switch (error, delay) {
            case (.invalidToken, nil): break
            case let (.rateLimited(reset), .some(seconds)):
                XCTAssertGreaterThanOrEqual(reset, before.addingTimeInterval(seconds))
                XCTAssertLessThanOrEqual(reset, Date().addingTimeInterval(seconds))
                let requests = FixtureHTTP.capturedRequests().count
                let blocked = await service.fetch(preferences: preferences)
                guard case let .rateLimited(blockedUntil) = blocked.errors[.github] as? GitHubAPIError else {
                    XCTFail("Expected the next refresh to be rate limited")
                    continue
                }
                XCTAssertEqual(blockedUntil, reset)
                XCTAssertEqual(FixtureHTTP.capturedRequests().count, requests)
            default: XCTFail("Unexpected error for HTTP \(response.status): \(error)")
            }
        }
    }

    @MainActor
    func testRepositorySelectionReloadsOnlyWorkflowsAndResetLooksUpOnce() async throws {
        let suite = "DeploylightGitHubOptions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(userDefaults: defaults, tokens: FixtureTokenStore())
        try store.update { $0.githubToken = "fixture-token" }
        let session = FixtureHTTP.session { request in
            switch request.url!.path {
            case "/user": return FixtureResponse(body: #"{"login":"owner"}"#)
            case "/user/repos": return FixtureResponse(body: self.repoPage(["owner/worker", "owner/site"]))
            case "/repos/owner/worker/actions/workflows", "/repos/owner/site/actions/workflows":
                return FixtureResponse(body: self.deployWorkflows)
            default: return FixtureResponse(status: 404)
            }
        }
        let viewModel = PreferencesViewModel(store: store, githubClient: GitHubClient(session: session))
        let initial = expectation(description: "Initial GitHub options loaded")
        let initialObservation = viewModel.$githubWorkflowsLoading.first { !$0 }.sink { _ in initial.fulfill() }
        await fulfillment(of: [initial], timeout: 5)
        withExtendedLifetime(initialObservation) {}
        let repositories = viewModel.availableGitHubRepositories
        XCTAssertEqual(repositories.map(\.id), ["owner/site", "owner/worker"])

        let reloaded = expectation(description: "Selecting a repository reloaded its workflows")
        let reloadObservation = viewModel.$githubWorkflowsLoading.dropFirst(2).first { !$0 }.sink { _ in reloaded.fulfill() }
        let repositoryReload = viewModel.$githubRepositoriesLoading.dropFirst().sink { XCTAssertFalse($0) }
        viewModel.githubRepositoryMode = .selected
        viewModel.selectedGitHubRepositories = ["owner/worker"]
        await fulfillment(of: [reloaded], timeout: 5)
        repositoryReload.cancel()
        withExtendedLifetime(reloadObservation) {}
        XCTAssertEqual(viewModel.availableGitHubRepositories, repositories)
        XCTAssertEqual(viewModel.availableGitHubWorkflows.count, 3)
        let selectionPaths = FixtureHTTP.capturedRequests().compactMap { $0.url?.path }
        XCTAssertEqual(selectionPaths, [
            "/user", "/user/repos", "/repos/owner/site/actions/workflows", "/repos/owner/worker/actions/workflows",
            "/repos/owner/worker/actions/workflows",
        ])

        viewModel.selectedGitHubRepositories = ["owner/site"]
        viewModel.reset()
        XCTAssertEqual(viewModel.selectedGitHubRepositories, ["owner/worker"])
        let reset = expectation(description: "Reset reloaded GitHub options")
        let resetObservation = viewModel.$githubWorkflowsLoading.first { !$0 }.sink { _ in reset.fulfill() }
        await fulfillment(of: [reset], timeout: 5)
        withExtendedLifetime(resetObservation) {}

        let duplicate = expectation(description: "Reset values did not restart the debounced lookup")
        duplicate.isInverted = true
        let duplicateObservation = viewModel.$githubWorkflowsLoading.first { $0 }.sink { _ in duplicate.fulfill() }
        await fulfillment(of: [duplicate], timeout: 1)
        withExtendedLifetime(duplicateObservation) {}
        let resetPaths = FixtureHTTP.capturedRequests().compactMap { $0.url?.path }.dropFirst(selectionPaths.count)
        XCTAssertEqual(Array(resetPaths), ["/user", "/user/repos", "/repos/owner/worker/actions/workflows"])
    }

    private func repoPage(_ names: [String], pushed: String = "2026-09-01T09:00:00Z") -> String {
        let records = names.map { #"{"name":"\#($0.split(separator: "/").last!)","full_name":"\#($0)","default_branch":"main","pushed_at":"\#(pushed)"}"# }
        return "[\(records.joined(separator: ","))]"
    }

    private func run(id: Int, status: String, conclusion: String?, event: String = "push", branch: String = "main", start: String? = "2026-09-01T09:01:00Z") -> String {
        let conclusionJSON = conclusion.map { "\"\($0)\"" } ?? "null"
        let startJSON = start.map { "\"\($0)\"" } ?? "null"
        return #"{"id":\#(id),"status":"\#(status)","conclusion":\#(conclusionJSON),"event":"\#(event)","head_branch":"\#(branch)","head_commit":{"message":"Deploy Worker\n\nMore details"},"created_at":"2026-09-01T09:00:00Z","run_started_at":\#(startJSON),"updated_at":"2026-09-01T09:03:00Z","html_url":"https://github.com/owner/worker/actions/runs/\#(id)"}"#
    }

    private func runPage(_ runs: [String]) -> String {
        #"{"workflow_runs":[\#(runs.joined(separator: ","))]}"#
    }
}
