import Security
import XCTest
@testable import PrintShare

/// Import from the Expo build, with items written exactly like expo-secure-store 57 does (service `app:no-auth`,
/// account and generic attribute = the key as UTF-8 data).
final class KeychainMigrationTests: XCTestCase {
    private func expoQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "app:no-auth",
         kSecAttrGeneric as String: Data(key.utf8), kSecAttrAccount as String: Data(key.utf8)]
    }

    func testImportsExpoSecureStoreItems() throws {
        let key = "ps_test_\(UUID().uuidString.prefix(8))"
        var add = expoQuery(key)
        add[kSecValueData as String] = Data("{\"url\":\"http://tower:8484\"}".utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecMissingEntitlement { throw XCTSkip("no keychain access in this test host") }
        XCTAssertEqual(status, errSecSuccess)
        defer { SecItemDelete(expoQuery(key) as CFDictionary) }

        let target = Keychain(service: "printshare-tests-\(UUID().uuidString)")
        defer { target.set(key, nil) }
        let suite = "printshare-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(target.expoEntries()[key], "{\"url\":\"http://tower:8484\"}")
        target.migrateFromExpoIfNeeded(defaults: defaults)
        XCTAssertEqual(target.get(key), "{\"url\":\"http://tower:8484\"}")
    }

    func testExpoKeyAcceptsDataAndString() {
        XCTAssertEqual(Keychain.expoKey(Data("ps_server".utf8)), "ps_server")
        XCTAssertEqual(Keychain.expoKey("ps_lang"), "ps_lang")
        XCTAssertNil(Keychain.expoKey(nil))
    }
}
