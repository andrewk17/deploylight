import Foundation

actor GitHubActionsProvider: DeploymentProvider {
    nonisolated let kind = Deployment.Provider.github
    static let watchLimit = 30

    private static let listTTL: TimeInterval = 10 * 60

    private struct Cached<Value> {
        let value: Value
        let expiresAt = Date().addingTimeInterval(GitHubActionsProvider.listTTL)

        var isFresh: Bool { expiresAt > Date() }
    }

    private let client: GitHubClient
    private var cacheToken: String?
    private var repositoryList: Cached<[GitHubRepository]>?
    private var workflowLists: [String: Cached<Result<[GitHubWorkflow], GitHubAPIError>>] = [:]
    private var history: [String: GitHubClient.History] = [:]
    private var rateLimitedUntil: Date?

    init(client: GitHubClient = GitHubClient()) {
        self.client = client
    }

    nonisolated func isConfigured(_ preferences: Preferences) -> Bool {
        preferences.hasGitHubToken
    }

    func fetchDeployments(preferences: Preferences) async throws -> [Deployment] {
        try Task.checkCancellation()
        let token = preferences.githubToken
        guard isConfigured(preferences) else { return [] }
        if cacheToken != token {
            cacheToken = token
            repositoryList = nil
            workflowLists = [:]
            history = [:]
            rateLimitedUntil = nil
        }
        if let reset = rateLimitedUntil, reset > Date() { throw GitHubAPIError.rateLimited(reset: reset) }
        do {
            let watches = try await resolveWatches(preferences: preferences, token: token)
            let previous = history
            let client = self.client
            let refreshed = try await gatherConcurrently(watches, maxConcurrent: 6, shouldPropagate: GitHubAPIError.interruptsFetch) {
                watch -> [(String, GitHubClient.History)] in
                let result = try await client.runs(for: watch, token: token, previous: previous[watch.id])
                return [(watch.id, result)]
            }
            try checkToken(token)
            for (id, result) in refreshed { history[id] = result }

            let workflowsByRepo = Dictionary(grouping: watches, by: { $0.repository.fullName })
            var deployments: [Deployment] = []
            for watch in watches {
                guard let result = history[watch.id] else { continue }
                let repo = watch.repository
                let name = (workflowsByRepo[repo.fullName]?.count ?? 0) > 1 ? "\(repo.name) · \(watch.workflow.name)" : repo.name
                deployments += result.runs.compactMap { $0.deployment(for: watch, projectName: name) }
            }
            return deployments.sorted { $0.createdAt > $1.createdAt }
        } catch let GitHubAPIError.rateLimited(reset) {
            try checkToken(token)
            rateLimitedUntil = reset
            throw GitHubAPIError.rateLimited(reset: reset)
        }
    }

    private func resolveWatches(preferences: Preferences, token: String) async throws -> [GitHubWatch] {
        let repoNames = Set(preferences.githubRepositoryList.map { $0.lowercased() })
        let workflowIDs = Set(preferences.githubWorkflowList.map { $0.lowercased() })
        let repositories = try await repositories(token: token).filter {
            repoNames.isEmpty || repoNames.contains($0.fullName.lowercased())
        }
        let watches = try await GitHubWatch.collect(in: repositories, matching: {
            $0.matches(workflowIDs: workflowIDs)
        }, limit: Self.watchLimit) { repository in
            try await self.workflows(in: repository, token: token)
        }
        try checkToken(token)
        let ids = Set(watches.map(\.id))
        history = history.filter { ids.contains($0.key) }
        return watches
    }

    private func repositories(token: String) async throws -> [GitHubRepository] {
        if let repositoryList, repositoryList.isFresh { return repositoryList.value }
        let repositories = try await client.repositories(token: token)
        try checkToken(token)
        repositoryList = Cached(value: repositories)
        let names = Set(repositories.map(\.fullName))
        workflowLists = workflowLists.filter { names.contains($0.key) }
        return repositories
    }

    private func workflows(in repository: GitHubRepository, token: String) async throws -> [GitHubWorkflow] {
        let name = repository.fullName
        if let cached = workflowLists[name], cached.isFresh { return try cached.value.get() }
        let result: Result<[GitHubWorkflow], GitHubAPIError>
        do {
            result = .success(try await client.workflows(in: repository, token: token))
        } catch let error as GitHubAPIError where error.repositoryUnavailable {
            result = .failure(error)
        }
        try checkToken(token)
        workflowLists[name] = Cached(value: result)
        return try result.get()
    }

    private func checkToken(_ token: String) throws {
        try Task.checkCancellation()
        guard cacheToken == token else { throw CancellationError() }
    }
}
