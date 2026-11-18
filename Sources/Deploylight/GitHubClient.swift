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
}

struct GitHubRun: Decodable {
    struct Commit: Decodable {
        let message: String
    }

    let id: Int64
    let status: String
    let conclusion: String?
    let event: String
    let headBranch: String?
    let headCommit: Commit?
    let createdAt: Date
    let runStartedAt: Date?
    let updatedAt: Date
    let htmlUrl: URL

    func deployment(in repository: GitHubRepository, projectName: String) -> Deployment? {
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

        let productionEvents = ["push", "workflow_dispatch", "schedule", "release"]
        let target: Deployment.Target = headBranch == repository.defaultBranch && productionEvents.contains(event)
            ? .production : .preview
        return Deployment(
            id: String(id), provider: .github, projectName: projectName, state: state, target: target,
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

    func watches(
        in repositories: [GitHubRepository], token: String,
        matching: (GitHubWatch) -> Bool = { _ in true }, limit: Int? = nil
    ) async throws -> [GitHubWatch] {
        var result: [GitHubWatch] = []
        var unavailable: GitHubAPIError?
        var listedRepository = false
        for repository in repositories {
            do {
                let workflows = try await pages("/repos/\(repository.fullName)/actions/workflows?per_page=100", token: token) {
                    try decode(WorkflowPage.self, from: $0).workflows
                }
                listedRepository = true
                result += workflows.map { GitHubWatch(repository: repository, workflow: $0) }.filter(matching)
                if let limit, result.count >= limit { return Array(result.prefix(limit)) }
            } catch let error as GitHubAPIError where error.repositoryUnavailable {
                unavailable = error
            }
        }
        if !listedRepository, let unavailable { throw unavailable }
        return result
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
            if http.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0" {
                let epoch = http.value(forHTTPHeaderField: "X-RateLimit-Reset").flatMap(TimeInterval.init)
                let reset = epoch.map(Date.init(timeIntervalSince1970:)) ?? Date().addingTimeInterval(60)
                throw GitHubAPIError.rateLimited(reset: reset)
            }
            fallthrough
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
