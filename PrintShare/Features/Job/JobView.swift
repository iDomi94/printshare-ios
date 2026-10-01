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
    @State private var plateOk = false
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
        .alert(t(.confirmStartQ, ["printer": printerName]), isPresented: $confirmStart) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.start)) { Task { await send(start: true) } }
        }
        .sheet(item: $gcodeShare) { ActivitySheet(items: [$0.url]).ignoresSafeArea() }
        .sheet(item: $laneSheet) { sheet in laneSheetView(t, sheet.colour) }
        .sheet(item: $camera) { CameraView(printer: $0.printer, title: $0.name) }
        .task(id: job?.state == .started) { await loadCamera() }
        .alert(t(.deleteJobQ), isPresented: $confirmDelete) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.del), role: .destructive) { Task { await delete() } }
        }
    }

    private var statusKey: String {
        guard let job, job.state == .sliced || job.state == .uploaded else { return "" }
        return printerId ?? ""
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
        default: reviewView(t, job)
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

    // MARK: review / sent

    private func reviewView(_ t: L10n, _ job: Job) -> some View {
        let r = job.result
        let profiles = r?.profiles ?? [:]
        let changed = Self.changedValues(t, r?.overrides ?? [:])
        // plate options only from servers that know them (0.14.0 reports copies_requested)
        let arranged = r?.knowsPlate == true ? PlateOptions.summary(t, job.request.options, placed: r?.copies) : ""
        let fewer = PlateOptions.fewerHint(t, r)
        let name = Format.jobName(file: r?.sourceFile, link: job.request.link)
        let done = job.state == .started
        let uploaded = job.state == .uploaded
        let busy = printerKind?.isBusy ?? false
        let offline = printerKind == .offline
        let laneWarnings = done ? [] : LanePlan.warnings(t, colours: colours, lanes: printerLanes, tools: laneTools)
        let canPrint = plateOk && !busy && !offline && sending == nil && !laneWarnings.contains(where: \.blocking)
        let material = Format.shortName(profiles["filament"])
        var shareAction: (() -> Void)?
        if !gcodeLoading { shareAction = { Task { await shareGcode(job) } } }
        return PSScreen {
            if done || uploaded {
                VStack(spacing: 6) {
                    Image(systemName: done ? "checkmark.circle.fill" : "checkmark.icloud.fill")
                        .font(.system(size: 60)).foregroundStyle(Theme.ok).accessibilityHidden(true)
                    Text(t(done ? .startedTitle : .uploadedTitle)).font(.title2.bold()).foregroundStyle(Theme.text)
                        .padding(.top, 6)
                    Text(t(done ? .startedSub : .uploadedSub)).font(.subheadline).foregroundStyle(Theme.sub)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 20)
            } else {
                Text(t(.reviewTitle)).font(.largeTitle.bold()).foregroundStyle(Theme.text).padding(.bottom, 4)
            }
            Text(name).font(.subheadline).foregroundStyle(Theme.sub).lineLimit(2).padding(.bottom, 16)

            if !actionError.isEmpty { PSBanner(kind: .error, text: actionError) }
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
            }

            if !done {
                if busy { PSBanner(kind: .warn, text: t(.printerBusy, ["printer": printerName])) }
                if offline { PSBanner(kind: .error, text: t(.printerOffline, ["printer": printerName])) }
                PSCard(padding: 16) {
                    Toggle(isOn: $plateOk) {
                        Text(t(.confirmPlate, ["material": material.isEmpty ? t(.filament) : material]))
                            .font(.body).foregroundStyle(Theme.text)
                    }
                    .tint(Theme.accent)
                    .onChange(of: plateOk) { _, _ in Haptics.tap() }
                }
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
                PSButton(title: t(.editSettings), kind: .plain, icon: "slider.horizontal.3") { editSettings(job) }
                    .padding(.top, 12)
            }
            PSButton(title: t(.deleteJob), kind: .plain) { confirmDelete = true }.padding(.top, 4)
        } footer: {
            if done {
                PSButton(title: t(.toPrinter), icon: "printer") { app.navigate(to: .printers) }
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
        guard let api = app.api, let p = printerId else { return }
        let st = try? await api.status(printer: p)
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
        do {
            let levelValue: Bool? = printerInfo?.leveling != nil ? level : nil
            let lanes = printerLanes.isEmpty ? nil : laneTools
            try await api.send(job: job.id, start: start, leveling: levelValue, lanes: lanes)
            var latest: Job?
            for _ in 0..<600 {
                try await Task.sleep(for: .seconds(1))
                latest = try await api.job(id: job.id)
                if latest?.state != .sending { break }
            }
            if let latest { self.job = latest }
            if let e = latest?.error, !e.isEmpty {
                actionError = friendlyError(app.l10n, status: 0, detail: e)
            } else {
                Haptics.success()
            }
        } catch {
            actionError = error.localizedDescription
            await refreshPrinter()
        }
    }

    private func loadCamera() async {
        guard job?.state == .started, let api = app.api, let p = printerId else { return }
        hasCamera = (try? await api.cameraInfo(printer: p))?.available ?? false
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
