import Foundation

enum GitHubAPIError: LocalizedError {
    case invalidToken
    case rateLimited(reset: Date)
    case response(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidToken:
            return "Invalid GitHub token."
        case let .rateLimited(reset):
            return "GitHub rate limit reached, resets at \(reset.formatted(date: .abbreviated, time: .shortened))."
        case let .response(status, message):
            return "GitHub API error (\(status)): \(message)"
        }
    }

    var repositoryUnavailable: Bool {
        if case let .response(status, _) = self { return status == 403 || status == 404 }
        return false
    }

    static func interruptsFetch(_ error: Error) -> Bool {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { return true }
        switch error as? Self {
        case .invalidToken, .rateLimited: return true
        default: return false
        }
    }
}

struct GitHubRepository: Decodable {
    let name: String
    let fullName: String
    let defaultBranch: String
    let pushedAt: Date?
}

struct GitHubWorkflow: Decodable {
    let id: Int64
    let name: String
    let path: String

    var isDeployWorkflow: Bool {
        name.localizedCaseInsensitiveContains("deploy") || path.localizedCaseInsensitiveContains("deploy")
    }
}

struct GitHubWatch {
    let repository: GitHubRepository
    let workflow: GitHubWorkflow

    var id: String { "\(repository.fullName.lowercased())#\(workflow.id)" }
    var title: String { "\(repository.fullName) · \(workflow.name)" }

    func matches(workflowIDs: Set<String>) -> Bool {
        workflowIDs.isEmpty ? workflow.isDeployWorkflow : workflowIDs.contains(id)
    }

    static func collect(
        in repositories: [GitHubRepository], matching: (Self) -> Bool = { _ in true }, limit: Int? = nil,
        workflows: (GitHubRepository) async throws -> [GitHubWorkflow]
    ) async throws -> [Self] {
        var result: [Self] = []
        var firstError: Error?
        var listedRepository = false
        var consecutiveTransientFailures = 0
        for repository in repositories {
            do {
                let listed = try await workflows(repository)
                listedRepository = true
                consecutiveTransientFailures = 0
                result += listed.map { Self(repository: repository, workflow: $0) }.filter(matching)
                if let limit, result.count >= limit { return Array(result.prefix(limit)) }
            } catch {
                try Task.checkCancellation()
                if GitHubAPIError.interruptsFetch(error) { throw error }
                firstError = firstError ?? error
                if (error as? GitHubAPIError)?.repositoryUnavailable == true {
                    consecutiveTransientFailures = 0
                } else {
                    consecutiveTransientFailures += 1
                    if consecutiveTransientFailures == 3 { throw error }
                }
            }
        }
        if !listedRepository, let firstError { throw firstError }
        return result
    }
}

struct GitHubRun: Decodable {
    struct Commit: Decodable {
        let message: String
    }

    struct Repository: Decodable {
        let fullName: String
    }

    private static let pullRequestEvents: Set<String> = [
        "pull_request", "pull_request_target", "pull_request_review", "pull_request_review_comment", "merge_group",
    ]

    let id: Int64
    let status: String
    let conclusion: String?
    let event: String
    let headBranch: String?
    let headRepository: Repository?
    let headCommit: Commit?
    let createdAt: Date
    let runStartedAt: Date?
    let updatedAt: Date
    let htmlUrl: URL

    func deployment(for watch: GitHubWatch, projectName: String) -> Deployment? {
        let state: Deployment.State
        switch status {
        case "queued", "waiting", "requested", "pending": state = .queued
        case "in_progress": state = .building
        case "completed":
            switch conclusion {
            case "success": state = .ready
            case "failure", "timed_out", "startup_failure", "action_required": state = .error
            case "cancelled": state = .canceled
            case "skipped", "neutral", "stale": return nil
            default: state = .unknown
            }
        default: state = .unknown
        }

        // Release runs use the tag as head_branch, and Pages builds use the Pages source branch.
        let isPagesBuild = event == "dynamic" && watch.workflow.path == "dynamic/pages/pages-build-deployment"
        let isSameRepository = headRepository.map {
            $0.fullName.caseInsensitiveCompare(watch.repository.fullName) == .orderedSame
        } ?? true
        let isProduction = event == "release" || isPagesBuild
            || (headBranch == watch.repository.defaultBranch && isSameRepository && !Self.pullRequestEvents.contains(event))
        return Deployment(
            id: String(id), provider: .github, projectName: projectName, state: state, target: isProduction ? .production : .preview,
            branch: headBranch, commitMessage: headCommit?.message.components(separatedBy: .newlines).first,
            createdAt: createdAt, buildStartedAt: runStartedAt ?? createdAt,
            finishedAt: status == "completed" ? updatedAt : nil, link: htmlUrl
        )
    }
}

struct GitHubClient {
    private struct User: Decodable { let login: String }
    private struct WorkflowPage: Decodable { let workflows: [GitHubWorkflow] }
    private struct RunPage: Decodable { let workflowRuns: [GitHubRun] }
    private struct ErrorBody: Decodable { let message: String }

    private static let baseURL = URL(string: "https://api.github.com")!
    private static let uncachedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    private let session: URLSession

    init(session: URLSession? = nil) {
        self.session = session ?? Self.uncachedSession
    }

    func login(token: String) async throws -> String {
        let (data, _) = try await get(URL(string: "/user", relativeTo: Self.baseURL)!, token: token)
        return try decode(User.self, from: data).login
    }

    func repositories(token: String) async throws -> [GitHubRepository] {
        let repositories = try await pages("/user/repos?sort=pushed&direction=desc&per_page=100", token: token) {
            try decode([GitHubRepository].self, from: $0)
        }
        return repositories.sorted {
            let left = $0.pushedAt ?? .distantPast
            let right = $1.pushedAt ?? .distantPast
            return left == right ? $0.fullName < $1.fullName : left > right
        }
    }

    func workflows(in repository: GitHubRepository, token: String) async throws -> [GitHubWorkflow] {
        try await pages("/repos/\(repository.fullName)/actions/workflows?per_page=100", token: token) {
            try decode(WorkflowPage.self, from: $0).workflows
        }
    }

    func watches(in repositories: [GitHubRepository], token: String) async throws -> [GitHubWatch] {
        try await GitHubWatch.collect(in: repositories) { try await workflows(in: $0, token: token) }
    }

    struct History {
        let runs: [GitHubRun]
        let etag: String?
    }

    func runs(for watch: GitHubWatch, token: String, previous: History?) async throws -> History {
        let path = "/repos/\(watch.repository.fullName)/actions/workflows/\(watch.workflow.id)/runs?per_page=10"
        let (data, response) = try await get(URL(string: path, relativeTo: Self.baseURL)!, token: token, etag: previous?.etag)
        if response.statusCode == 304, let previous { return previous }
        return History(runs: try decode(RunPage.self, from: data).workflowRuns, etag: response.value(forHTTPHeaderField: "ETag"))
    }

    private func pages<Item>(_ path: String, token: String, decodePage: (Data) throws -> [Item]) async throws -> [Item] {
        var next = URL(string: path, relativeTo: Self.baseURL)?.absoluteURL
        var seen: Set<URL> = []
        var items: [Item] = []
        while let url = next, seen.insert(url).inserted {
            let (data, response) = try await get(url, token: token)
            items += try decodePage(data)
            next = nextPage(response)
        }
        return items
    }

    private func nextPage(_ response: HTTPURLResponse) -> URL? {
        let links = response.value(forHTTPHeaderField: "Link")?.split(separator: ",") ?? []
        for link in links where link.contains("rel=\"next\"") {
            guard let start = link.firstIndex(of: "<"), let end = link.firstIndex(of: ">"), start < end,
                  let url = URL(string: String(link[link.index(after: start)..<end])),
                  url.scheme == Self.baseURL.scheme, url.host == Self.baseURL.host,
                  url.port == nil, url.user == nil, url.password == nil else { continue }
            return url
        }
        return nil
    }

    private func get(_ url: URL, token: String, etag: String? = nil) async throws -> (Data, HTTPURLResponse) {
        try Task.checkCancellation()
        var request = URLRequest(url: url.absoluteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Deploylight", forHTTPHeaderField: "User-Agent")
        request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else {
            throw GitHubAPIError.response(status: -1, message: "No response")
        }
        switch http.statusCode {
        case 200...299:
            return (data, http)
        case 304 where etag != nil:
            return (data, http)
        case 401:
            throw GitHubAPIError.invalidToken
        case 403, 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
            let message = (try? decode(ErrorBody.self, from: data))?.message ?? "Unknown error"
            let now = Date()
            let seconds = retryAfter.flatMap(TimeInterval.init).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let retryReset = now.addingTimeInterval(seconds ?? 60)
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                let epoch = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
                let reset = epoch.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
                    ?? now.addingTimeInterval(60)
                throw GitHubAPIError.rateLimited(reset: retryAfter == nil ? reset : max(reset, retryReset))
            }
            if retryAfter != nil || message.localizedCaseInsensitiveContains("secondary rate limit") {
                throw GitHubAPIError.rateLimited(reset: retryReset)
            }
            if http.statusCode == 429 { throw GitHubAPIError.rateLimited(reset: now.addingTimeInterval(60)) }
            throw GitHubAPIError.response(status: http.statusCode, message: message)
        default:
            let message = (try? decode(ErrorBody.self, from: data))?.message ?? "Unknown error"
            throw GitHubAPIError.response(status: http.statusCode, message: message)
        }
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw APIError.decodingFailure(service: "GitHub")
        }
    }
}
