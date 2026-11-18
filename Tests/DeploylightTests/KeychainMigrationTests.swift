import XCTest
@testable import Deploylight

final class KeychainMigrationTests: XCTestCase {
    private func withStorage(_ body: (UserDefaults, KeychainTokenStore) throws -> Void) throws {
        let name = "DeploylightTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = KeychainTokenStore(service: name)
        defer {
            defaults.removePersistentDomain(forName: name)
            for provider in TokenProvider.allCases { try? tokens.save("", for: provider) }
        }
        try body(defaults, tokens)
    }

    private func savedJSON(_ defaults: UserDefaults) throws -> [String: Any] {
        let data = try XCTUnwrap(defaults.data(forKey: PreferencesStore.storageKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testMigratesBothTokensAndReopensFromKeychain() throws {
        try withStorage { defaults, tokens in
            let legacy = #"{"vercelToken":"test-vercel","cloudflareToken":"test-cloudflare","teamId":"team","showPreview":false}"#
            defaults.set(Data(legacy.utf8), forKey: PreferencesStore.storageKey)
            let store = PreferencesStore(userDefaults: defaults, tokens: tokens)
            XCTAssertNil(store.storageError)
            XCTAssertEqual(try tokens.read(.vercel), "test-vercel")
            XCTAssertEqual(try tokens.read(.cloudflare), "test-cloudflare")
            XCTAssertEqual(store.current.vercelToken, "test-vercel")
            XCTAssertEqual(store.current.cloudflareToken, "test-cloudflare")
            let saved = try savedJSON(defaults)
            XCTAssertNil(saved["vercelToken"])
            XCTAssertNil(saved["cloudflareToken"])
            XCTAssertEqual(saved["teamId"] as? String, "team")
            XCTAssertEqual(saved["showPreview"] as? Bool, false)
            let reopened = PreferencesStore(userDefaults: defaults, tokens: tokens)
            XCTAssertEqual(reopened.current, store.current)
            // Editing and clearing use Keychain too, with no credential in the JSON.
            try reopened.update { $0.vercelToken = "replacement"; $0.cloudflareToken = ""; $0.checkForUpdates = false }
            let edited = PreferencesStore(userDefaults: defaults, tokens: tokens)
            XCTAssertEqual(edited.current.vercelToken, "replacement")
            XCTAssertEqual(edited.current.cloudflareToken, "")
            XCTAssertFalse(edited.current.checkForUpdates)
            XCTAssertNil(try tokens.read(.cloudflare))
            XCTAssertNil(try savedJSON(defaults)["vercelToken"])
            XCTAssertNil(try savedJSON(defaults)["cloudflareToken"])
        }
    }

    func testGitHubTokenRoundTripsThroughKeychainOnly() throws {
        try withStorage { defaults, tokens in
            let store = PreferencesStore(userDefaults: defaults, tokens: tokens)
            XCTAssertFalse(store.current.hasGitHubToken)
            try store.update {
                $0.githubToken = "fixture-github"
                $0.githubRepositories = "owner/worker"
                $0.githubWorkflows = "owner/worker#123"
            }
            XCTAssertEqual(try tokens.read(.github), "fixture-github")
            XCTAssertNil(try savedJSON(defaults)["githubToken"])
            let reopened = PreferencesStore(userDefaults: defaults, tokens: tokens)
            XCTAssertEqual(reopened.current, store.current)
            try reopened.update { $0.githubToken = "" }
            XCTAssertNil(try tokens.read(.github))
            XCTAssertFalse(PreferencesStore(userDefaults: defaults, tokens: tokens).current.hasGitHubToken)
            XCTAssertNil(try savedJSON(defaults)["githubToken"])
        }
    }

    func testInterruptedMigrationWithMatchingKeychainCopyFinishesSafely() throws {
        try withStorage { defaults, tokens in
            try tokens.save("test-vercel", for: .vercel)
            defaults.set(Data(#"{"vercelToken":"test-vercel"}"#.utf8), forKey: PreferencesStore.storageKey)
            let store = PreferencesStore(userDefaults: defaults, tokens: tokens)
            XCTAssertNil(store.storageError)
            XCTAssertEqual(store.current.vercelToken, "test-vercel")
            XCTAssertNil(try savedJSON(defaults)["vercelToken"])
        }
    }

    func testNewerPlaintextTokenReplacesConflictingKeychainItem() throws {
        try withStorage { defaults, tokens in
            try tokens.save("older-credential", for: .vercel)
            defaults.set(Data(#"{"vercelToken":"newer-credential","cloudflareToken":"test-cf"}"#.utf8), forKey: PreferencesStore.storageKey)
            let store = PreferencesStore(userDefaults: defaults, tokens: tokens)
            XCTAssertNil(store.storageError)
            XCTAssertEqual(store.current.vercelToken, "newer-credential")
            XCTAssertEqual(try tokens.read(.vercel), "newer-credential")
            XCTAssertNil(try savedJSON(defaults)["vercelToken"])
            XCTAssertNil(try savedJSON(defaults)["cloudflareToken"])
            let reopened = PreferencesStore(userDefaults: defaults, tokens: tokens)
            XCTAssertEqual(reopened.current, store.current)
        }
    }

    func testLegacyTokenSurvivesFailedMigrationAndUnchangedEditRetries() throws {
        try withStorage { defaults, _ in
            let tokens = FailingTokenStore()
            tokens.failingProviders = [.vercel]
            defaults.set(Data(#"{"vercelToken":"newer-credential","cloudflareToken":"test-cf"}"#.utf8), forKey: PreferencesStore.storageKey)
            let store = PreferencesStore(userDefaults: defaults, tokens: tokens)
            XCTAssertNotNil(store.storageError)
            XCTAssertEqual(try savedJSON(defaults)["vercelToken"] as? String, "newer-credential")
            XCTAssertNil(try savedJSON(defaults)["cloudflareToken"])
            try store.update { $0.showProjects = false }
            XCTAssertNotNil(store.storageError)
            XCTAssertEqual(try savedJSON(defaults)["vercelToken"] as? String, "newer-credential")
            tokens.failingProviders = []
            try store.update { $0.vercelToken = "newer-credential" }
            XCTAssertNil(store.storageError)
            XCTAssertEqual(try tokens.read(.vercel), "newer-credential")
            XCTAssertNil(try savedJSON(defaults)["vercelToken"])
            XCTAssertFalse(store.current.showProjects)
        }
    }

    func testMigratedInstallRetriesUnreadTokenWithoutErasingIt() throws {
        try withStorage { defaults, _ in
            let tokens = FailingTokenStore()
            tokens.values = [.vercel: "saved-vercel", .cloudflare: "saved-cf"]
            tokens.failingProviders = [.vercel]
            let store = PreferencesStore(userDefaults: defaults, tokens: tokens)
            XCTAssertNotNil(store.storageError)
            XCTAssertEqual(store.current.vercelToken, "")
            try store.update { $0.showProjects = false }
            XCTAssertNotNil(store.storageError)
            XCTAssertEqual(tokens.values[.vercel], "saved-vercel")
            tokens.failingProviders = []
            store.retryTokenStorage()
            XCTAssertNil(store.storageError)
            XCTAssertEqual(store.current.vercelToken, "saved-vercel")
            XCTAssertEqual(store.current.cloudflareToken, "saved-cf")
            XCTAssertNil(try savedJSON(defaults)["vercelToken"])
        }
    }

    func testFailedReadbackKeepsPlaintextUntilVerified() throws {
        try withStorage { defaults, _ in
            let tokens = FailingTokenStore()
            tokens.failReadback = true
            defaults.set(Data(#"{"vercelToken":"newer-credential"}"#.utf8), forKey: PreferencesStore.storageKey)
            let store = PreferencesStore(userDefaults: defaults, tokens: tokens)
            XCTAssertNotNil(store.storageError)
            XCTAssertEqual(tokens.values[.vercel], "newer-credential")
            XCTAssertEqual(try savedJSON(defaults)["vercelToken"] as? String, "newer-credential")
            tokens.failReadback = false
            store.retryTokenStorage()
            XCTAssertNil(store.storageError)
            XCTAssertNil(try savedJSON(defaults)["vercelToken"])
        }
    }

    func testUnreadablePreferencesAreNeverOverwrittenByDefaults() throws {
        try withStorage { defaults, tokens in
            let original = Data(#"{"vercelToken":"legacy-credential","showProjects":"invalid"}"#.utf8)
            defaults.set(original, forKey: PreferencesStore.storageKey)
            let store = PreferencesStore(userDefaults: defaults, tokens: tokens)
            XCTAssertNotNil(store.storageError)
            XCTAssertThrowsError(try store.update { $0.showProjects = false })
            XCTAssertEqual(defaults.data(forKey: PreferencesStore.storageKey), original)
            XCTAssertNil(try tokens.read(.vercel))
        }
    }

}

private final class FailingTokenStore: TokenStore {
    var values: [TokenProvider: String] = [:]
    var failingProviders: Set<TokenProvider> = []
    var failReadback = false

    func read(_ provider: TokenProvider) throws -> String? {
        if failingProviders.contains(provider) || (failReadback && values[provider] != nil) {
            throw TokenStorageError.verificationFailed
        }
        return values[provider]
    }

    func save(_ token: String, for provider: TokenProvider) throws {
        guard !failingProviders.contains(provider) else { throw TokenStorageError.verificationFailed }
        values[provider] = token.isEmpty ? nil : token
    }
}
