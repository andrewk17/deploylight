import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Deploylight

final class OffscreenRenderTests: XCTestCase {
    @MainActor
    func testRenderAccountsAndMenuRows() async throws {
        guard let path = ProcessInfo.processInfo.environment["DEPLOYLIGHT_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set DEPLOYLIGHT_SCREENSHOT_DIR to capture the UI with fixtures.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let suite = "DeploylightRender.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PreferencesStore(userDefaults: defaults, tokens: FixtureTokenStore())
        try store.update {
            $0.vercelToken = "fixture-vercel"
            $0.cloudflareToken = "fixture-cloudflare"
#if !DEPLOYLIGHT_BASELINE
            $0.githubToken = "fixture-github"
            $0.githubWorkflows = "andrewk17/open-places-api#1"
#endif
        }
        let session = FixtureHTTP.session { request in
            switch request.url?.path {
            case "/v2/teams": return FixtureResponse(body: #"{"teams":[]}"#)
            case "/v9/projects": return FixtureResponse(body: #"{"projects":[{"id":"web","name":"web"}]}"#)
            case "/client/v4/accounts": return FixtureResponse(body: #"{"success":true,"result":[{"id":"account","name":"Personal"}]}"#)
            case "/client/v4/accounts/account/workers/scripts":
                return FixtureResponse(body: #"{"success":true,"result":[{"id":"edge-cache","tag":"edge-cache"}]}"#)
            case "/user": return FixtureResponse(body: #"{"login":"andrewk17"}"#)
            case "/user/repos":
                return FixtureResponse(body: #"[{"name":"open-places-api","full_name":"andrewk17/open-places-api","default_branch":"main","pushed_at":"2026-11-17T16:45:00Z"}]"#)
            case "/repos/andrewk17/open-places-api/actions/workflows":
                return FixtureResponse(body: #"{"workflows":[{"id":1,"name":"Deploy","path":".github/workflows/deploy.yml"},{"id":2,"name":"CI","path":".github/workflows/ci.yml"}]}"#)
            default: return FixtureResponse(status: 404)
            }
        }
        let vercel = VercelClient(session: session)
        let cloudflare = CloudflareClient(session: session)
#if DEPLOYLIGHT_BASELINE
        let viewModel = PreferencesViewModel(store: store, vercelClient: vercel, cloudflareClient: cloudflare)
        let githubLookup = Just(false).eraseToAnyPublisher()
#else
        let viewModel = PreferencesViewModel(store: store, vercelClient: vercel, cloudflareClient: cloudflare,
                                             githubClient: GitHubClient(session: session))
        let githubLookup = viewModel.$githubWorkflowsLoading.eraseToAnyPublisher()
#endif
        let loaded = expectation(description: "The fixture account options have loaded")
        let observation = Publishers.CombineLatest4(viewModel.$teamsLoading, viewModel.$projectsLoading,
                                                    viewModel.$cloudflareLoading, githubLookup)
            .first { !$0.0 && !$0.1 && !$0.2 && !$0.3 }
            .sink { _ in loaded.fulfill() }
        await fulfillment(of: [loaded], timeout: 10)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(viewModel.vercelStatus, .connected("1 project"))
        XCTAssertEqual(viewModel.cloudflareStatus, .connected("1 account · 1 Worker"))
#if !DEPLOYLIGHT_BASELINE
        XCTAssertEqual(viewModel.githubStatus, .connected("andrewk17"))
        XCTAssertEqual(viewModel.availableGitHubRepositories.map(\.title), ["andrewk17/open-places-api"])
        XCTAssertEqual(viewModel.availableGitHubWorkflows.map(\.title), ["andrewk17/open-places-api · Deploy", "andrewk17/open-places-api · CI"])
#endif
        NSApplication.shared.setActivationPolicy(.prohibited)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let accounts = PreferencesPane.accounts.view(viewModel: viewModel)
            try capture(NSHostingView(rootView: accounts), appearance: appearance, at: directory.appendingPathComponent("accounts-\(name).png"))
        }
        try capture(exampleMenuRows(), appearance: .aqua, at: directory.appendingPathComponent("menu-rows.png"))
    }

#if !DEPLOYLIGHT_BASELINE
    @MainActor
    func testRenderGitHubReleaseRow() async throws {
        guard let path = ProcessInfo.processInfo.environment["DEPLOYLIGHT_SCREENSHOT_DIR"], !path.isEmpty else {
            throw XCTSkip("Set DEPLOYLIGHT_SCREENSHOT_DIR to capture the UI with fixtures.")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let session = FixtureHTTP.session { request in
            switch request.url?.path {
            case "/user/repos":
                return FixtureResponse(body: #"[{"name":"example-app","full_name":"fixture-owner/example-app","default_branch":"main"}]"#)
            case "/repos/fixture-owner/example-app/actions/workflows":
                return FixtureResponse(body: #"{"workflows":[{"id":1,"name":"Deploy","path":".github/workflows/deploy.yml"}]}"#)
            case "/repos/fixture-owner/example-app/actions/workflows/1/runs":
                return FixtureResponse(body: #"{"workflow_runs":[{"id":1,"status":"completed","conclusion":"success","event":"release","head_branch":"v0.5.0","created_at":"2026-11-17T16:45:00Z","updated_at":"2026-11-17T16:46:12Z","html_url":"https://github.com/fixture-owner/example-app/actions/runs/1"}]}"#)
            default: return FixtureResponse(status: 404)
            }
        }
        var preferences = Preferences.default
        preferences.githubToken = "fixture-token"
        let provider = GitHubActionsProvider(client: GitHubClient(session: session))
        let rows = try await provider.fetchDeployments(preferences: preferences)
        XCTAssertEqual(rows.count, 1)
        let deployment = try XCTUnwrap(rows.first)
        NSApplication.shared.setActivationPolicy(.prohibited)
        let menu = menuRows(rows, now: deployment.createdAt.addingTimeInterval(120))
        print("GitHub release row badge: \(try XCTUnwrap(deployment.target).rawValue)")
        try capture(menu, appearance: .aqua, at: directory.appendingPathComponent("github-release-row.png"))
    }
#endif

    @MainActor
    private func exampleMenuRows() -> NSView {
        let now = Date(timeIntervalSince1970: 1_794_931_200)
        var examples: [(Deployment.Provider, String, Deployment.State, String, Deployment.Target)] = [
            (.vercel, "web", .ready, "main", .production),
            (.cloudflare, "edge-cache", .ready, "main", .production),
        ]
#if !DEPLOYLIGHT_BASELINE
        examples += [
            (.github, "open-places-api", .building, "main", .production),
            (.github, "open-places-api", .error, "cache-fix", .preview),
            (.github, "open-places-api", .ready, "main", .production),
        ]
#endif
        let deployments = examples.enumerated().map { index, example in
            let (provider, project, state, branch, target) = example
            let start = now.addingTimeInterval(-72 - Double(index - 2) * 180)
            return Deployment(id: String(index), provider: provider, projectName: project, state: state,
                              target: target, branch: branch, commitMessage: nil, createdAt: start,
                              buildStartedAt: start, finishedAt: state.isActive ? nil : start.addingTimeInterval(state == .error ? 48 : 128), link: nil)
        }
        return menuRows(deployments, now: now)
    }

    @MainActor
    private func menuRows(_ deployments: [Deployment], now: Date) -> NSView {
        let font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize, weight: .regular)
        let formatter = MenuRowFormatter(preferences: .default, showsProvider: true, font: font, now: now)
        let menu = NSStackView()
        menu.orientation = .vertical
        menu.alignment = .leading
        menu.spacing = 5
        menu.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        menu.wantsLayer = true
        let light = NSAppearance(named: .aqua)
        menu.appearance = light
        light?.performAsCurrentDrawingAppearance {
            menu.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        }
        for deployment in deployments {
            let title = formatter.title(for: deployment, includeProject: true)
            let icon = NSImageView()
            icon.image = StatusIcon.image(for: deployment.state)
            let row = NSStackView(views: [icon, NSTextField(labelWithAttributedString: title.attributed)])
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 7
            menu.addArrangedSubview(row)
        }
        return menu
    }

    @MainActor
    private func capture(_ view: NSView, appearance: NSAppearance.Name, at url: URL) throws {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: view.fittingSize), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: url)
    }
}

final class FixtureTokenStore: TokenStore {
    private var values: [TokenProvider: String] = [:]

    func read(_ provider: TokenProvider) throws -> String? { values[provider] }

    func save(_ token: String, for provider: TokenProvider) throws {
        values[provider] = token.isEmpty ? nil : token
    }
}
