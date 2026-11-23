import SwiftUI
import UIKit

/// Live status and control of every printer (DR-04, DR-05, DR-06); details in ControlView (issue #5).
struct PrintersView: View {
    private struct Entry: Identifiable, Sendable {
        var printer: Printer
        var status: PrinterStatus?
        /// The first status of this visit is still on its way (an unreachable printer can take a while to time out).
        var checking = false
        /// Cloud: the app has no Wi-Fi address for this printer yet.
        var noAddress = false
        /// Why there is no status (bridge printers: the server's reason, e.g. "bridge offline").
        var error: String?
        var id: String { printer.id }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var entries: [Entry]?
    @State private var error = ""
    @State private var acting = ""
    @State private var cancelTarget: Printer?
    /// Printer whose Home Assistant plug should be switched off (asked first).
    @State private var powerOffTarget: Printer?
    @State private var camera: CameraTarget?
    @State private var cams: [String: Bool] = [:]
    /// When the app switched a printer's plug on (issue #9): it needs 30-60 s before it answers.
    @State private var poweredAt: [String: Date] = [:]
    /// Spoolman bookings waiting for a decision, and the ones just booked (shown for a minute).
    @State private var openBookings: [Booking] = []
    @State private var booked: [Booked] = []
    /// Cloud: when the server was last told what the printers on this Wi-Fi do (server 0.33.0).
    @State private var lastObserve = Date.distantPast
    /// Printer → its started job (for the model picture of the current layer, 0.9.20), and when that was asked.
    @State private var printJobs: [String: String] = [:]
    @State private var lastJobs = Date.distantPast
    /// Printer → "model" when the card shows the print up to the current layer instead of the camera.
    @AppStorage("ps_printer_card_view") private var cardViewsRaw = ""
    /// Bumped when layer pictures were rendered, so the cards look again.
    @State private var picturesReady = 0

    private struct Booked: Identifiable {
        var booking: Booking
        var at: Date
        var id: String { booking.id }
    }

    var body: some View {
        let t = app.l10n
        PSScreen(refresh: { await load() }) {
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            ForEach(booked) { PSBanner(kind: .ok, text: BookingCard.bookedText(t, $0.booking)) }
            ForEach(openBookings) { b in
                BookingCard(booking: b) { openBookings = app.bookings().filter { $0.ask != nil } }
            }
            if let entries {
                if entries.isEmpty {
                    if app.isCloud {
                        PSEmpty(icon: "printer", title: t(.noPrinters), sub: t(.noPrintersCloud)) {
                            PSButton(title: t(.addPrinter), icon: "plus") { app.push(.cloudPrinter(id: CloudPrinterView.new)) }
                        }
                    } else {
                        PSEmpty(icon: "printer", title: t(.noPrinters))
                    }
                }
                ForEach(entries) { card(t, $0) }
            }
        }
        .navigationTitle(t(.tabPrinters))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(item: $camera) { CameraView(printer: $0.printer, title: $0.name) }
        .task(id: scenePhase == .active) { await pollWhileVisible() }
        .task { await loadCameras() }
        .alert(t(.cancelPrint), isPresented: Binding(get: { cancelTarget != nil }, set: { if !$0 { cancelTarget = nil } }),
               presenting: cancelTarget) { p in
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.cancelPrint), role: .destructive) { Task { await run(p, "cancel") } }
        } message: { p in
            Text(t(.cancelPrintQ, ["printer": p.name]))
        }
        .alert(powerOffTarget.map { t(.powerOffQ, ["printer": $0.name]) } ?? "",
               isPresented: Binding(get: { powerOffTarget != nil }, set: { if !$0 { powerOffTarget = nil } }),
               presenting: powerOffTarget) { p in
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.powerOff), role: .destructive) { Task { await powerOff(p) } }
        }
    }

    private func card(_ t: L10n, _ e: Entry) -> some View {
        let p = e.printer, s = e.status
        let kind: PrinterKind = s?.kind ?? .offline
        let busy = kind.isBusy
        var label = t.printerKind(kind.rawValue)
        let raw = (s?.state ?? "").lowercased()
        if kind == .active, !raw.isEmpty, raw != "printing" { label += " · \(t.rawState(raw))" }
        let badge: PSBadgeKind = kind == .offline || kind == .error ? .error : kind == .paused ? .warn : busy ? .accent : .ok
        let pct = s?.progress ?? 0
        // printers that report it (PrusaLink, OctoPrint) know better than the estimate from progress
        var left: Double?
        if busy {
            if let r = s?.timeRemainingS { left = r }
            else if let d = s?.printDurationS, d > 0, pct > 1 { left = d * (100 - pct) / pct }
        }
        return PSCard(padding: Theme.space) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "printer.fill").font(.title3).foregroundStyle(Theme.accent).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.title3.bold()).foregroundStyle(Theme.text).lineLimit(1)
                        if p.bridge != nil { Text(t(.viaBridge)).font(.footnote).foregroundStyle(Theme.sub) }
                    }
                    Spacer(minLength: 8)
                    // Home Assistant plug: switching off only while the printer answers and prints nothing
                    // (the server refuses it during a print as well, 409)
                    if p.power, s != nil, !busy, kind != .offline {
                        powerOffButton(t, p)
                    }
                    // no "offline" badge while the first status is still on its way
                    if !e.checking { PSBadge(text: label, kind: badge) }
                }
                .padding(.bottom, 12)
                if busy, let s {
                    Text(s.file ?? "–").font(.subheadline).foregroundStyle(Theme.text).lineLimit(1).padding(.bottom, 8)
                    PSProgressBar(value: pct)
                    HStack {
                        Text("\(Int(pct.rounded())) %").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                        Spacer()
                        Text(progressDetail(t, s, left)).font(.subheadline).foregroundStyle(Theme.sub)
                    }
                    .padding(.top, 6)
                }
                if let s {
                    HStack(spacing: 24) {
                        temperature(t(.nozzle), Format.temp(s.nozzle, s.nozzleTarget))
                        temperature(t(.bed), Format.temp(s.bed, s.bedTarget))
                    }
                    .padding(.top, busy ? 14 : 0)
                } else if e.checking {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text(t(.printerChecking)).font(.subheadline).foregroundStyle(Theme.sub)
                    }
                } else if e.noAddress {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(t(.needLanAddress)).font(.subheadline).foregroundStyle(Theme.sub)
                        PSButton(title: t(.lanAddress), kind: .secondary, icon: "wifi") { app.push(.cloudPrinter(id: p.id)) }
                    }
                } else if p.bridge != nil {
                    Text(e.error ?? t(.errBridgeOffline)).font(.subheadline).foregroundStyle(Theme.sub)
                } else {
                    offline(t, p)
                }
                if let w = s?.watch {
                    WatchInfo(printer: p.id, watch: w, busy: acting, onMute: { Task { await mute(p) } },
                              onPause: { Task { await run(p, "pause") } })
                }
                if busy {
                    HStack(spacing: 10) {
                        if kind == .paused {
                            PSButton(title: t(.resume), icon: "play.fill", loading: acting == "\(p.id):resume") {
                                Task { await run(p, "resume") }
                            }
                        } else {
                            PSButton(title: t(.pause), kind: .secondary, icon: "pause.fill",
                                     loading: acting == "\(p.id):pause") { Task { await run(p, "pause") } }
                        }
                        PSButton(title: t(.cancelBtn), kind: .danger, icon: "stop.fill",
                                 loading: acting == "\(p.id):cancel") { cancelTarget = p }
                    }
                    .padding(.top, 16)
                }
                if let lanes = s?.lanes, !lanes.isEmpty { laneChips(t, lanes).padding(.top, 14) }
                // on the Wi-Fi the cloud app reaches the printer only for status and pause / resume / cancel so far;
                // own servers and bridges do everything
                if s != nil && app.viaServer(p) {
                    PSButton(title: t(.control), kind: .secondary, icon: "slider.horizontal.3") {
                        app.push(.control(id: p.id, name: p.name))
                    }
                    .padding(.top, 14)
                }
                let job = busy ? printJobs[p.id] : nil
                let hasCam = cams[p.id] == true && app.viaServer(p)
                if job != nil && hasCam {
                    Picker("", selection: Binding(get: { showsModel(p.id) }, set: { setShowsModel(p.id, $0) })) {
                        Text(t(.camera)).tag(false)
                        Text(t(.modelView)).tag(true)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .padding(.top, 14)
                }
                if let job, let s, showsModel(p.id) || !hasCam {
                    Button { Haptics.tap(); app.push(.livePreview(job: job, printer: p)) } label: {
                        LayerPicture(job: job, status: s, ready: picturesReady)
                            .overlay(alignment: .bottomTrailing) {
                                Label(t(.view3d), systemImage: "cube")
                                    .font(.caption).foregroundStyle(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Color.black.opacity(0.55)).clipShape(Capsule()).padding(8)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t(.livePreviewTitle))
                    .padding(.top, 14)
                    .task(id: job) {
                        guard let api = app.api, !ActivityImages.hasFrames(job) else { return }
                        if await ActivityPictures.prepare(job: job, api: api) { picturesReady += 1 }
                    }
                } else if hasCam {
                    Button { Haptics.tap(); camera = CameraTarget(printer: p.id, name: p.name) } label: {
                        CameraImage(printer: p.id, width: 640, interval: 5)
                            .aspectRatio(16 / 9, contentMode: .fit)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(alignment: .bottomTrailing) {
                                Label(t(.camera), systemImage: "arrow.up.left.and.arrow.down.right")
                                    .font(.caption).foregroundStyle(.white)
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(Color.black.opacity(0.55)).clipShape(Capsule()).padding(8)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(t(.camera))
                    .padding(.top, 14)
                }
            }
        }
        .padding(.bottom, 16)
    }

    private func showsModel(_ printer: String) -> Bool {
        cardViewsRaw.split(separator: ",").contains { $0 == Substring(printer) }
    }

    private func setShowsModel(_ printer: String, _ on: Bool) {
        var set = Set(cardViewsRaw.split(separator: ",").map(String.init))
        if on { set.insert(printer) } else { set.remove(printer) }
        cardViewsRaw = set.sorted().joined(separator: ",")
    }

    /// Which started job each busy printer runs (asked at most every 30 s, and only while something prints).
    private func loadPrintJobs(_ api: APIClient, _ list: [Entry]) async {
        guard list.contains(where: { $0.status?.kind.isBusy == true }) else { printJobs = [:]; return }
        let missing = list.contains { $0.status?.kind.isBusy == true && printJobs[$0.id] == nil }
        guard missing ? Date().timeIntervalSince(lastJobs) > 10 : Date().timeIntervalSince(lastJobs) > 30 else { return }
        lastJobs = Date()
        guard let jobs = try? await api.jobs() else { return }
        var out: [String: String] = [:]
        for j in jobs.sorted(by: { $0.created > $1.created }) where j.state == .started && !j.isExternal {
            if let printer = j.printer, out[printer] == nil { out[printer] = j.id }
        }
        printJobs = out
    }

    private func powerOffButton(_ t: L10n, _ p: Printer) -> some View {
        Button { Haptics.tap(); powerOffTarget = p } label: {
            Group {
                if acting == "\(p.id):powerOff" { ProgressView() }
                else { Image(systemName: "power").font(.body.weight(.semibold)).foregroundStyle(Theme.danger) }
            }
            .frame(width: 36, height: 36)
            .background(Theme.input).clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!acting.isEmpty)
        .accessibilityLabel(t(.powerOff))
    }

    /// Filament lanes of an AFC unit (CANVAS on COSMOS), spec MA-02.
    private func laneChips(_ t: L10n, _ lanes: [Lane]) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(LanePlan.bySlot(lanes)) { l in
                HStack(spacing: 6) {
                    ColorDot(color: Color(hexString: l.color), size: 14)
                    Text("\(LanePlan.slotName(t, lane: l, lanes: lanes)) · \(l.loaded ? (l.material ?? "?") : t(.laneEmpty))")
                        .font(.footnote).foregroundStyle(Theme.text)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Theme.input).clipShape(Capsule())
                .overlay(Capsule().stroke(Theme.accent, lineWidth: l.inToolhead ? 2 : 0))
                .opacity(l.loaded ? 1 : 0.5)
                .accessibilityElement(children: .combine)
                .accessibilityHint(l.inToolhead ? t(.laneInToolhead) : "")
            }
        }
    }

    /// No status: offline text, and for printers on a Home Assistant plug a switch-on button (issue #9).
    @ViewBuilder
    private func offline(_ t: L10n, _ p: Printer) -> some View {
        let since = poweredAt[p.id].map { Date().timeIntervalSince($0) }
        if p.power, let since, since < 120 {
            HStack(spacing: 10) {
                ProgressView()
                Text(t(.powerStarting)).font(.subheadline).foregroundStyle(Theme.sub)
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text(since != nil ? t(.powerSlow) : t(app.isCloud ? .errPrinterOfflineLan : .errPrinterOffline)).font(.subheadline).foregroundStyle(Theme.sub)
                if p.power {
                    PSButton(title: t(.powerOn), icon: "power", loading: acting == "\(p.id):power") {
                        Task { await powerOn(p) }
                    }
                }
            }
        }
    }

    private func temperature(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label).font(.footnote).foregroundStyle(Theme.sub)
            Text(value).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
        }
        .accessibilityElement(children: .combine)
    }

    private func progressDetail(_ t: L10n, _ s: PrinterStatus, _ left: Double?) -> String {
        var parts: [String] = []
        if let total = s.layers, total > 0 { parts.append("\(t(.layer)) \(s.layer.map(String.init) ?? "–")/\(total)") }
        if let left, left > 0 { parts.append("\(t(.remaining)) ~\(Format.duration(left))") }
        return parts.joined(separator: " · ")
    }

    /// Poll every 5 s while the screen is visible and the app is in the foreground.
    private func pollWhileVisible() async {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(5))
        }
    }

    /// Which printers have a camera (asked once per visit, not with every status refresh).
    private func loadCameras() async {
        guard let api = app.api, let list = try? await api.printers() else { return }
        for p in list where app.viaServer(p) {
            if let info = try? await api.cameraInfo(printer: p.id) { cams[p.id] = info.available }
        }
    }

    private func load() async {
        guard let api = app.api else { return }
        do {
            let list = try await api.printers()
            // Show the printers at once and fill in each status as it arrives: a switched-off printer only answers
            // after its timeout, and until then the screen used to stay empty.
            let known = Dictionary((entries ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            entries = list.map { p in
                if var e = known[p.id] { e.printer = p; return e }
                return Entry(printer: p, checking: true)
            }
            let app = app
            var out: [Entry] = []
            await withTaskGroup(of: Entry.self) { group in
                for p in list {
                    group.addTask {
                        do {
                            return Entry(printer: p, status: try await app.printerStatus(p))
                        } catch {
                            return Entry(printer: p, status: nil, noAddress: error is NoLanAddress,
                                         error: p.bridge != nil ? error.localizedDescription : nil)
                        }
                    }
                }
                for await e in group {
                    out.append(e)
                    if let i = entries?.firstIndex(where: { $0.id == e.id }) { entries?[i] = e }
                }
            }
            out = list.compactMap { p in out.first { $0.id == p.id } }
            for e in out where e.status != nil { poweredAt[e.id] = nil }
            error = ""
            await loadPrintJobs(api, out)
            await observe(api, out)
            await settle(out)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Cloud: tell the server what the printers on this Wi-Fi do, so started jobs learn that they finished (0.33.0).
    /// Bridge printers are watched by the cloud itself.
    private func observe(_ api: APIClient, _ list: [Entry]) async {
        guard app.isCloud, Date().timeIntervalSince(lastObserve) > 30 else { return }
        var statuses: [String: PrinterStatus?] = [:]
        for e in list where e.printer.bridge == nil { if let st = e.status { statuses[e.id] = .some(st) } }
        guard !statuses.isEmpty else { return }
        lastObserve = Date()
        try? await api.observe(statuses)
    }

    /// Book the filament of finished prints in Spoolman (or ask when a print was cancelled or its end was missed).
    private func settle(_ list: [Entry]) async {
        var statuses: [String: PrinterStatus?] = [:]
        for e in list { statuses[e.id] = .some(e.status) }
        let result = await app.settleBookings(statuses)
        let now = Date()
        booked = booked.filter { now.timeIntervalSince($0.at) < 60 } + result.booked.map { Booked(booking: $0, at: now) }
        openBookings = result.open
        if let e = result.error { error = app.l10n(.spoolmanUnreachable, ["error": e]) }
    }

    /// "False alarm" of the AI failure detection: no more alerts for this print.
    private func mute(_ p: Printer) async {
        guard let api = app.api else { return }
        acting = "\(p.id):mute"
        do { _ = try await api.muteWatch(printer: p.id) }
        catch { self.error = error.localizedDescription }
        acting = ""
        await load()
    }

    private func powerOn(_ p: Printer) async {
        guard let api = app.api else { return }
        acting = "\(p.id):power"
        do {
            try await api.setPower(printer: p.id, on: true)
            poweredAt[p.id] = Date()
        } catch { self.error = error.localizedDescription }
        acting = ""
    }

    private func powerOff(_ p: Printer) async {
        guard let api = app.api else { return }
        acting = "\(p.id):powerOff"
        do {
            try await api.setPower(printer: p.id, on: false)
            poweredAt[p.id] = nil
        } catch { self.error = error.localizedDescription }
        acting = ""
        try? await Task.sleep(for: .seconds(2))
        await load()
    }

    private func run(_ p: Printer, _ action: String) async {
        acting = "\(p.id):\(action)"
        do { try await app.printerControl(p, action: action) }
        catch { self.error = error.localizedDescription }
        acting = ""
        try? await Task.sleep(for: .milliseconds(800))
        await load()
    }
}

/// The print up to the printer's current layer: one of the layer pictures the Live Activity uses (0.9.20).
private struct LayerPicture: View {
    let job: String
    let status: PrinterStatus
    /// Changes when new pictures were rendered.
    let ready: Int

    var body: some View {
        let state = PrintActivityAttributes.ContentState(s: "printing", p: Int((status.progress ?? 0).rounded()),
                                                         l: status.layer, lt: status.layers)
        ZStack {
            Color(white: 0.16)
            if let url = ActivityImages.frameFile(job, state.frame), let img = UIImage(contentsOfFile: url.path) {
                Image(uiImage: img).resizable().aspectRatio(contentMode: .fit)
            } else if let none = ActivityImages.noPreviewURL(job), FileManager.default.fileExists(atPath: none.path) {
                Image(systemName: "cube.transparent").font(.largeTitle).foregroundStyle(.white.opacity(0.5))
            } else {
                ProgressView().tint(.white)
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .id(ready)
    }
}
