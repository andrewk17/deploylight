import Foundation

/// What the menu bar item shows next to the status icon.
enum MenuBarStyle: String, Codable, CaseIterable {
    /// The project and build time while a build is running, otherwise just the icon.
    case auto
    /// Just the icon.
    case compact
    /// The project and build time, always.
    case detailed
}

/// How build durations are written.
enum TimeFormat: String, Codable, CaseIterable {
    /// "2:14"
    case clock
    /// "2m 14s"
    case units
    /// "2m"
    case minutes
}

/// How menu rows show which provider a deployment came from, when more than one is in use.
enum ProviderStyle: String, Codable, CaseIterable {
    case icon
    case name
    case hidden
}

/// How menu rows show whether a deployment is production or preview.
enum EnvironmentStyle: String, Codable, CaseIterable {
    /// A colored badge, filled for production and outlined for preview.
    case badge
    case text
    case hidden
}

struct Preferences: Codable, Equatable {
    static let personalScopeIdentifier = "__personal__"

    var vercelToken: String
    /// Comma-separated Vercel team IDs; empty means all accessible scopes.
    var teamId: String
    /// Comma-separated Vercel project names; empty means all.
    var projectName: String
    var cloudflareToken: String
    /// Comma-separated Cloudflare account IDs; empty means all accessible accounts.
    var cloudflareAccountIds: String
    /// Comma-separated Worker names; empty means all.
    var cloudflareWorkers: String
    var gitBranches: String
    var showProduction: Bool
    var showPreview: Bool
    var showReady: Bool
    var showBuilding: Bool
    var showError: Bool
    var showQueued: Bool
    var showCanceled: Bool
    var limitByCount: Int?
    var limitByHours: Int?
    var refreshIntervalIdle: Int?
    var refreshIntervalBuilding: Int?
    var menuBarStyle: MenuBarStyle
    var timeFormat: TimeFormat
    /// Whether the menu lists each project's latest deployment below the recent ones.
    var showProjects: Bool
    var providerStyle: ProviderStyle
    var environmentStyle: EnvironmentStyle
    var checkForUpdates: Bool = true

    static let `default` = Preferences(
        vercelToken: "",
        teamId: "",
        projectName: "",
        cloudflareToken: "",
        cloudflareAccountIds: "",
        cloudflareWorkers: "",
        gitBranches: "",
        showProduction: true,
        showPreview: true,
        showReady: true,
        showBuilding: true,
        showError: true,
        showQueued: true,
        showCanceled: true,
        limitByCount: 5,
        limitByHours: nil,
        refreshIntervalIdle: 15,
        refreshIntervalBuilding: 2,
        menuBarStyle: .auto,
        timeFormat: .clock,
        showProjects: true,
        providerStyle: .icon,
        environmentStyle: .badge
    )

    var hasVercelToken: Bool {
        !vercelToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasCloudflareToken: Bool {
        !cloudflareToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var teamIdList: [String] {
        commaSeparatedList(from: teamId)
    }

    var projectNameList: [String] {
        commaSeparatedList(from: projectName)
    }

    var cloudflareAccountIdList: [String] {
        commaSeparatedList(from: cloudflareAccountIds)
    }

    var cloudflareWorkerList: [String] {
        commaSeparatedList(from: cloudflareWorkers)
    }

    var branchList: [String] {
        commaSeparatedList(from: gitBranches).map { $0.lowercased() }
    }

    private func commaSeparatedList(from value: String) -> [String] {
        var results: [String] = []
        var seen: Set<String> = []

        for token in value.split(separator: ",") {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let normalized = trimmed.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            results.append(trimmed)
        }

        return results
    }
}

extension Preferences {
    enum CodingKeys: String, CodingKey {
        case vercelToken, teamId, projectName, cloudflareToken, cloudflareAccountIds, cloudflareWorkers, gitBranches, showProduction, showPreview, showReady, showBuilding, showError, showQueued, showCanceled, limitByCount, limitByHours, refreshIntervalIdle, refreshIntervalBuilding, menuBarStyle, timeFormat, showProjects, providerStyle, environmentStyle, checkForUpdates
    }

    /// Missing keys fall back to defaults so preferences saved by older versions still load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Preferences.default

        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }

        self.init(
            vercelToken: try value(.vercelToken, defaults.vercelToken),
            teamId: try value(.teamId, defaults.teamId),
            projectName: try value(.projectName, defaults.projectName),
            cloudflareToken: try value(.cloudflareToken, defaults.cloudflareToken),
            cloudflareAccountIds: try value(.cloudflareAccountIds, defaults.cloudflareAccountIds),
            cloudflareWorkers: try value(.cloudflareWorkers, defaults.cloudflareWorkers),
            gitBranches: try value(.gitBranches, defaults.gitBranches),
            showProduction: try value(.showProduction, defaults.showProduction),
            showPreview: try value(.showPreview, defaults.showPreview),
            showReady: try value(.showReady, defaults.showReady),
            showBuilding: try value(.showBuilding, defaults.showBuilding),
            showError: try value(.showError, defaults.showError),
            showQueued: try value(.showQueued, defaults.showQueued),
            showCanceled: try value(.showCanceled, defaults.showCanceled),
            // A missing optional was saved as nil (cleared), so it stays nil.
            limitByCount: try container.decodeIfPresent(Int.self, forKey: .limitByCount),
            limitByHours: try container.decodeIfPresent(Int.self, forKey: .limitByHours),
            refreshIntervalIdle: try container.decodeIfPresent(Int.self, forKey: .refreshIntervalIdle),
            refreshIntervalBuilding: try container.decodeIfPresent(Int.self, forKey: .refreshIntervalBuilding),
            // An unrecognized style (say, from a newer version) falls back to the default.
            menuBarStyle: MenuBarStyle(rawValue: try value(.menuBarStyle, defaults.menuBarStyle.rawValue)) ?? defaults.menuBarStyle,
            timeFormat: TimeFormat(rawValue: try value(.timeFormat, defaults.timeFormat.rawValue)) ?? defaults.timeFormat,
            showProjects: try value(.showProjects, defaults.showProjects),
            providerStyle: ProviderStyle(rawValue: try value(.providerStyle, defaults.providerStyle.rawValue)) ?? defaults.providerStyle,
            environmentStyle: EnvironmentStyle(rawValue: try value(.environmentStyle, defaults.environmentStyle.rawValue)) ?? defaults.environmentStyle,
            checkForUpdates: try value(.checkForUpdates, true)
        )
    }

    // Tokens remain in memory for the existing UI/providers, but never enter new JSON.
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(teamId, forKey: .teamId)
        try container.encodeIfPresent(projectName, forKey: .projectName)
        try container.encodeIfPresent(cloudflareAccountIds, forKey: .cloudflareAccountIds)
        try container.encodeIfPresent(cloudflareWorkers, forKey: .cloudflareWorkers)
        try container.encodeIfPresent(gitBranches, forKey: .gitBranches)
        try container.encodeIfPresent(showProduction, forKey: .showProduction)
        try container.encodeIfPresent(showPreview, forKey: .showPreview)
        try container.encodeIfPresent(showReady, forKey: .showReady)
        try container.encodeIfPresent(showBuilding, forKey: .showBuilding)
        try container.encodeIfPresent(showError, forKey: .showError)
        try container.encodeIfPresent(showQueued, forKey: .showQueued)
        try container.encodeIfPresent(showCanceled, forKey: .showCanceled)
        try container.encodeIfPresent(limitByCount, forKey: .limitByCount)
        try container.encodeIfPresent(limitByHours, forKey: .limitByHours)
        try container.encodeIfPresent(refreshIntervalIdle, forKey: .refreshIntervalIdle)
        try container.encodeIfPresent(refreshIntervalBuilding, forKey: .refreshIntervalBuilding)
        try container.encodeIfPresent(menuBarStyle, forKey: .menuBarStyle)
        try container.encodeIfPresent(timeFormat, forKey: .timeFormat)
        try container.encodeIfPresent(showProjects, forKey: .showProjects)
        try container.encodeIfPresent(providerStyle, forKey: .providerStyle)
        try container.encodeIfPresent(environmentStyle, forKey: .environmentStyle)
        try container.encodeIfPresent(checkForUpdates, forKey: .checkForUpdates)
    }
}

final class PreferencesStore {
    static let shared = PreferencesStore()
    static let didChangeNotification = Notification.Name("PreferencesStoreDidChange")
    static let storageKey = "vercelStatusPreferences"

    private let userDefaults: UserDefaults
    private let tokens: any TokenStore
    private let canPersistPreferences: Bool
    // Retain a legacy token in its original storage until its Keychain read is confirmed.
    private var pendingLegacyTokens: [String: String] = [:]
    private var unreadProviders = Set(TokenProvider.allCases)
    private(set) var storageError: String?
    private(set) var current: Preferences

    init(userDefaults: UserDefaults = .standard, tokens: any TokenStore = KeychainTokenStore()) {
        self.userDefaults = userDefaults
        self.tokens = tokens
        let data = userDefaults.data(forKey: Self.storageKey)
        let decoded = data.flatMap { try? JSONDecoder().decode(Preferences.self, from: $0) }
        canPersistPreferences = data == nil || decoded != nil
        current = decoded ?? .default
        for provider in TokenProvider.allCases {
            let legacy = current[keyPath: provider.preference]
            if !legacy.isEmpty { pendingLegacyTokens[provider.legacyKey] = legacy }
        }
        retryTokenStorage(notify: false)
    }

    /// Only unresolved providers touch Keychain again; lifecycle events and refreshes can retry safely.
    func retryTokenStorage(notify: Bool = true) {
        guard canPersistPreferences else {
            storageError = "Couldn't read saved preferences. The original data has been kept; changes cannot be saved yet."
            return
        }
        let previous = current
        let previousError = storageError
        for provider in TokenProvider.allCases where unreadProviders.contains(provider) || pendingLegacyTokens[provider.legacyKey] != nil {
            do {
                if let legacy = pendingLegacyTokens[provider.legacyKey] {
                    // An older app can write JSON after migration: that copy is the newer credential.
                    try saveAndVerify(legacy, for: provider)
                    current[keyPath: provider.preference] = legacy
                    pendingLegacyTokens.removeValue(forKey: provider.legacyKey)
                } else {
                    current[keyPath: provider.preference] = try tokens.read(provider) ?? ""
                }
                unreadProviders.remove(provider)
            } catch {
                unreadProviders.insert(provider)
            }
        }
        storageError = unreadProviders.isEmpty && pendingLegacyTokens.isEmpty ? nil :
            "Couldn't access saved tokens in Keychain. Existing tokens have been kept; try again after unlocking your Keychain."
        persist()
        if notify && (previous != current || previousError != storageError) {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: current)
        }
    }

    private func saveAndVerify(_ token: String, for provider: TokenProvider) throws {
        try tokens.save(token, for: provider)
        guard try tokens.read(provider) == (token.isEmpty ? nil : token) else {
            throw TokenStorageError.verificationFailed
        }
    }

    func update(_ transform: (inout Preferences) -> Void) throws {
        guard canPersistPreferences else { throw TokenStorageError.verificationFailed }
        let previous = current
        var updated = current
        transform(&updated)
        do {
            for provider in TokenProvider.allCases where updated[keyPath: provider.preference] != current[keyPath: provider.preference] {
                do {
                    try saveAndVerify(updated[keyPath: provider.preference], for: provider)
                } catch {
                    unreadProviders.insert(provider)
                    throw error
                }
                unreadProviders.remove(provider)
                pendingLegacyTokens.removeValue(forKey: provider.legacyKey)
                // If the next provider fails, the confirmed change still stays in memory.
                current[keyPath: provider.preference] = updated[keyPath: provider.preference]
            }
        } catch {
            storageError = "Couldn't save a token to Keychain. Your previous saved credentials have been kept. Please try again."
            persist()
            throw error
        }
        current = updated
        retryTokenStorage(notify: false)
        persist()
        // Token changes also notify, even though they were assigned above.
        if previous != current {
            NotificationCenter.default.post(name: Self.didChangeNotification, object: current)
        }
    }

    private func persist() {
        guard canPersistPreferences else { return }
        guard let data = try? JSONEncoder().encode(current),
              var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        for (key, token) in pendingLegacyTokens { json[key] = token }
        if let saved = try? JSONSerialization.data(withJSONObject: json) {
            userDefaults.set(saved, forKey: Self.storageKey)
        }
    }
}
