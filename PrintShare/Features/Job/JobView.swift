import SwiftUI
import UIKit

/// Slicing progress -> review -> explicit confirmation -> print / upload (spec 5, NF-05, DR-03).
struct JobView: View {
    let id: String

    private enum SendMode: String { case print, upload }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var job: Job?
    @State private var loadError = ""
    @State private var actionError = ""
    /// Time-lapse (server 0.32.0): only where the server or a bridge reaches the camera; starts as the
    /// "always make a time-lapse" setting says (off unless set).
    @State private var timelapse = false
    @State private var timelapseDefaulted = false
    /// "Print again" on a finished / cancelled job brings the review back.
    @State private var again = false
    @State private var sending: SendMode?
    @State private var printers: [Printer] = []
    @State private var printerStatus: PrinterStatus?
    @State private var printerKind: PrinterKind?
    @State private var laneChoice: [Int: Int]
    @State private var laneSheet: LaneSheet?
    @State private var camera: CameraTarget?
    @State private var hasCamera = false
    @State private var showLog = false
    @State private var elapsed = 0
    @State private var startedAt = Date()
    @State private var confirmStart = false
    @State private var confirmDelete = false
    @State private var level = true
    @State private var levelLoaded = false
    @State private var gcodeShare: SharedFile?
    @State private var gcodeLoading = false
    /// Cloud: the app sends the G-code itself, so the server's job stays "sliced"; this remembers what happened.
    @State private var relayed: SendMode?
    @State private var relay: (step: SendStep, part: Double)?
    // Spoolman (MA-07): spool per colour; the app books the use after the print unless Moonraker does it itself
    @State private var smSetting: String?
    @State private var spools: [Spool]?
    @State private var smError = ""
    @State private var spoolChoice: [Int: Int] = [:]
    @State private var lastSpools: [String: Int] = [:]
    @State private var spoolSheet: SpoolSheet?
    /// Spools put into the printer's slots in the filament menu (tool → spool, server 0.38.0).
    @State private var slotSpools: [Int: Int] = [:]
    // a spool chosen by NFC chip (server 0.38.0) or OpenPrintTag
    @State private var nfcBusy = false
    @State private var nfcMsg: (ok: Bool, text: String)?
    @State private var linkSheet: LinkSheet?

    /// `slots`: tool per model colour chosen on the prepare screen (the default until changed here).
    init(id: String, slots: [Int: Int] = [:]) {
        self.id = id
        _laneChoice = State(initialValue: slots)
    }

    private var working: Bool { job?.state.isWorking ?? false }
    private var printerId: String? {
        let p = job?.result?.printer
        return (p?.isEmpty == false) ? p : job?.printer
    }
    private var printerInfo: Printer? { printers.first { $0.id == printerId } }
    private var printerName: String { printerInfo?.name ?? printerId ?? "" }

    private struct LaneSheet: Identifiable { var colour: Int; var id: Int { colour } }
    private struct SpoolSheet: Identifiable { var colour: Int; var id: Int { colour } }
    /// A chip without a link: "which spool is this?" - linked once, known after.
    private struct LinkSheet: Identifiable { var uid: String; var id: String { uid } }

    private var spoolColours: [SpoolPlan.Colour] { SpoolPlan.colours(job?.result) }
    private var tracker: SpoolmanLink? { printerKind == .offline ? nil : printerStatus?.spoolman }
    /// Moonraker books the filament itself ...
    private var printerBooks: Bool { tracker?.connected == true }
    /// ... on the spools AFC assigned to the slots.
    private var afcSpools: Bool { printerBooks && !printerLanes.isEmpty }
    private var spoolFor: [Int: Int] {
        SpoolPlan.spools(colours: spoolColours, lanes: printerLanes, tools: laneTools, afc: afcSpools, choice: spoolChoice,
                         tracker: tracker, last: lastSpools, known: spools, slots: slotSpools)
    }
    /// Moonraker without AFC tracks one active spool: set it for a single-colour print.
    private var activeSpool: Int? {
        printerBooks && !afcSpools && spoolColours.count == 1 ? spoolFor[spoolColours[0].index] : nil
    }

    // Lane selection (issue #6): which lane of the printer prints each filament of the model.
    private var printerLanes: [Lane] { LanePlan.usable(printerStatus) }
    private var colours: [LanePlan.Colour] { LanePlan.colours(job?.result) }
    private var laneTools: [Int: Int] { LanePlan.tools(colours: colours, lanes: printerLanes, choice: laneChoice) }

    var body: some View {
        let t = app.l10n
        Group {
            if let job { content(t, job) } else { placeholder(t) }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sending) { await poll() }
        .task(id: working) { await tickElapsed() }
        .task { await loadPrinters() }
        .task(id: statusKey) { await pollPrinter() }
        .onAppear { updateIdleTimer() }
        .onChange(of: working) { _, _ in updateIdleTimer() }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        // the safety check (NF-05) sits on the button: plate empty, material loaded, then start
        .alert(t(.confirmStartPlateQ, ["printer": printerName, "material": startMaterial(t)]), isPresented: $confirmStart) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.start)) { Task { await send(start: true) } }
        }
        .sheet(item: $gcodeShare) { ActivitySheet(items: [$0.url]).ignoresSafeArea() }
        .sheet(item: $laneSheet) { sheet in laneSheetView(t, sheet.colour) }
        .sheet(item: $spoolSheet) { sheet in spoolSheetView(t, sheet.colour) }
        .sheet(item: $linkSheet) { sheet in linkSheetView(t, sheet.uid) }
        .task(id: reviewing) { await loadSpools() }
        .sheet(item: $camera) { CameraView(printer: $0.printer, title: $0.name) }
        .task(id: cameraKey) { await loadCamera() }
        .task(id: following) { await follow() }
        .alert(t(.deleteJobQ), isPresented: $confirmDelete) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.del), role: .destructive) { Task { await delete() } }
        }
    }

    private var reviewing: Bool { job?.state == .sliced || job?.state == .uploaded || again }

    /// A camera the server (own server or bridge) can show and record from; asked once the printer is known.
    private var cameraKey: String {
        guard let info = printerInfo, app.viaServer(info) else { return "" }
        return info.id
    }

    /// A started print is followed until it is over (server 0.33.0), and its time-lapse until the video is ready.
    private var following: Bool {
        guard let job else { return false }
        let tl = job.timelapse?.state
        return job.state == .started || tl == .recording || tl == .rendering
    }

    private func startMaterial(_ t: L10n) -> String {
        let m = Format.shortName(job?.result?.profiles["filament"])
        return m.isEmpty ? t(.filament) : m
    }

    private var statusKey: String {
        guard let job, job.state == .sliced || job.state == .uploaded || again else { return "" }
        // the cloud needs the printer list (type) before it can ask the printer on the Wi-Fi
        return (printerId ?? "") + (app.isCloud && printerInfo == nil ? "?" : "")
    }

    private func placeholder(_ t: L10n) -> some View {
        VStack {
            if loadError.isEmpty {
                ProgressView().controlSize(.large)
            } else {
                PSEmpty(icon: "icloud.slash", title: loadError) {
                    PSButton(title: t(.tryAgain), kind: .secondary) { Task { _ = await load() } }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
    }

    @ViewBuilder
    private func content(_ t: L10n, _ job: Job) -> some View {
        switch job.state {
        case .slicing, .running: slicingView(t, job)
        case .error: errorView(t, job)
        default:
            if job.isExternal { externalView(t, job) } else { reviewView(t, job) }
        }
    }

    // MARK: slicing

    private func slicingView(_ t: L10n, _ job: Job) -> some View {
        let name = Format.jobName(file: job.result?.sourceFile, link: job.request.link)
        let last = job.log.last.map { t.translateLog($0) } ?? t(.slicing)
        return PSScreen {
            VStack(spacing: 6) {
                ProgressView().controlSize(.large)
                Text(t(.slicing)).font(.title2.bold()).foregroundStyle(Theme.text).padding(.top, 20)
                Text(name).font(.subheadline).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
                Text(last).font(.subheadline).foregroundStyle(Theme.sub).padding(.top, 14)
                Text("\(elapsed) s · \(t(.slicingSub))").font(.footnote).foregroundStyle(Theme.sub)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 40)
            PSCard(padding: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(job.log.enumerated()), id: \.offset) { i, line in
                        let finished = i < job.log.count - 1
                        HStack(spacing: 10) {
                            Image(systemName: finished ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(finished ? Theme.ok : Theme.accent).accessibilityHidden(true)
                            Text(t.translateLog(line)).font(.subheadline).foregroundStyle(Theme.text)
                        }
                    }
                }
            }
        } footer: {
            PSButton(title: t(.keepRunning), kind: .secondary) { dismiss() }
        }
    }

    // MARK: error (SL-04)

    private func errorView(_ t: L10n, _ job: Job) -> some View {
        PSScreen {
            PSEmpty(icon: "exclamationmark.circle", title: t(.errorTitle),
                    sub: friendlyError(t, status: 0, detail: job.error ?? ""))
            Button { Haptics.tap(); showLog.toggle() } label: {
                Text(t(.showDetails)).font(.subheadline).foregroundStyle(Theme.accent)
            }
            .frame(maxWidth: .infinity)
            if showLog {
                PSCard(padding: 14) {
                    Text((job.log + [job.error].compactMap { $0 }).joined(separator: "\n"))
                        .font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.sub).textSelection(.enabled)
                }
                .padding(.top, 12)
            }
        } footer: {
            PSButton(title: t(.editSettings), icon: "slider.horizontal.3") { editSettings(job) }
            PSButton(title: t(.deleteJob), kind: .plain) { confirmDelete = true }
        }
    }

    // MARK: started on the printer itself (server 0.40.0)

    private func externalView(_ t: L10n, _ job: Job) -> some View {
        let name = job.printerFile ?? "–"
        let cancelled = job.state == .cancelled
        let finished = job.state == .finished
        return PSScreen {
            VStack(spacing: 6) {
                Image(systemName: cancelled ? "xmark.circle.fill" : finished ? "checkmark.circle.fill" : "printer.fill")
                    .font(.system(size: 60)).foregroundStyle(cancelled ? Theme.warn : finished ? Theme.ok : Theme.accent)
                    .accessibilityHidden(true)
                Text(t(finished ? .finishedTitle : cancelled ? .cancelledTitle : .jobExternal))
                    .font(.title2.bold()).foregroundStyle(Theme.text).padding(.top, 6)
                Text(t(.jobExternalSub)).font(.subheadline).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
                if let tl = job.timelapse { timelapseInfo(t, tl, name: name) }
            }
            .frame(maxWidth: .infinity).padding(.vertical, 20)
            if !actionError.isEmpty { PSBanner(kind: .error, text: actionError) }
            if job.state == .started, let p = job.progress {
                PSCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(t(.jobProgress)).font(.body).foregroundStyle(Theme.text)
                            Spacer()
                            Text("\(Int(p.rounded())) %").font(.body.monospacedDigit()).foregroundStyle(Theme.sub)
                        }
                        ProgressView(value: min(max(p, 0), 100), total: 100).tint(Theme.accent)
                    }
                }
                .padding(.bottom, 12)
            }
            PSSection(title: t(.details)) {
                PSRow(label: t(.printer), value: printerName)
                PSDivider()
                PSRow(label: t(.file), sub: name)
            }
            PSButton(title: t(.deleteJob), kind: .plain) { confirmDelete = true }.padding(.top, 4)
        } footer: {
            PSButton(title: t(.toPrinter), icon: "printer") { app.navigate(to: .printers) }
            if hasCamera, let p = printerId {
                PSButton(title: t(.camera), kind: .secondary, icon: "video") {
                    camera = CameraTarget(printer: p, name: printerName)
                }
            }
        }
    }

    // MARK: review / sent

    private func reviewView(_ t: L10n, _ job: Job) -> some View {
        let r = job.result
        let profiles = r?.profiles ?? [:]
        let changed = Self.changedValues(t, r?.overrides ?? [:])
        // plate options only from servers that know them (0.14.0 reports copies_requested)
        let arranged = r?.knowsPlate == true ? PlateOptions.summary(t, job.request.options, placed: r?.copies) : ""
        let fewer = PlateOptions.fewerHint(t, r)
        let name = Format.jobName(file: r?.sourceFile, link: job.request.link)
        // the print is over (server 0.33.0 follows it): show the result, "print again" brings the review back
        let over = job.state.isOver
        let done = !again && (job.state == .started || over || relayed == .print)
        let uploaded = !again && (job.state == .uploaded || relayed == .upload)
        let busy = printerKind?.isBusy ?? false
        let offline = printerKind == .offline
        let laneWarnings = done ? [] : LanePlan.warnings(t, colours: colours, lanes: printerLanes, tools: laneTools)
        let canPrint = !busy && !offline && sending == nil && !laneWarnings.contains(where: \.blocking)
        let material = Format.shortName(profiles["filament"])
        let cancelled = job.state == .cancelled
        var shareAction: (() -> Void)?
        if !gcodeLoading { shareAction = { Task { await shareGcode(job) } } }
        return PSScreen {
            if done || uploaded {
                VStack(spacing: 6) {
                    Image(systemName: cancelled ? "xmark.circle.fill" : done ? "checkmark.circle.fill" : "checkmark.icloud.fill")
                        .font(.system(size: 60)).foregroundStyle(cancelled ? Theme.warn : Theme.ok).accessibilityHidden(true)
                    Text(t(job.state == .finished ? .finishedTitle : cancelled ? .cancelledTitle : done ? .startedTitle : .uploadedTitle))
                        .font(.title2.bold()).foregroundStyle(Theme.text)
                        .padding(.top, 6)
                    Text(t(job.state == .finished ? .finishedSub : cancelled ? .cancelledSub : done ? .startedSub : .uploadedSub))
                        .font(.subheadline).foregroundStyle(Theme.sub)
                        .multilineTextAlignment(.center)
                    if let tl = job.timelapse { timelapseInfo(t, tl, name: name) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                Text(t(.reviewTitle)).font(.largeTitle.bold()).foregroundStyle(Theme.text).padding(.bottom, 4)
            }
            Text(name).font(.subheadline).foregroundStyle(Theme.sub).lineLimit(2).padding(.bottom, 16)

            if !actionError.isEmpty { PSBanner(kind: .error, text: actionError) }
            if let relay {
                PSBanner(kind: .info, text: relay.step == .upload ? t(.relayUpload, ["pct": String(Int((relay.part * 100).rounded()))])
                                                                  : t(relay.step == .download ? .relayDownload : .relayStart))
            }
            if let fewer { PSBanner(kind: .warn, text: fewer) }

            HStack(spacing: 10) {
                PSStat(label: t(.printTime), value: Format.printTime(r?.printTime))
                PSStat(label: t(.filament), value: r?.filamentG.map { String(format: "%.1f g", $0) } ?? "–",
                       sub: r?.filamentM.map { "\(Self.trim($0)) m" })
                PSStat(label: t(.layers), value: r?.layers.map(String.init) ?? "–")
            }
            .padding(.bottom, 22)

            PSSection(title: t(.details)) {
                PSRow(label: t(.printer), value: printerName)
                PSDivider()
                PSRow(label: t(.material), value: material)
                PSDivider()
                PSRow(label: t(.quality), value: Format.shortName(profiles["process"]))
                PSDivider()
                PSRow(label: t(.plate), value: Format.plateName(t, profiles["bed_type"]))
                PSDivider()
                PSRow(label: t(.changed), sub: changed.isEmpty ? t(.changedNone) : changed.joined(separator: " · "))
                if !arranged.isEmpty {
                    PSDivider()
                    PSRow(label: t(.arrange), sub: arranged)
                }
                PSDivider()
                PSRow(icon: "eye", label: t(.showPreview)) { app.push(.preview(job.id)) }
                PSDivider()
                PSRow(icon: "square.and.arrow.up", label: t(.shareGcode), chevron: false, action: shareAction,
                      right: { if gcodeLoading { ProgressView() } })
            }

            if let fil = r?.filaments, fil.count > 1 {
                PSSection(title: t(.colors)) {
                    ForEach(Array(fil.enumerated()), id: \.element.index) { i, f in
                        if i > 0 { PSDivider() }
                        PSRow(label: t(.colorN, ["n": String(f.index)]), value: f.grams.map { String(format: "%.1f g", $0) } ?? "–",
                              sub: Format.shortName(f.preset),
                              right: { ColorDot(color: Color(hexString: f.color)).padding(.leading, 10) })
                    }
                }
            }

            if !done && !printerLanes.isEmpty {
                PSSection(title: t(.slots), footer: t(.jobSlotsHint)) {
                    ForEach(Array(colours.enumerated()), id: \.element.index) { i, col in
                        if i > 0 { PSDivider() }
                        laneRow(t, col)
                    }
                }
            }
            if !done {
                ForEach(laneWarnings, id: \.text) { PSBanner(kind: $0.blocking ? .error : .warn, text: $0.text) }
                spoolSection(t)
            }

            if !done {
                if busy { PSBanner(kind: .warn, text: t(.printerBusy, ["printer": printerName])) }
                if offline { PSBanner(kind: .error, text: t(.printerOffline, ["printer": printerName])) }
                if printerInfo?.leveling != nil {
                    PSCard(padding: 16) {
                        Toggle(isOn: $level) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t(.leveling)).font(.body).foregroundStyle(Theme.text)
                                Text(t(.levelingSub)).font(.footnote).foregroundStyle(Theme.sub)
                            }
                        }
                            .tint(Theme.accent)
                            .onChange(of: level) { _, on in
                                if levelLoaded, let p = printerId { app.saveLevel(p, on) }
                            }
                    }
                    .padding(.top, 12)
                }
                if hasCamera {
                    PSCard(padding: 16) {
                        Toggle(isOn: $timelapse) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t(.timelapse)).font(.body).foregroundStyle(Theme.text)
                                Text(t(.timelapseSub)).font(.footnote).foregroundStyle(Theme.sub)
                            }
                        }
                        .tint(Theme.accent)
                        .onChange(of: timelapse) { _, _ in Haptics.tap() }
                    }
                    .padding(.top, 12)
                }
                PSButton(title: t(.editSettings), kind: .plain, icon: "slider.horizontal.3") { editSettings(job) }
                    .padding(.top, 12)
            }
            PSButton(title: t(.deleteJob), kind: .plain) { confirmDelete = true }.padding(.top, 4)
        } footer: {
            if done {
                if over {
                    PSButton(title: t(.printAgain), icon: "arrow.clockwise") {
                        relayed = nil
                        again = true
                    }
                } else {
                    PSButton(title: t(.toPrinter), icon: "printer") { app.navigate(to: .printers) }
                }
                if hasCamera, let p = printerId {
                    PSButton(title: t(.camera), kind: .secondary, icon: "video") {
                        camera = CameraTarget(printer: p, name: printerName)
                    }
                }
                PSButton(title: t(.newModel), kind: .secondary) { app.navigate(to: .print) }
            } else {
                PSButton(title: t(.print), icon: "play.fill", loading: sending == .print || job.state == .sending,
                         disabled: !canPrint) { confirmStart = true }
                if !uploaded {
                    PSButton(title: t(.uploadOnly), kind: .secondary, icon: "icloud.and.arrow.up",
                             loading: sending == .upload, disabled: sending != nil || job.state == .sending) {
                        Task { await send(start: false) }
                    }
                }
            }
        }
    }

    /// Time-lapse of the print (server 0.32.0): progress, or the button to the video.
    @ViewBuilder
    private func timelapseInfo(_ t: L10n, _ tl: Timelapse, name: String) -> some View {
        if tl.state == .ready {
            PSButton(title: t(.timelapseWatch), icon: "film") { app.push(.timelapse(id: id, name: name)) }
                .padding(.top, 14)
        } else {
            Text(tl.state == .recording ? t(.timelapseRecording, ["n": String(tl.frames)])
                 : tl.state == .rendering ? t(.timelapseRendering) : t(.timelapseFailed, ["error": tl.error ?? ""]))
                .font(.footnote).foregroundStyle(tl.state == .failed ? Theme.danger : Theme.sub)
                .multilineTextAlignment(.center).padding(.top, 10)
        }
    }

    private func laneRow(_ t: L10n, _ col: LanePlan.Colour) -> some View {
        let lane = printerLanes.first { $0.tool == laneTools[col.index] }
        return PSRow(label: colours.count > 1 ? t(.colorN, ["n": String(col.index)]) : t(.slot),
                     value: LanePlan.label(t, lane: lane, lanes: printerLanes), sub: Format.shortName(col.preset),
                     action: { laneSheet = LaneSheet(colour: col.index) }, right: {
            HStack(spacing: 4) {
                if let c = col.color { ColorDot(color: Color(hexString: c), size: 14) }
                ColorDot(color: Color(hexString: lane?.color), size: 22)
            }
            .padding(.leading, 8)
        })
    }

    @ViewBuilder
    private func spoolSection(_ t: L10n) -> some View {
        if smSetting != nil && (spools != nil || !smError.isEmpty) {
            if !smError.isEmpty {
                PSBanner(kind: .warn, text: t(.spoolmanUnreachable, ["error": smError]))
            } else if printerBooks && !afcSpools && spoolColours.count > 1 {
                PSBanner(kind: .info, text: t(.spoolsMultiPrinter))
            } else {
                PSSection(title: t(.spools), footer: t(afcSpools ? .spoolsHintAfc : printerBooks ? .spoolsHintPrinter : .spoolsHint)) {
                    ForEach(Array(spoolColours.enumerated()), id: \.element.index) { i, col in
                        if i > 0 { PSDivider() }
                        spoolRow(t, col)
                    }
                    if !afcSpools && NFC.available && !(spools ?? []).isEmpty {
                        PSDivider()
                        PSRow(icon: "wave.3.right", label: t(.nfcPick), action: nfcBusy ? nil : { Task { await pickByNFC(t) } }) {
                            if nfcBusy { ProgressView().padding(.leading, 8) }
                        }
                    }
                }
            }
            if let nfcMsg { PSBanner(kind: nfcMsg.ok ? .ok : .warn, text: nfcMsg.text) }
            ForEach(SpoolPlan.warnings(t, colours: spoolColours, spoolFor: spoolFor, known: spools ?? []), id: \.self) {
                PSBanner(kind: .warn, text: $0)
            }
        }
    }

    private func spoolRow(_ t: L10n, _ col: SpoolPlan.Colour) -> some View {
        let sp = spools?.first { $0.id == spoolFor[col.index] }
        var sub: String?
        if let sp {
            sub = [sp.material, sp.remainingG.map { t(.spoolLeft, ["g": String(Int($0.rounded()))]) }]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        var pick: (() -> Void)?
        if !afcSpools { pick = { spoolSheet = SpoolSheet(colour: col.index) } }
        return PSRow(label: spoolColours.count > 1 ? t(.colorN, ["n": String(col.index)]) : t(.spool),
                     value: sp?.label ?? t(.noSpool), sub: sub, action: pick, right: {
            ColorDot(color: Color(hexString: sp?.color)).padding(.leading, 8)
        })
    }

    private func spoolSheetView(_ t: L10n, _ colour: Int) -> some View {
        let choices = [Choice(value: String(SpoolPlan.none), label: t(.noSpool), sub: t(.noSpoolSub))]
            + (spools ?? []).map { Choice(value: String($0.id), label: $0.label, group: $0.material, sub: SpoolsView.line(t, $0)) }
        return PickerSheet(title: spoolColours.count > 1 ? t(.colorN, ["n": String(colour)]) : t(.spool), choices: choices,
                           selected: String(spoolFor[colour] ?? SpoolPlan.none), searchLabel: t(.search), closeLabel: "OK") { v in
            if let id = Int(v) { spoolChoice[colour] = id }
        }
    }

    /// Hold the phone to the spool: a linked chip or a matching OpenPrintTag chooses the spool for the colour whose
    /// material fits it; an unknown chip is linked to a spool of the list right away.
    private func pickByNFC(_ t: L10n) async {
        nfcBusy = true
        nfcMsg = nil
        defer { nfcBusy = false }
        do {
            let chip = try await NFC.scanChip(t)
            let list = spools ?? []
            guard let sp = await NFC.identify(app.api, chip, list) else {
                if let tag = chip.tag { nfcMsg = (false, t(.nfcNoMatch, ["tag": tag.label])) }
                if app.api != nil && !list.isEmpty {
                    try? await Task.sleep(for: .milliseconds(450))
                    linkSheet = LinkSheet(uid: chip.uid)
                }
                return
            }
            chooseForNFC(sp, material: sp.material ?? chip.tag?.materialType)
            nfcMsg = (true, chip.tag.map { t(.nfcMatched, ["spool": sp.label, "tag": $0.label]) } ?? t(.nfcLinkedChip, ["spool": sp.label]))
        } catch let e as NFCError {
            let text = e.text(t)
            nfcMsg = text.isEmpty ? nil : (false, text)
        } catch {
            nfcMsg = (false, error.localizedDescription)
        }
    }

    /// The colour whose material fits the spool, else the first one.
    private func chooseForNFC(_ sp: Spool, material: String?) {
        let fitting = spoolColours.filter { LanePlan.fits($0.preset, material: material) }
        if let target = (fitting.isEmpty ? spoolColours : fitting).first { spoolChoice[target.index] = sp.id }
    }

    private func linkSheetView(_ t: L10n, _ uid: String) -> some View {
        let choices = (spools ?? []).map { Choice(value: String($0.id), label: $0.label, group: $0.material, sub: SpoolsView.line(t, $0)) }
        return PickerSheet(title: t(.nfcWhichSpool), choices: choices, selected: nil, searchLabel: t(.search), closeLabel: "OK") { v in
            guard let sp = spools?.first(where: { String($0.id) == v }), let api = app.api else { return }
            Task {
                do {
                    try await api.linkSpoolTag(uid: uid, spool: sp.id)
                    chooseForNFC(sp, material: sp.material)
                    nfcMsg = (true, t(.nfcLinkedNow, ["spool": sp.label]))
                } catch {
                    nfcMsg = (false, error.localizedDescription)
                }
            }
        }
    }

    private func loadSpools() async {
        smSetting = app.spoolmanSetting()
        if let p = printerId { lastSpools = app.lastSpools(p) }
        if reviewing, smSetting != nil, let p = printerId, let api = app.api,
           let s = try? await api.slotSpools(printer: p) {     // older servers: none
            slotSpools = s.spools
        }
        guard reviewing, let setting = smSetting, let sm = app.openSpoolman(setting) else { return }
        do {
            spools = try await sm.spools()
            smError = ""
        } catch {
            smError = error.localizedDescription
        }
    }

    /// After a started print: remember the choice; the filament is booked once the print is over.
    private func afterStart(fileName: String) async {
        guard let p = printerId, smSetting != nil, let spools else { return }
        let chosen = spoolFor
        if !afcSpools { app.saveLastSpools(p, Dictionary(uniqueKeysWithValues: chosen.map { (String($0.key), $0.value) })) }
        if printerBooks { return }
        await app.addBooking(printer: p, printerName: printerName, file: fileName,
                             uses: SpoolPlan.uses(colours: spoolColours, spoolFor: chosen, known: spools), job: id)
    }

    private func laneSheetView(_ t: L10n, _ colour: Int) -> some View {
        let choices = LanePlan.choices(t, lanes: printerLanes)
        return PickerSheet(title: colours.count > 1 ? t(.colorN, ["n": String(colour)]) : t(.slot), choices: choices,
                           selected: laneTools[colour].map(String.init), searchLabel: t(.search), closeLabel: "OK") { v in
            if let tool = Int(v) { laneChoice[colour] = tool }
        }
    }

    private static func trim(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    /// Values Orca changed for this job, in the words of the prepare screen.
    static func changedValues(_ t: L10n, _ o: [String: String]) -> [String] {
        var out: [String] = []
        if o["enable_support"] == "0" {
            out.append("\(t(.supports)): \(t(.supOff))")
        } else if o["enable_support"] == "1" {
            let tree = o["support_type"]?.hasPrefix("tree") == true
            out.append("\(t(.supports)): \(t(tree ? .supTree : .supNormal))")
        }
        switch o["brim_type"] {
        case "auto_brim": out.append("\(t(.brim)): \(t(.brimAuto))")
        case "no_brim": out.append("\(t(.brim)): \(t(.brimOff))")
        case "outer_only": out.append("\(t(.brim)): \(t(.brimOuter))")
        default: break
        }
        if let v = o["sparse_infill_density"], !v.isEmpty {
            out.append("\(t(.infill)): \(v.replacingOccurrences(of: "%", with: " %"))")
        }
        if let v = o["sparse_infill_pattern"], !v.isEmpty { out.append("\(t(.infillPattern)): \(t.infillPattern(v))") }
        if let v = o["wall_loops"], !v.isEmpty { out.append("\(t(.walls)): \(v)") }
        return out
    }

    // MARK: loading

    private func load() async -> Job? {
        guard let api = app.api else { return nil }
        do {
            let j = try await api.job(id: id)
            job = j
            loadError = ""
            return j
        } catch {
            loadError = error.localizedDescription
            return nil
        }
    }

    /// Every 15 s while a started print runs or its time-lapse is made (server 0.33.0 / 0.32.0).
    private func follow() async {
        guard following else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(15))
            if Task.isCancelled { return }
            _ = await load()
        }
    }

    /// Poll every second while the server is working (or while the job cannot be loaded).
    private func poll() async {
        while !Task.isCancelled {
            let j = await load()
            if let j, !j.state.isWorking { return }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    private func tickElapsed() async {
        guard working else { return }
        if elapsed == 0 { startedAt = Date() }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            elapsed = Int(Date().timeIntervalSince(startedAt).rounded())
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = working
    }

    private func loadPrinters() async {
        guard let api = app.api else { return }
        printers = (try? await api.printers()) ?? []
    }

    /// DR-03: is the printer free? Refreshed every 10 s while the job waits for the go.
    private func pollPrinter() async {
        guard !statusKey.isEmpty else { return }
        while !Task.isCancelled {
            await refreshPrinter()
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func refreshPrinter() async {
        guard let p = printerId else { return }
        let st: PrinterStatus?
        if app.isCloud {
            guard let info = printerInfo else { return }  // printer list not loaded yet
            st = try? await app.printerStatus(info)
        } else {
            st = try? await app.api?.status(printer: p)
        }
        printerStatus = st
        printerKind = st?.kind ?? .offline
        if !levelLoaded, let info = printers.first(where: { $0.id == p }), let def = info.leveling {
            level = app.loadLevel(p) ?? def
            levelLoaded = true
        }
    }

    // MARK: actions

    private func send(start: Bool) async {
        guard let api = app.api, let job else { return }
        actionError = ""
        sending = start ? .print : .upload
        defer { sending = nil }
        let levelValue: Bool? = printerInfo?.leveling != nil ? level : nil
        let lanes = printerLanes.isEmpty ? nil : laneTools
        // printers behind a bridge are sent to by the cloud like on an own server
        if app.isCloud, let info = printerInfo, info.bridge == nil {
            await relaySend(job, info, start: start, leveling: levelValue, lanes: lanes)
            return
        }
        do {
            try await api.send(job: job.id, start: start, leveling: levelValue, lanes: lanes, spoolId: start ? activeSpool : nil,
                               timelapse: hasCamera && timelapse)
            var latest: Job?
            for _ in 0..<600 {
                try await Task.sleep(for: .seconds(1))
                latest = try await api.job(id: job.id)
                if latest?.state != .sending { break }
            }
            if let latest { self.job = latest }
            again = false
            if let e = latest?.error, !e.isEmpty {
                actionError = friendlyError(app.l10n, status: 0, detail: e)
            } else {
                if start, let latest, latest.state == .started {
                    // through a bridge the server names the file on the printer
                    let onServer = latest.printerFile ?? ((latest.result?.gcode ?? "") as NSString).lastPathComponent
                    await afterStart(fileName: onServer.isEmpty ? Lan.fileName(source: latest.result?.sourceFile, job: latest.id) : onServer)
                }
                Haptics.success()
            }
        } catch {
            actionError = error.localizedDescription
            await refreshPrinter()
        }
    }

    /// Cloud: the phone is on the home Wi-Fi - G-code from the cloud (slots already mapped) straight to the printer.
    /// Called once per confirmed start or upload; nothing is repeated automatically.
    private func relaySend(_ job: Job, _ printer: Printer, start: Bool, leveling: Bool?, lanes: [Int: Int]?) async {
        // the printer clients report from their own actor; the banner follows through a stream on the main actor
        let (steps, feed) = AsyncStream.makeStream(of: SendProgress.self)
        let options = SendOptions(start: start, leveling: start ? leveling : nil, spoolId: start ? activeSpool : nil,
                                  onStep: { feed.yield(SendProgress(step: $0, part: 0)) },
                                  onProgress: { feed.yield(SendProgress(step: .upload, part: $0)) })
        let banner = Task {
            for await p in steps where !Task.isCancelled { relay = (p.step, p.part) }
        }
        defer {
            feed.finish()
            banner.cancel()
            relay = nil
        }
        do {
            let fileName = Lan.fileName(source: job.result?.sourceFile, job: job.id)
            try await app.relay(job: job.id, printer: printer, fileName: fileName, lanes: lanes, options: options)
            relayed = start ? .print : .upload
            again = false
            // the server follows the print from now on (0.33.0); a failure here doesn't touch the print
            if let api = app.api {
                try? await api.markRelayed(job: job.id, start: start, file: fileName)
                if let j = try? await api.job(id: job.id) { self.job = j }
            }
            if start { await afterStart(fileName: fileName) }
            Haptics.success()
        } catch is NoLanAddress {
            actionError = app.l10n(.needLanAddress)
        } catch {
            actionError = "\(app.l10n(.errRelay)) \(error.localizedDescription)"
        }
        await refreshPrinter()
    }

    /// Own server or bridge printer: does the server reach a camera (camera button, time-lapse switch)?
    private func loadCamera() async {
        guard !cameraKey.isEmpty, let api = app.api else { hasCamera = false; return }
        hasCamera = (try? await api.cameraInfo(printer: cameraKey))?.available ?? false
        if hasCamera && !timelapseDefaulted {
            timelapse = app.timelapseAlways
            timelapseDefaulted = true
        }
    }

    /// SL-10: fetch the G-code and hand it to the share sheet (Files, AirDrop, another slicer app …).
    private func shareGcode(_ job: Job) async {
        guard let api = app.api else { return }
        gcodeLoading = true
        actionError = ""
        defer { gcodeLoading = false }
        let source = ((job.result?.sourceFile ?? "") as NSString).lastPathComponent
        let stem = (source as NSString).deletingPathExtension
        do {
            let url = try await api.downloadGcode(job: job.id, name: (stem.isEmpty ? "print" : stem) + ".gcode")
            gcodeShare = SharedFile(url: url)
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func editSettings(_ job: Job) {
        let r = job.request
        let fromUpload = r.link.hasPrefix("upload:")
        let edit = EditArgs(printer: r.printer ?? job.printer, file: r.file, options: r.options,
                            name: job.result?.sourceFile)
        app.replaceTop(with: .prepare(PrepareArgs(link: r.link, fileName: fromUpload ? job.result?.sourceFile : nil,
                                                  edit: edit)))
    }

    private func delete() async {
        guard let api = app.api, let job else { return }
        do {
            try await api.deleteJob(id: job.id)
            dismiss()
        } catch {
            actionError = error.localizedDescription
        }
    }
}

/// A local file handed to the share sheet.
struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// UIActivityViewController for SwiftUI (ShareLink needs the file before the button is shown).
struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
