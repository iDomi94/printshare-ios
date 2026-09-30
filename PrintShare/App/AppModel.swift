import Foundation
import Observation

/// App-wide state: server connection, language, API client, navigation.
@MainActor
@Observable
final class AppModel {
    private(set) var ready = false
    private(set) var server: Server?
    private(set) var langPref: LangPref = .auto
    private(set) var l10n = L10n(pref: .auto)
    private(set) var api: APIClient?

    var path: [Screen] = []
    var tab: AppTab = .print
    var connectRequest: ConnectRequest?
    /// Printer slot (tool) per model colour chosen on the prepare screen, per job id: the job screen's default.
    /// Kept in memory only; after a restart the job screen picks the default slots again.
    @ObservationIgnored var plannedSlots: [String: [Int: Int]] = [:]

    @ObservationIgnored private let keychain: Keychain

    init(keychain: Keychain = Keychain()) {
        self.keychain = keychain
    }

    func load() {
        guard !ready else { return }
        keychain.migrateFromExpoIfNeeded()
        if let s: Server = keychain.getJSON(StoreKey.server), !s.url.isEmpty { server = s }
        if let raw = keychain.get(StoreKey.lang), let pref = LangPref(rawValue: raw) { langPref = pref }
        l10n = L10n(pref: langPref)
        rebuildAPI()
        ready = true
    }

    private func rebuildAPI() {
        api = server.map { APIClient(server: $0, l10n: l10n) }
    }

    func setServer(_ s: Server?) {
        server = s
        if let s { keychain.setJSON(StoreKey.server, s) } else { keychain.set(StoreKey.server, nil) }
        rebuildAPI()
    }

    func setLangPref(_ pref: LangPref) {
        langPref = pref
        keychain.set(StoreKey.lang, pref.rawValue)
        l10n = L10n(pref: pref)
        rebuildAPI()
    }

    /// Back in the foreground: maybe we left home (or came back) -> find the working address again.
    func appBecameActive() {
        Task { await APIClient.resetRoutes() }
        processInbox()
    }

    // MARK: per-printer choices (spec 4)

    func loadPrefs(_ printer: String) -> PrinterPrefs? { keychain.getJSON(StoreKey.prefs(printer)) }
    func savePrefs(_ printer: String, _ prefs: PrinterPrefs) { keychain.setJSON(StoreKey.prefs(printer), prefs) }
    func lastPrinter() -> String? { keychain.get(StoreKey.lastPrinter) }
    func saveLastPrinter(_ id: String) { keychain.set(StoreKey.lastPrinter, id) }
    func loadLevel(_ printer: String) -> Bool? { keychain.get(StoreKey.level(printer)).map { $0 == "1" } }
    func saveLevel(_ printer: String, _ on: Bool) { keychain.set(StoreKey.level(printer), on ? "1" : "0") }

    // MARK: navigation

    func push(_ screen: Screen) { path.append(screen) }

    /// Replace the top screen (Prepare -> Job must not stay on the stack).
    func replaceTop(with screen: Screen) {
        if !path.isEmpty { path.removeLast() }
        path.append(screen)
    }

    /// Back to the tabs and select one (`router.navigate` in the Expo app).
    func navigate(to tab: AppTab) {
        path.removeAll()
        self.tab = tab
    }

    func showConnect(_ request: ConnectRequest = ConnectRequest()) {
        connectRequest = request
    }

    func open(_ url: URL) {
        switch DeepLink.parse(url) {
        case .connect(let s): showConnect(ConnectRequest(server: s, autoConnect: true))
        case .share: processInbox()
        case .other: break
        }
    }

    /// Links or files shared from Safari, Files … open the prepare screen (MQ-01, MQ-03).
    func processInbox() {
        SharedInbox.purge()
        guard ready, let item = SharedInbox.peek() else { return }
        guard server != nil else {
            if connectRequest == nil { showConnect() }  // the shared item waits until the server is connected
            return
        }
        SharedInbox.clear()
        if let rel = item.file, let url = SharedInbox.fileURL(rel) {
            push(.prepare(PrepareArgs(fileURL: url, fileName: item.fileName ?? "model.stl")))
            return
        }
        var link = Format.extractLink(item.url)
        if link.isEmpty { link = Format.extractLink(item.text) }
        if !link.isEmpty { push(.prepare(PrepareArgs(link: link))) }
    }
}
