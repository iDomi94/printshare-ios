import ActivityKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// What a tap on a notification asks for, taken out of the (non-Sendable) notification response.
struct PushTap: Sendable, Equatable {
    var action: String
    var event: String?
    var job: String?
    var printer: String?
}

/// Notification categories and their buttons (server 0.51.0 sends `SLOT_CHECK` and `AI_ALERT`).
enum PushCategory {
    static let slotCheck = "SLOT_CHECK"
    static let aiAlert = "AI_ALERT"
    static let checkAction = "CHECK"
    static let abortAction = "ABORT"
    static let pauseAction = "PAUSE"

    @MainActor
    static func register(_ t: L10n) {
        // "print anyway" is not offered here: a start always goes through the app's confirmation dialog (NF-05)
        let check = UNNotificationAction(identifier: checkAction, title: t(.notifyCheck), options: [.foreground])
        let abort = UNNotificationAction(identifier: abortAction, title: t(.notifyAbort),
                                         options: [.destructive, .authenticationRequired])
        let pause = UNNotificationAction(identifier: pauseAction, title: t(.notifyPause), options: [.authenticationRequired])
        UNUserNotificationCenter.current().setNotificationCategories([
            UNNotificationCategory(identifier: slotCheck, actions: [check, abort], intentIdentifiers: []),
            UNNotificationCategory(identifier: aiAlert, actions: [pause], intentIdentifiers: []),
        ])
    }
}

enum PushError: Error, Equatable {
    case denied, noToken, notConnected, relayOff
}

extension Data {
    /// APNs tokens are sent as lowercase hex.
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}

/// Push notifications and Live Activities (server 0.51.0, docs/PUSH.md of the server).
///
/// The phone registers its APNs token at the push relay (PocketPrint3D Cloud), which answers with a handle; the handle
/// and the phone's own encryption key go to the connected server. The server encrypts the texts with that key, the
/// notification service extension decrypts them. Live Activities: started here for a print the user starts, or by the
/// server (push-to-start) for prints started elsewhere; each one's update token goes the same way.
@MainActor
@Observable
final class PushNotifications {
    static let shared = PushNotifications()

    /// Per server / account: what this phone registered there.
    struct Record: Codable, Equatable {
        var device: String
        var relay: String
        var token: String
        var activities: Bool = true
    }

    private(set) var token: String?
    @ObservationIgnored private weak var app: AppModel?
    @ObservationIgnored private var tokenWaiters: [CheckedContinuation<String?, Never>] = []
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var watched: Set<String> = []
    @ObservationIgnored private var registering = false
    /// A tap that launched the app before it was ready.
    @ObservationIgnored private var pendingTap: PushTap?

    /// Xcode builds talk to Apple's sandbox, TestFlight / App Store builds to production.
    nonisolated static var env: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }

    func attach(_ app: AppModel) {
        self.app = app
        PushCategory.register(app.l10n)
        PushShared.lang = app.l10n.lang.rawValue
        observeActivities()
        // a new token (restore, reinstall) has to reach the relay again
        if record() != nil { UIApplication.shared.registerForRemoteNotifications() }
        if let tap = pendingTap {
            pendingTap = nil
            Task { await handle(tap) }
        }
    }

    // MARK: record per server

    private var recordKey: String? {
        app?.server.map { "ps_push_" + ($0.email ?? $0.url).replacingRegex("[^A-Za-z0-9_.-]", with: "_") }
    }

    func record() -> Record? {
        guard let recordKey, let data = UserDefaults.standard.data(forKey: recordKey) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private func save(_ rec: Record?) {
        guard let recordKey else { return }
        if let rec, let data = try? JSONEncoder().encode(rec) {
            UserDefaults.standard.set(data, forKey: recordKey)
        } else {
            UserDefaults.standard.removeObject(forKey: recordKey)
        }
    }

    // MARK: APNs token

    func didRegister(token data: Data) {
        let hex = data.hexString
        let changed = token != nil && token != hex
        token = hex
        for w in tokenWaiters { w.resume(returning: hex) }
        tokenWaiters.removeAll()
        if !registering, let rec = record(), rec.token != hex || changed {
            Task { try? await self.register(replacing: rec) }
        }
    }

    func didFailToRegister() {
        for w in tokenWaiters { w.resume(returning: nil) }
        tokenWaiters.removeAll()
    }

    private func awaitToken() async -> String? {
        if let token { return token }
        UIApplication.shared.registerForRemoteNotifications()
        return await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            tokenWaiters.append(c)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(20))
                self.didFailToRegister()            // no answer from Apple: give up (nothing waits any more otherwise)
            }
        }
    }

    // MARK: on / off

    /// Ask for permission, register at the relay and at the server. Returns this phone's device on the server.
    @discardableResult
    func enable() async throws -> PushDevice {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        guard granted else { throw PushError.denied }
        return try await register(replacing: record())
    }

    private func register(replacing old: Record?) async throws -> PushDevice {
        guard let app, let api = app.api else { throw PushError.notConnected }
        registering = true
        defer { registering = false }
        guard let token = await awaitToken() else { throw PushError.noToken }
        let info = try await api.pushInfo()
        let relay: String
        if info.relayHere {
            relay = await api.baseURL()
        } else if let r = info.relay, !r.isEmpty, r != "off" {
            relay = r
        } else {
            throw PushError.relayOff
        }
        guard let key = PushShared.key(create: true) else { throw PushError.noToken }
        let handle = try await Self.registerToken(relay: relay, token: token, kind: "device")
        let prefs = old.flatMap { o in info.devices.first { $0.id == o.device }?.prefs }
        if let old, old.device != "" { try? await api.removePushDevice(id: old.device) }
        let device = try await api.addPushDevice(handle, key: key, lang: app.l10n.lang.rawValue,
                                                 name: UIDevice.current.name, prefs: prefs)
        save(Record(device: device.id, relay: relay, token: token, activities: device.prefs.activities))
        await savePrinterNames()
        if #available(iOS 17.2, *), let start = Activity<PrintActivityAttributes>.pushToStartToken {
            await syncStartToken(start.hexString)
        }
        return device
    }

    func disable() async {
        if let rec = record() { try? await app?.api?.removePushDevice(id: rec.device) }
        save(nil)
    }

    /// This phone's entry on the server (nil: not registered there, or the server forgot it).
    func device() async throws -> PushDevice? {
        guard let rec = record(), let api = app?.api else { return nil }
        return try await api.pushInfo().devices.first { $0.id == rec.device }
    }

    func setPrefs(_ prefs: PushPrefs) async throws -> PushDevice {
        guard var rec = record(), let api = app?.api else { throw PushError.notConnected }
        let device = try await api.updatePushDevice(id: rec.device, PushDeviceUpdate(prefs: prefs))
        rec.activities = device.prefs.activities
        save(rec)
        return device
    }

    func test() async throws {
        guard let rec = record(), let api = app?.api else { throw PushError.notConnected }
        try await api.testPush(device: rec.device)
    }

    /// The app's language changed: the server writes the texts in it.
    func languageChanged() {
        guard let app else { return }
        PushShared.lang = app.l10n.lang.rawValue
        PushCategory.register(app.l10n)
        guard let rec = record(), let api = app.api else { return }
        let lang = app.l10n.lang.rawValue
        Task { _ = try? await api.updatePushDevice(id: rec.device, PushDeviceUpdate(lang: lang)) }
    }

    private func savePrinterNames() async {
        guard let printers = try? await app?.api?.printers() else { return }
        PushShared.savePrinterNames(Dictionary(printers.map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a }))
    }

    // MARK: relay

    nonisolated static func registerToken(relay: String, token: String, kind: String) async throws -> PushHandle {
        guard let url = URL(string: relay.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/push/register"),
              url.scheme != nil else { throw PushError.relayOff }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["token": token, "kind": kind, "env": env, "platform": "ios"])
        let (data, res) = try await URLSession.shared.data(for: req)
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw APIError(message: "push relay: HTTP \(status)", status: status, detail: String(decoding: data, as: UTF8.self))
        }
        return try JSONDecoder().decode(PushHandle.self, from: data)
    }

    // MARK: Live Activities

    private func observeActivities() {
        guard !observing else { return }
        observing = true
        for a in Activity<PrintActivityAttributes>.activities { watch(a) }
        Task {
            for await a in Activity<PrintActivityAttributes>.activityUpdates { self.watch(a) }
        }
        if #available(iOS 17.2, *) {
            Task {
                for await data in Activity<PrintActivityAttributes>.pushToStartTokenUpdates {
                    await self.syncStartToken(data.hexString)
                }
            }
        }
    }

    /// Every activity (started here or by the server) hands its update token to the server through the relay.
    private func watch(_ activity: Activity<PrintActivityAttributes>) {
        guard !watched.contains(activity.id) else { return }
        watched.insert(activity.id)
        let job = activity.attributes.job
        Task {
            for await data in activity.pushTokenUpdates {
                await self.registerActivity(job: job, token: data.hexString)
            }
        }
    }

    private func registerActivity(job: String, token: String) async {
        guard let rec = record(), let api = app?.api else { return }
        do {
            let handle = try await Self.registerToken(relay: rec.relay, token: token, kind: "activity")
            try await api.registerLiveActivity(job: job, handle, device: rec.device)
        } catch {
            // the server just doesn't update this activity; it ends by itself
        }
    }

    private func syncStartToken(_ token: String) async {
        guard let rec = record(), let api = app?.api else { return }
        do {
            let handle = try await Self.registerToken(relay: rec.relay, token: token, kind: "start")
            _ = try await api.updatePushDevice(id: rec.device, PushDeviceUpdate(startHandle: handle.handle,
                                                                                startSecret: handle.secret))
        } catch {
            // no push-to-start: prints started elsewhere just don't get a Live Activity
        }
    }

    /// A print the user starts from the app (own server or bridge): show it on the lock screen right away; the server
    /// keeps it up to date and ends it.
    func startActivity(job: String, printer: String, name: String) {
        guard let rec = record(), rec.activities, ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard !Activity<PrintActivityAttributes>.activities.contains(where: { $0.attributes.job == job }) else { return }
        PushShared.savePrinterNames([printer: name])
        let content = ActivityContent(state: PrintActivityAttributes.ContentState(s: "sending", p: 0),
                                      staleDate: Date().addingTimeInterval(30 * 60))
        if let a = try? Activity.request(attributes: PrintActivityAttributes(job: job, printer: printer), content: content,
                                         pushType: .token) {
            watch(a)
        }
    }

    // MARK: taps

    func handle(_ tap: PushTap) async {
        guard let app, app.ready else { pendingTap = tap; return }
        switch tap.action {
        case PushCategory.abortAction:
            if let job = tap.job { try? await app.api?.decide(job: job, start: false) }
        case PushCategory.pauseAction:
            if let p = tap.printer { try? await app.api?.control(printer: p, action: "pause") }
        case UNNotificationDismissActionIdentifier:
            break
        default:
            if let job = tap.job { app.openJob(job) } else if tap.printer != nil { app.tab = .printers }
        }
    }
}

/// APNs callbacks and notification taps.
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushNotifications.shared.didRegister(token: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushNotifications.shared.didFailToRegister()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let tap = PushTap(action: response.actionIdentifier, event: info["event"] as? String, job: info["job"] as? String,
                          printer: info["printer"] as? String)
        await PushNotifications.shared.handle(tap)
    }
}
