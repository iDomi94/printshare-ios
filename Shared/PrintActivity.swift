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
        /// Server 0.54.0: 1 while heating up before the first layer.
        var h: Int?
        /// Server 0.54.0: nozzle / bed actual and target, chamber - whole °C.
        var tn: Int?
        var tnt: Int?
        var tb: Int?
        var tbt: Int?
        var tc: Int?

        init(s: String, p: Int? = nil, end: Int? = nil, l: Int? = nil, lt: Int? = nil, h: Int? = nil,
             tn: Int? = nil, tnt: Int? = nil, tb: Int? = nil, tbt: Int? = nil, tc: Int? = nil) {
            self.s = s; self.p = p; self.end = end; self.l = l; self.lt = lt; self.h = h
            self.tn = tn; self.tnt = tnt; self.tb = tb; self.tbt = tbt; self.tc = tc
        }

        var heating: Bool { s == "printing" && (h ?? 0) != 0 }
        var hasTemperatures: Bool { tn != nil || tb != nil }

        /// Which of the `ActivityImages.frames` layer pictures fits (same rule as the server's `notify.frame`).
        var frame: Int {
            if let lt, lt > 0, let l { return min(max(l * ActivityImages.frames / lt, 0), ActivityImages.frames) }
            if s == "done" { return ActivityImages.frames }
            return min(max((p ?? 0) * ActivityImages.frames / 100, 0), ActivityImages.frames)
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

    private static let serversName = "push.servers"

    /// Device id on a server → its addresses (home, away), so the notification service can load a notification's
    /// camera picture from the server that sent it (0.9.20).
    static func serverURLs(device: String) -> [String] {
        ((defaults?.dictionary(forKey: serversName) as? [String: [String]])?[device] ?? []).filter { !$0.isEmpty }
    }

    static func saveServerURLs(device: String, _ urls: [String]) {
        var all = (defaults?.dictionary(forKey: serversName) as? [String: [String]]) ?? [:]
        all[device] = urls.filter { !$0.isEmpty }
        defaults?.set(all, forKey: serversName)
    }

    /// "de" or "en": the app's language for the widget.
    static var lang: String {
        get { defaults?.string(forKey: langName) ?? (Locale.preferredLanguages.first?.hasPrefix("de") == true ? "de" : "en") }
        set { defaults?.set(newValue, forKey: langName) }
    }
}

/// Pictures of a running print for the Live Activity (and the printer list): the app puts them into the App Group,
/// the widget only reads them (it can't go online, and Live Activity pushes carry no pictures).
///
/// `<group>/activity/<job>/f<n>.png`: the print up to `n / frames` of its layers, rendered by the app from the G-code
/// preview when the activity starts; `camera.jpg`: the last camera picture (button in the Live Activity).
enum ActivityImages {
    static let frames = 24
    /// A camera picture newer than this replaces the layer picture even when the user prefers the preview.
    static let cameraFresh: TimeInterval = 10 * 60

    enum Mode: String, CaseIterable, Sendable { case preview, camera, none }

    private static let modeName = "activity.imageMode"

    /// What the Live Activity shows next to the progress (Settings → Notifications).
    static var mode: Mode {
        get { PushShared.defaults?.string(forKey: modeName).flatMap(Mode.init(rawValue:)) ?? .preview }
        set { PushShared.defaults?.set(newValue.rawValue, forKey: modeName) }
    }

    static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: PushShared.groupID)?
            .appendingPathComponent("activity", isDirectory: true)
    }

    static func folder(_ job: String) -> URL? {
        guard job.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil else { return nil }
        return root?.appendingPathComponent(job, isDirectory: true)
    }

    static func frameURL(_ job: String, _ n: Int) -> URL? { folder(job)?.appendingPathComponent("f\(n).png") }
    static func cameraURL(_ job: String) -> URL? { folder(job)?.appendingPathComponent("camera.jpg") }
    /// Written when the job has no preview (started at the printer): don't try again.
    static func noPreviewURL(_ job: String) -> URL? { folder(job)?.appendingPathComponent("none") }

    static func hasFrames(_ job: String) -> Bool {
        guard let u = frameURL(job, frames) else { return false }
        return FileManager.default.fileExists(atPath: u.path)
    }

    /// The layer picture closest below `frame` (frames may be missing for very short prints).
    static func frameFile(_ job: String, _ frame: Int) -> URL? {
        var n = min(max(frame, 0), frames)
        while n >= 0 {
            if let u = frameURL(job, n), FileManager.default.fileExists(atPath: u.path) { return u }
            n -= 1
        }
        return nil
    }

    /// The camera picture and when it was taken.
    static func camera(_ job: String) -> (url: URL, at: Date)? {
        guard let u = cameraURL(job),
              let at = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date else { return nil }
        return (u, at)
    }

    enum Pick: Equatable { case frame(URL), camera(URL, Date) }

    /// What to show for this state: the preference, a fresh camera picture wins over the preview.
    static func pick(job: String, state: PrintActivityAttributes.ContentState, mode: Mode = mode, now: Date = Date()) -> Pick? {
        if mode == .none { return nil }
        let cam = camera(job)
        if let cam, mode == .camera || now.timeIntervalSince(cam.at) < cameraFresh { return .camera(cam.url, cam.at) }
        if let f = frameFile(job, state.frame) { return .frame(f) }
        if let cam { return .camera(cam.url, cam.at) }
        return nil
    }
}
