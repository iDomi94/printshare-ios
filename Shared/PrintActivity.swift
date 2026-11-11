import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

/// A print on the lock screen / in the Dynamic Island (server 0.51.0). The type name is part of the server's
/// push-to-start payload (`attributes-type`), the field names are the server's content state keys - keep both.
struct PrintActivityAttributes: Codable, Hashable, Sendable {
    /// Content state as the server sends it through the push relay: numbers and a state code only.
    struct ContentState: Codable, Hashable, Sendable {
        /// sending | waking | decision | printing | paused | done | cancelled | error | failed
        var s: String
        /// 0-100
        var p: Int?
        /// Expected end (unix seconds) while printing.
        var end: Int?
        /// Layer / layers.
        var l: Int?
        var lt: Int?

        init(s: String, p: Int? = nil, end: Int? = nil, l: Int? = nil, lt: Int? = nil) {
            self.s = s; self.p = p; self.end = end; self.l = l; self.lt = lt
        }

        var endDate: Date? { end.map { Date(timeIntervalSince1970: TimeInterval($0)) } }
        var progress: Double { Double(min(max(p ?? 0, 0), 100)) / 100 }
        var isOver: Bool { ["done", "cancelled", "failed"].contains(s) }
    }

    var job: String
    var printer: String
}

#if canImport(ActivityKit)
extension PrintActivityAttributes: ActivityAttributes {}
#endif

/// What the app, the notification service and the widget share through the App Group (no secrets beyond the push key,
/// which only decrypts notification texts).
enum PushShared {
    static let groupID = "group.com.dominiqueherbrigpersonalteam.printshare"
    private static let keyName = "push.key"
    private static let namesName = "push.printerNames"
    private static let langName = "push.lang"

    static var defaults: UserDefaults? { UserDefaults(suiteName: groupID) }

    /// The phone's notification key (32 bytes, base64); created once.
    static func key(create: Bool = false) -> String? {
        if let k = defaults?.string(forKey: keyName), !k.isEmpty { return k }
        guard create else { return nil }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        let k = Data(bytes).base64EncodedString()
        defaults?.set(k, forKey: keyName)
        return k
    }

    /// Printer id → name, so the widget can show names the server never sends through the relay.
    static func printerName(_ id: String) -> String? {
        (defaults?.dictionary(forKey: namesName) as? [String: String])?[id]
    }

    static func savePrinterNames(_ names: [String: String]) {
        var all = (defaults?.dictionary(forKey: namesName) as? [String: String]) ?? [:]
        all.merge(names) { _, new in new }
        defaults?.set(all, forKey: namesName)
    }

    /// "de" or "en": the app's language for the widget.
    static var lang: String {
        get { defaults?.string(forKey: langName) ?? (Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en") }
        set { defaults?.set(newValue, forKey: langName) }
    }
}
