import Foundation

actor GitHubActionsProvider: DeploymentProvider {
    nonisolated let kind = Deployment.Provider.github
    static let watchLimit = 30

    private static let listTTL: TimeInterval = 10 * 60
    private static let workflowRetryTTL: TimeInterval = 60
    private static let runHistoryTTL: TimeInterval = 5 * 60

    private struct Cached<Value> {
        let value: Value
        let expiresAt: Date
    }

    private struct RunHistory {
        let value: GitHubClient.History
        let fetchedAt: Date
    }

    private let client: GitHubClient
    private let now: @Sendable () -> Date
    private var cacheToken: String?
    private var repositoryList: Cached<[GitHubRepository]>?
    private var workflowLists: [String: Cached<Result<[GitHubWorkflow], Error>>] = [:]
    private var history: [String: RunHistory] = [:]
    private var rateLimitedUntil: Date?

    init(client: GitHubClient = GitHubClient(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client
        self.now = now
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
        if let reset = rateLimitedUntil, reset > now() { throw GitHubAPIError.rateLimited(reset: reset) }
        do {
            let watches = try await resolveWatches(preferences: preferences, token: token)
            let previous = history
            let client = self.client
            let now = self.now
            let refreshed = try await gatherConcurrently(
                watches, maxConcurrent: 4, shouldPropagate: GitHubAPIError.interruptsFetch,
                onFailure: { watch, error in
                    try await self.discardHistoryIfNeeded(for: watch, error: error, token: token)
                }
            ) { watch -> [(String, RunHistory)] in
                let result = try await client.runs(for: watch, token: token, previous: previous[watch.id]?.value)
                return [(watch.id, RunHistory(value: result, fetchedAt: now()))]
            }
            try checkToken(token)
            for (id, result) in refreshed { history[id] = result }

            let cutoff = now().addingTimeInterval(-Self.runHistoryTTL)
            history = history.filter { $0.value.fetchedAt > cutoff }
            let workflowsByRepo = Dictionary(grouping: watches, by: { $0.repository.fullName })
            var deployments: [Deployment] = []
            for watch in watches {
                guard let result = history[watch.id] else { continue }
                let repo = watch.repository
                let name = (workflowsByRepo[repo.fullName]?.count ?? 0) > 1 ? "\(repo.name) · \(watch.workflow.name)" : repo.name
                deployments += result.value.runs.compactMap { $0.deployment(for: watch, projectName: name) }
            }
            return deployments.sorted { $0.createdAt > $1.createdAt }
        } catch let GitHubAPIError.rateLimited(reset) {
            try checkToken(token)
            rateLimitedUntil = reset
            throw GitHubAPIError.rateLimited(reset: reset)
        }
    }

    private func discardHistoryIfNeeded(for watch: GitHubWatch, error: Error, token: String) throws {
        try checkToken(token)
        guard let result = history[watch.id] else { return }
        if (error as? GitHubAPIError)?.repositoryUnavailable == true
            || now().timeIntervalSince(result.fetchedAt) >= Self.runHistoryTTL {
            history[watch.id] = nil
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
        if let repositoryList, repositoryList.expiresAt > now() { return repositoryList.value }
        let repositories = try await client.repositories(token: token)
        try checkToken(token)
        repositoryList = Cached(value: repositories, expiresAt: now().addingTimeInterval(Self.listTTL))
        let names = Set(repositories.map(\.fullName))
        workflowLists = workflowLists.filter { names.contains($0.key) }
        return repositories
    }

    private func workflows(in repository: GitHubRepository, token: String) async throws -> [GitHubWorkflow] {
        let name = repository.fullName
        if let cached = workflowLists[name], cached.expiresAt > now() { return try cached.value.get() }
        let result: Result<[GitHubWorkflow], Error>
        let ttl: TimeInterval
        do {
            result = .success(try await client.workflows(in: repository, token: token))
            ttl = Self.listTTL
        } catch {
            try checkToken(token)
            if GitHubAPIError.interruptsFetch(error) { throw error }
            if (error as? GitHubAPIError)?.repositoryUnavailable == true {
                result = .failure(error)
                ttl = Self.listTTL
            } else {
                if let cached = workflowLists[name], case .success = cached.value {
                    result = cached.value
                } else {
                    result = .failure(error)
                }
                ttl = Self.workflowRetryTTL
            }
        }
        try checkToken(token)
        workflowLists[name] = Cached(value: result, expiresAt: now().addingTimeInterval(ttl))
        return try result.get()
    }

    private func checkToken(_ token: String) throws {
        try Task.checkCancellation()
        guard cacheToken == token else { throw CancellationError() }
    }
}
