import Foundation
import Security

/// Small key/value store on the iOS Keychain (NF-04). Values are UTF-8 strings (JSON for structured data).
struct Keychain: Sendable {
    static let defaultService = "io.github.halvar20000.printshare"
    /// Services `expo-secure-store` (SDK 57) writes to: `app:no-auth` for items without biometrics (the Expo build
    /// never asked for it), `app` for items of older versions. Items under `app:auth` are skipped (they would prompt).
    static let expoServices = ["app:no-auth", "app"]

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

    /// All `ps_*` entries stored by the Expo build. Layout as in expo-secure-store 57 (`SecureStoreModule.swift`):
    /// generic password, service `app:no-auth`, account and generic attribute = the key as UTF-8 *data*.
    func expoEntries() -> [String: String] {
        var found: [String: String] = [:]
        for service in Keychain.expoServices.reversed() {  // newer entries (app:no-auth) win
            for (key, value) in Keychain.expoItems(service: service) { found[key] = value }
        }
        return found
    }

    private static func expoItems(service: String) -> [String: String] {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecReturnAttributes as String: true, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitAll]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [:] }
        var found: [String: String] = [:]
        for item in items {
            guard let data = item[kSecValueData as String] as? Data, let value = String(data: data, encoding: .utf8) else { continue }
            let key = [item[kSecAttrAccount as String], item[kSecAttrGeneric as String]].lazy.compactMap(expoKey).first ?? ""
            if key.hasPrefix("ps_") { found[key] = value }
        }
        return found
    }

    /// expo-secure-store stores the key as `Data`; the account attribute may also come back as a string.
    static func expoKey(_ attribute: Any?) -> String? {
        if let s = attribute as? String { return s }
        if let d = attribute as? Data { return String(data: d, encoding: .utf8) }
        return nil
    }

    /// One-time import of server, language and printer choices from the Expo app (same bundle id, same device).
    func migrateFromExpoIfNeeded(defaults: UserDefaults = .standard) {
        let flag = "ps_migrated_expo"
        guard !defaults.bool(forKey: flag) else { return }
        defaults.set(true, forKey: flag)
        for (key, value) in expoEntries() where get(key) == nil { set(key, value) }
    }
}
