import Foundation
import Security

/// Small key/value store on the iOS Keychain (NF-04). Values are UTF-8 strings (JSON for structured data).
struct Keychain: Sendable {
    static let defaultService = "io.github.halvar20000.printshare"
    /// Service name `expo-secure-store` used, for the migration from the Expo build.
    static let expoService = "app"

    let service: String

    init(service: String = Keychain.defaultService) { self.service = service }

    private func query(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }

    func get(_ key: String) -> String? {
        var q = query(key)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// nil removes the entry. Storage problems are ignored: the app keeps working for this session.
    func set(_ key: String, _ value: String?) {
        SecItemDelete(query(key) as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var q = query(key)
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(q as CFDictionary, nil)
    }

    func getJSON<T: Decodable>(_ key: String, as type: T.Type = T.self) -> T? {
        guard let raw = get(key), let data = raw.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    func setJSON<T: Encodable>(_ key: String, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        set(key, String(data: data, encoding: .utf8))
    }

    /// All `ps_*` entries stored by the Expo build (best effort - the layout is that of expo-secure-store).
    func expoEntries() -> [String: String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Keychain.expoService,
                                kSecReturnAttributes as String: true, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [:] }
        var found: [String: String] = [:]
        for item in items {
            guard let data = item[kSecValueData as String] as? Data, let value = String(data: data, encoding: .utf8) else { continue }
            let account = (item[kSecAttrAccount as String] as? String) ?? ""
            let generic = (item[kSecAttrGeneric as String] as? Data).flatMap { String(data: $0, encoding: .utf8) } ?? ""
            for key in [account, generic] where key.hasPrefix("ps_") { found[key] = value }
        }
        return found
    }

    /// One-time import of server, language and printer choices from the Expo app (same bundle id, same device).
    func migrateFromExpoIfNeeded(defaults: UserDefaults = .standard) {
        let flag = "ps_migrated_expo"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        for (key, value) in expoEntries() where get(key) == nil { set(key, value) }
    }
}
