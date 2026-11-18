import Foundation
import Security

enum TokenProvider: String, CaseIterable {
    case vercel, cloudflare

    var legacyKey: String { rawValue + "Token" }
    var preference: WritableKeyPath<Preferences, String> {
        switch self {
        case .vercel: \.vercelToken
        case .cloudflare: \.cloudflareToken
        }
    }
}

enum TokenStorageError: Error {
    case keychain(OSStatus)
    case verificationFailed
}

protocol TokenStore {
    func read(_ provider: TokenProvider) throws -> String?
    func save(_ token: String, for provider: TokenProvider) throws
}

struct KeychainTokenStore: TokenStore {
    // Keep the historical bundle ID, including for command-line development builds.
    let service: String

    init(service: String = Bundle.main.bundleIdentifier ?? "com.andrew.vercel-deployment-menu-bar") {
        self.service = service
    }

    private func query(_ provider: TokenProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: provider.rawValue]
    }

    func read(_ provider: TokenProvider) throws -> String? {
        var query = query(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw TokenStorageError.keychain(status) }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else {
            throw TokenStorageError.verificationFailed
        }
        return token
    }

    func save(_ token: String, for provider: TokenProvider) throws {
        let query = query(provider)
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw TokenStorageError.keychain(status)
            }
            guard try read(provider) == nil else { throw TokenStorageError.verificationFailed }
            return
        }
        let attributes = [kSecValueData as String: Data(token.utf8)]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw TokenStorageError.keychain(status) }
        guard try read(provider) == token else { throw TokenStorageError.verificationFailed }
    }
}
