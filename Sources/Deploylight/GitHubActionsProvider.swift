import Foundation

actor GitHubActionsProvider: DeploymentProvider {
    nonisolated let kind = Deployment.Provider.github
    static let watchLimit = 30

    private static let listTTL: TimeInterval = 10 * 60

    private struct Scope: Equatable {
        let repositories: Set<String>
        let workflows: Set<String>
    }

    private struct Catalog {
        let scope: Scope
        let watches: [GitHubWatch]
        let expiresAt: Date
    }

    private let client: GitHubClient
    private var cacheToken: String?
    private var catalog: Catalog?
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
            catalog = nil
            history = [:]
            rateLimitedUntil = nil
        }
        if let reset = rateLimitedUntil, reset > Date() { throw GitHubAPIError.rateLimited(reset: reset) }
        let scope = Scope(repositories: Set(preferences.githubRepositoryList.map { $0.lowercased() }),
                          workflows: Set(preferences.githubWorkflowList.map { $0.lowercased() }))

        do {
            let watches = try await resolveWatches(scope: scope, token: token)
            let workflowsByRepo = Dictionary(grouping: watches, by: { $0.repository.fullName })
            var deployments: [Deployment] = []
            var unavailable: GitHubAPIError?
            var fetchedWorkflow = false
            for watch in watches {
                do {
                    let result = try await client.runs(for: watch, token: token, previous: history[watch.id])
                    try checkToken(token)
                    history[watch.id] = result
                    fetchedWorkflow = true
                    let repo = watch.repository
                    let name = (workflowsByRepo[repo.fullName]?.count ?? 0) > 1 ? "\(repo.name) · \(watch.workflow.name)" : repo.name
                    deployments += result.runs.compactMap { $0.deployment(in: repo, projectName: name) }
                } catch let error as GitHubAPIError where error.repositoryUnavailable {
                    unavailable = error
                }
            }
            if !fetchedWorkflow, let unavailable { throw unavailable }
            return deployments.sorted { $0.createdAt > $1.createdAt }
        } catch let GitHubAPIError.rateLimited(reset) {
            try checkToken(token)
            rateLimitedUntil = reset
            throw GitHubAPIError.rateLimited(reset: reset)
        }
    }

    private func resolveWatches(scope: Scope, token: String) async throws -> [GitHubWatch] {
        if let catalog, catalog.scope == scope, catalog.expiresAt > Date() { return catalog.watches }
        let repositories = try await client.repositories(token: token).filter {
            scope.repositories.isEmpty || scope.repositories.contains($0.fullName.lowercased())
        }
        try checkToken(token)
        let watches = try await client.watches(in: repositories, token: token, matching: {
            $0.matches(workflowIDs: scope.workflows)
        }, limit: Self.watchLimit)
        try checkToken(token)
        catalog = Catalog(scope: scope, watches: watches, expiresAt: Date().addingTimeInterval(Self.listTTL))
        let ids = Set(watches.map(\.id))
        history = history.filter { ids.contains($0.key) }
        return watches
    }

    private func checkToken(_ token: String) throws {
        try Task.checkCancellation()
        guard cacheToken == token else { throw CancellationError() }
    }
}
