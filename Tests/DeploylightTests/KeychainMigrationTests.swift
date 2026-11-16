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

    func testConflictingKeychainItemNeverDiscardsEitherToken() throws {
        try withStorage { defaults, tokens in
            try tokens.save("other-credential", for: .vercel)
            defaults.set(Data(#"{"vercelToken":"legacy-credential","cloudflareToken":"test-cf"}"#.utf8), forKey: PreferencesStore.storageKey)
            let store = PreferencesStore(userDefaults: defaults, tokens: tokens)
            XCTAssertNotNil(store.storageError)
            XCTAssertEqual(store.current.vercelToken, "legacy-credential")
            XCTAssertEqual(try tokens.read(.vercel), "other-credential")
            try store.update { $0.showProjects = false }
            XCTAssertEqual(try savedJSON(defaults)["vercelToken"] as? String, "legacy-credential")
            XCTAssertNil(try savedJSON(defaults)["cloudflareToken"])
            XCTAssertEqual(try tokens.read(.cloudflare), "test-cf")
            let reopened = PreferencesStore(userDefaults: defaults, tokens: tokens)
            XCTAssertEqual(reopened.current.vercelToken, "legacy-credential")
            XCTAssertEqual(try tokens.read(.vercel), "other-credential")
        }
    }
}
