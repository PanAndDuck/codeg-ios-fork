import Foundation
import Security

/// Per-server auth-token storage. Keychain is the primary, secure store. A
/// UserDefaults fallback exists ONLY on the simulator, and ONLY when the
/// Keychain is unavailable because the build lacks an `application-identifier`
/// entitlement (`SecItemAdd` returns `errSecMissingEntitlement`, -34018) — the
/// usual state for unsigned simulator/CLI builds. The fallback code path is
/// compiled out of device/release builds entirely (`#if targetEnvironment(simulator)`),
/// so a token is never read from or written to plaintext storage on a real
/// device; there it is always the Keychain or nothing.
enum Keychain {
    private static let service = "com.codeg.ios.server-token"

    struct Credentials: Codable {
        let token: String
        let customHeaders: [HeaderPair]
    }

    static func credentials(for id: UUID) -> Credentials? {
        if let encoded = secret(account: id.uuidString + ".credentials") {
            // A damaged new item must not silently revive stale credentials.
            return try? JSONDecoder().decode(Credentials.self, from: Data(encoded.utf8))
        }
        return secret(account: id.uuidString).map { Credentials(token: $0, customHeaders: []) }
    }

    @discardableResult
    static func setCredentials(token: String, customHeaders: [HeaderPair], for id: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(Credentials(token: token, customHeaders: customHeaders)),
              let encoded = String(data: data, encoding: .utf8),
              setSecret(encoded, account: id.uuidString + ".credentials") else { return false }
        // The new item contains both secrets atomically; only now remove legacy.
        deleteSecret(account: id.uuidString)
        return true
    }

    #if targetEnvironment(simulator)
    private static let fallbackPrefix = "codeg.token.fallback."
    private static var fallback: UserDefaults { .standard }
    #endif

    /// Persist (or replace) the token for a profile. Returns `true` only when the
    /// token is now retrievable — via the Keychain, or the simulator fallback.
    /// Returns `false` on a genuine secure-storage failure so the caller can
    /// surface it instead of silently saving a server whose token was lost.
    @discardableResult
    static func setToken(_ token: String, for id: UUID) -> Bool {
        setCredentials(token: token, customHeaders: credentials(for: id)?.customHeaders ?? [], for: id)
    }

    private static func setSecret(_ secret: String, account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let data = Data(secret.utf8)

        // Add first; on a pre-existing item, update it in place. This avoids the
        // destructive delete-then-add window where a failed add after a
        // successful delete would lose the previously stored token entirely.
        var addAttributes = query
        addAttributes[kSecValueData as String] = data
        addAttributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        var status = SecItemAdd(addAttributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let changes: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            ]
            status = SecItemUpdate(query as CFDictionary, changes as CFDictionary)
        }

        if status == errSecSuccess {
            #if targetEnvironment(simulator)
            // Keychain is authoritative — clear any stale simulator fallback copy.
            fallback.removeObject(forKey: fallbackPrefix + account)
            #endif
            return true
        }

        #if targetEnvironment(simulator)
        // Unsigned simulator builds lack an application-identifier entitlement, so
        // SecItem* returns errSecMissingEntitlement (-34018). ONLY in that exact
        // case do we degrade to a UserDefaults copy so the simulator stays usable.
        if status == errSecMissingEntitlement {
            fallback.set(secret, forKey: fallbackPrefix + account)
            return true
        }
        #endif

        // A genuine Keychain failure on a real build: report it (the token did
        // not persist) rather than silently downgrading security.
        return false
    }

    static func token(for id: UUID) -> String? {
        credentials(for: id)?.token
    }

    private static func secret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data, let token = String(data: data, encoding: .utf8) {
            return token
        }
        #if targetEnvironment(simulator)
        return fallback.string(forKey: fallbackPrefix + account)
        #else
        // No plaintext fallback exists on device — a Keychain miss means no token.
        return nil
        #endif
    }

    @discardableResult
    static func deleteToken(for id: UUID) -> Bool {
        let current = deleteSecret(account: id.uuidString + ".credentials")
        let legacy = deleteSecret(account: id.uuidString)
        return current && legacy
    }

    @discardableResult
    private static func deleteSecret(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        #if targetEnvironment(simulator)
        fallback.removeObject(forKey: fallbackPrefix + account)
        #endif
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
