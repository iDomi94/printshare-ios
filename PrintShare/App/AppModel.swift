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

    // MARK: printers - through the own server, or in the cloud by the app itself on the home Wi-Fi (server 0.15.0)

    var isCloud: Bool { server?.isCloud ?? false }

    /// The printers' Wi-Fi addresses (and PrusaLink passwords / API keys) stay on this phone, in the Keychain, per
    /// account - the cloud never sees them (docs/CLOUD.md).
    private var lanKey: String? {
        server.map { StoreKey.lan(($0.email ?? $0.url).replacingRegex("[^A-Za-z0-9_.-]", with: "_")) }
    }

    func lanAccess() -> [String: LanAccess] {
        lanKey.flatMap { keychain.getJSON($0, as: [String: LanAccess].self) } ?? [:]
    }

    /// nil (or no address) forgets the printer.
    func saveLanAccess(_ printer: String, _ access: LanAccess?) {
        guard let lanKey else { return }
        var all = lanAccess()
        all[printer] = access?.cleaned
        keychain.setJSON(lanKey, all)
    }

    private func lanPrinter(_ p: Printer) throws -> any LanPrinter {
        guard Lan.canRelay(p.type) else { throw LanError("this printer type can only be used with an own server for now") }
        guard let access = lanAccess()[p.id], !access.address.isEmpty else { throw NoLanAddress() }
        return try Lan.printer(type: p.type, access: access)
    }

    private func requireAPI() throws -> APIClient {
        guard let api else { throw APIError(message: l10n(.notConnected)) }
        return api
    }

    /// Own servers and printers behind a bridge (server 0.26.0) are reached through the server; other cloud printers
    /// by this phone on the Wi-Fi.
    func viaServer(_ p: Printer) -> Bool { !isCloud || p.bridge != nil }

    func printerStatus(_ p: Printer) async throws -> PrinterStatus {
        guard !viaServer(p) else { return try await requireAPI().status(printer: p.id) }
        let lan = try lanPrinter(p)
        defer { Task { await lan.close() } }
        return try await lan.status()
    }

    /// Pause / resume / cancel. A cancel is only sent after the user confirmed it.
    func printerControl(_ p: Printer, action: String) async throws {
        guard !viaServer(p) else { return try await requireAPI().control(printer: p.id, action: action) }
        let lan = try lanPrinter(p)
        defer { Task { await lan.close() } }
        try await lan.control(action)
    }

    /// Cloud: download the sliced G-code (slots already mapped by the server) and send it to the printer. Bambu: the
    /// trays go to the printer as `ams_mapping` instead, the G-code stays as sliced.
    func relay(job: String, printer p: Printer, fileName: String, lanes: [Int: Int]?, options: SendOptions) async throws {
        let api = try requireAPI()
        let lan = try lanPrinter(p)
        defer { Task { await lan.close() } }
        var options = options
        let bambu = p.type == "bambu_lan"
        if bambu, let lanes { options.tools = lanes }
        options.onStep?(.download)
        let file = try await api.downloadGcode(job: job, name: fileName, lanes: bambu ? nil : lanes)
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try await lan.send(file: file, name: fileName, options: options)
    }

    // MARK: Spoolman (spec MA-07, server 0.16.0) - everything stays on this phone, per server / account

    private var accountKey: String? {
        server.map { ($0.email ?? $0.url).replacingRegex("[^A-Za-z0-9_.-]", with: "_") }
    }

    private struct SpoolmanSetting: Codable { var url: String }

    /// The user's Spoolman address, `Spoolman.cloudSetting` for the cloud account's spools, or nil (off).
    func spoolmanSetting() -> String? {
        accountKey.flatMap { keychain.getJSON(StoreKey.spoolman($0), as: SpoolmanSetting.self)?.url }
    }

    func saveSpoolmanSetting(_ url: String?) {
        guard let accountKey else { return }
        let v = url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if v.isEmpty { keychain.set(StoreKey.spoolman(accountKey), nil) } else { keychain.setJSON(StoreKey.spoolman(accountKey), SpoolmanSetting(url: v)) }
    }

    /// "Always make a time-lapse": the switch before printing starts on. On an own server the server keeps the setting
    /// too, so it also records prints started on the printer itself (0.40.0); this copy is the phone's default.
    var timelapseAlways: Bool {
        accountKey.map { keychain.get(StoreKey.timelapseAlways($0)) == "1" } ?? false
    }

    func saveTimelapseAlways(_ on: Bool) {
        guard let accountKey else { return }
        keychain.set(StoreKey.timelapseAlways(accountKey), on ? "1" : nil)
    }

    /// Spoolman spool id → cloud spool id of earlier imports.
    func spoolImportMap() -> [String: Int] {
        accountKey.flatMap { keychain.getJSON(StoreKey.spoolImport($0), as: [String: Int].self) } ?? [:]
    }

    func saveSpoolImportMap(_ map: [String: Int]) {
        guard let accountKey else { return }
        keychain.setJSON(StoreKey.spoolImport(accountKey), map)
    }

    func openSpoolman(_ setting: String) -> Spoolman? {
        server.map { Spoolman.open(server: $0, setting: setting) }
    }

    /// Last spool per colour of a printer (default for the next print).
    func lastSpools(_ printer: String) -> [String: Int] {
        accountKey.flatMap { keychain.getJSON(StoreKey.spools($0, printer), as: [String: Int].self) } ?? [:]
    }

    func saveLastSpools(_ printer: String, _ spools: [String: Int]) {
        guard let accountKey else { return }
        keychain.setJSON(StoreKey.spools(accountKey, printer), spools)
    }

    func bookings() -> [Booking] {
        if bookingsInAccount { return accountBookings }
        return accountKey.flatMap { keychain.getJSON(StoreKey.bookings($0), as: [Booking].self) } ?? []
    }

    /// Cloud spools: bookings live in the account (server 0.29.0), so the cloud books them even when no app is open.
    /// An own Spoolman at home: this phone keeps them, as before.
    var bookingsInAccount: Bool { isCloud && spoolmanSetting() == Spoolman.cloudSetting }
    /// Last list of the account's open bookings (refreshed with every `settleBookings` / `loadBookings`).
    @ObservationIgnored private var accountBookings: [Booking] = []

    /// The open bookings, asking the account when it keeps them.
    func loadBookings() async -> [Booking] {
        if bookingsInAccount, let api {
            if let r = try? await api.bookings() { accountBookings = (r.waiting + r.open).map(Booking.init(server:)) }
            return accountBookings
        }
        return bookings()
    }

    private func saveBookings(_ list: [Booking]) {
        guard let accountKey else { return }
        keychain.setJSON(StoreKey.bookings(accountKey), Array(list.suffix(Bookings.maxCount)))
    }

    /// After a started print: book the filament once it is over.
    func addBooking(printer: String, printerName: String, file: String, uses: [BookingUse], job: String? = nil) async {
        guard !uses.isEmpty else { return }
        if bookingsInAccount, let api {
            try? await api.createBooking(BookingRequest(printer: printer, file: file,
                                                        uses: uses.map { .init(spool: $0.spool, grams: $0.grams, label: $0.label) },
                                                        printerName: printerName, job: job))
            return
        }
        let b = Booking(id: Lan.randomHex(6), printer: printer, printerName: printerName, file: file, uses: uses,
                        created: Bookings.now())
        saveBookings(Bookings.adding(b, to: bookings()))
    }

    @ObservationIgnored private var settling = false

    /// With fresh printer statuses (printers tab): finished prints are booked, unclear ones wait for the user.
    func settleBookings(_ statuses: [String: PrinterStatus?]) async -> SettleResult {
        if bookingsInAccount, let api {
            do {
                let r = try await api.observeBookings(statuses)
                accountBookings = (r.waiting + r.open).map(Booking.init(server:))
                return SettleResult(booked: r.bookedNow.map(Booking.init(server:)), open: r.open.map(Booking.init(server:)))
            } catch {
                return SettleResult(open: accountBookings.filter { $0.ask != nil }, error: error.localizedDescription)
            }
        }
        guard !settling else { return SettleResult(open: bookings().filter { $0.ask != nil }) }
        settling = true
        defer { settling = false }
        let before = bookings()
        guard !before.isEmpty else { return SettleResult() }
        var list = before.map { b in statuses.keys.contains(b.printer) ? Bookings.judge(b, statuses[b.printer] ?? nil) : b }
        var result = SettleResult()
        if let setting = spoolmanSetting(), let sm = openSpoolman(setting) {
            for i in list.indices where list[i].ready == true {
                let uses = list[i].uses
                do {
                    try await book(&list, i, part: 1, sm)
                    var done = list[i]
                    done.uses = uses
                    result.booked.append(done)
                } catch {
                    result.error = error.localizedDescription  // retried with the next status refresh
                    break
                }
            }
        }
        let doneIds = Set(result.booked.map(\.id))
        let rest = list.filter { !doneIds.contains($0.id) }
        saveBookings(rest)
        result.open = rest.filter { $0.ask != nil }
        return result
    }

    /// Book a share of a booking (1 = all); spools already booked are removed from it, so a retry never books twice.
    private func book(_ list: inout [Booking], _ i: Int, part: Double, _ sm: Spoolman) async throws {
        while let u = list[i].uses.first {
            let grams = u.grams * part
            if grams >= 0.05 { try await sm.use(spool: u.spool, grams: grams) }
            list[i].uses.removeFirst()
            saveBookings(list)
        }
    }

    /// The user's decision on an open booking: book `part` of the filament (0 = discard).
    func resolveBooking(_ id: String, part: Double) async throws {
        if bookingsInAccount, let api {
            try await api.resolveBooking(id: id, part: part)
            accountBookings.removeAll { $0.id == id }
            return
        }
        var list = bookings()
        guard let i = list.firstIndex(where: { $0.id == id }) else { return }
        if part > 0 {
            guard let setting = spoolmanSetting(), let sm = openSpoolman(setting) else {
                throw SpoolmanError("no Spoolman address set")
            }
            try await book(&list, i, part: part, sm)
        }
        list.remove(at: i)
        saveBookings(list)
    }

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
        if !link.isEmpty { openLink(link) }
    }

    /// A model link from the user: MakerWorld only allows downloads with the user's own account (server 0.17.1), so
    /// its model page opens with a button to MakerWorld; everything else goes to the prepare screen.
    func openLink(_ link: String) {
        if let mw = Format.makerWorldId(link) {
            push(.model(source: "makerworld", id: mw))
        } else {
            push(.prepare(PrepareArgs(link: link)))
        }
    }
}
