import SwiftUI

/// Model -> printer, material, quality, plate, supports … -> slice (spec sections 3 + 4).
struct PrepareView: View {
    let args: PrepareArgs

    private enum SheetKind: Identifiable, Hashable {
        case printer, filament, process, plate, file, tilt, infillPattern
        case color(Int)  // material for filament n of a multicolour model (or 1 with printer slots)
        case slot(Int)  // printer slot (AFC lane) for filament n

        var id: String {
            switch self {
            case .printer: return "printer"
            case .filament: return "filament"
            case .process: return "process"
            case .plate: return "plate"
            case .file: return "file"
            case .tilt: return "tilt"
            case .infillPattern: return "infillPattern"
            case .color(let n): return "color\(n)"
            case .slot(let n): return "slot\(n)"
            }
        }
    }

    @Environment(AppModel.self) private var app
    @State private var link: String?
    @State private var name: String
    @State private var error = ""
    @State private var listed: (link: String, files: [ModelFile])?
    @State private var file: String?
    @State private var printers: [Printer] = []
    @State private var printersLoaded = false
    @State private var kinds: [String: PrinterKind] = [:]
    @State private var statuses: [String: PrinterStatus] = [:]
    /// Printer slot (tool number) per model colour, chosen by the user; others follow `LanePlan.tools`.
    @State private var slotChoice: [Int: Int] = [:]
    @State private var printer = ""
    @State private var opts: Options?
    @State private var filament = ""
    @State private var process = ""
    @State private var plate = ""
    @State private var supports = "off"
    @State private var brim = "auto"
    @State private var infill: Int?  // nil = profile default
    @State private var infillPattern: String?  // nil = profile default
    @State private var walls: Int?
    // plate (server 0.14.0): kept when the printer changes, taken over when editing a job
    @State private var copies: Int
    @State private var tilt: PlateTilt
    @State private var scale: Int
    @State private var showMore = false
    @State private var sheet: SheetKind?
    @State private var submitting = false
    @State private var firstLoad = true
    /// Colours of a 3MF project, per `colorKey`; data nil = no colour info (single-colour flow).
    @State private var colorInfo: (key: String, data: ModelColors?)?
    @State private var perColor: [Int: String] = [:]

    init(args: PrepareArgs) {
        self.args = args
        _link = State(initialValue: args.link)
        _name = State(initialValue: args.fileName ?? args.edit?.name ?? "")
        _file = State(initialValue: args.edit?.file)
        _copies = State(initialValue: args.edit?.options?.copies ?? 1)
        _tilt = State(initialValue: PlateTilt(options: args.edit?.options))
        _scale = State(initialValue: args.edit?.options?.scale ?? 100)
    }

    private var files: [ModelFile]? {
        guard let listed, listed.link == link else { return nil }  // nil while loading
        return listed.files
    }

    private var uploading: Bool { args.fileURL != nil && link == nil && error.isEmpty }
    private var needsFile: Bool { (files?.count ?? 0) > 1 && file == nil }

    // MA-04: a 3MF project may have several colours; then the app asks for a material per colour.
    private var chosenFileName: String? {
        guard let files else { return nil }
        return files.count == 1 ? files[0].name : files.first { String($0.index) == file }?.name
    }

    private var colorKey: String? {
        guard let link, let files, let name = chosenFileName, name.lowercased().hasSuffix(".3mf") else { return nil }
        return "\(link)|\(files.count > 1 ? (file ?? "") : "")"
    }

    private var colors: ModelColors? {
        guard let key = colorKey, let info = colorInfo, info.key == key else { return nil }
        return info.data
    }

    private var colorsLoading: Bool { colorKey != nil && colorInfo?.key != colorKey }
    private var multi: Bool { colors?.isMulticolor ?? false }

    // Printer slots (AFC lanes, issue #6): with a multi-slot printer the user picks the slot per colour; its
    // material and colour come from the printer and the slicing material follows the slot.
    private var lanes: [Lane] { LanePlan.usable(statuses[printer]) }
    private var slotMode: Bool { !lanes.isEmpty }

    private var modelColours: [LanePlan.Colour] {
        if multi, let colors {
            return colors.usedFilaments.map { LanePlan.Colour(index: $0.index, color: $0.color, preset: perColor[$0.index] ?? filament) }
        }
        return [LanePlan.Colour(index: 1, color: nil, preset: perColor[1] ?? filament)]
    }

    private var slotTools: [Int: Int] { LanePlan.tools(colours: modelColours, lanes: lanes, choice: slotChoice) }

    private func lane(for index: Int) -> Lane? {
        guard let tool = slotTools[index] else { return nil }
        return lanes.first { $0.tool == tool }
    }

    /// Filament preset for colour `index`: the user's own choice, else the one matching the slot's material.
    private func material(for index: Int) -> String {
        if !multi && !slotMode { return filament }
        if let own = perColor[index] { return own }
        if slotMode, let p = LanePlan.preset(for: lane(for: index), materials: opts?.materials ?? [],
                                             preferred: filament, fallback: opts?.defaults.filament) {
            return p
        }
        return filament
    }

    var body: some View {
        let t = app.l10n
        Group {
            if uploading {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.large)
                    Text(t(.uploading)).font(.body).foregroundStyle(Theme.text).padding(.top, 10)
                    if !name.isEmpty { Text(name).foregroundStyle(Theme.sub) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            } else {
                form(t)
            }
        }
        .navigationTitle(t(.prepareTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task(id: args) { await upload() }
        .task(id: link) { await listFiles() }
        .task { await loadPrinters() }
        // back from adding the first printer: load the list again
        .onAppear { if printersLoaded && printers.isEmpty { Task { await loadPrinters() } } }
        .task(id: printer) { await loadOptions() }
        .task(id: printer) { await refreshStatus() }
        .task(id: colorKey) { await inspectColors() }
    }

    // MARK: form

    private func form(_ t: L10n) -> some View {
        let ready = link != nil && opts != nil && files != nil && !printer.isEmpty
        return PSScreen {
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            modelSection(t)
            printerSection(t)
            if printersLoaded && printers.isEmpty && error.isEmpty {
                noPrinter(t)
            } else if let opts {
                optionSections(t, opts)
            } else if !printer.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.top, 24)
            }
        } footer: {
            PSButton(title: t(.slice), icon: "square.3.layers.3d", loading: submitting, disabled: !ready || needsFile) {
                Task { await submit() }
            }
        }
        .sheet(item: $sheet) { kind in
            PickerSheet(title: sheetTitle(t, kind), choices: choices(t, kind), selected: sheetValue(kind),
                        searchLabel: t(.search), closeLabel: "OK", onPick: { pick(kind, $0) },
                        leading: kind == .infillPattern ? Self.infillThumb : nil)
        }
    }

    private func modelSection(_ t: L10n) -> some View {
        PSSection(title: t(.model)) {
            PSRow(icon: "cube", label: name.isEmpty ? Format.jobName(file: nil, link: link) : name,
                  sub: (link ?? "").hasPrefix("upload:") ? nil : link)
            if files == nil && link != nil {
                PSDivider()
                PSRow(label: t(.filesLoading), right: { ProgressView() })
            } else if let files, files.count > 1 {
                PSDivider()
                let chosen = files.first { String($0.index) == file }?.name
                PSRow(icon: "doc", label: chosen ?? t(.filesMany, ["n": String(files.count)])) { sheet = .file }
            } else if let files, files.count == 1, name.isEmpty {
                PSDivider()
                PSRow(icon: "doc", label: files[0].name)
            }
        }
    }

    /// A fresh cloud account has no printer yet: say so instead of an empty screen, with the way to add one.
    @ViewBuilder
    private func noPrinter(_ t: L10n) -> some View {
        if app.isCloud {
            PSEmpty(icon: "printer", title: t(.noPrinters), sub: t(.noPrintersCloud)) {
                PSButton(title: t(.addPrinter), icon: "plus") { app.push(.cloudPrinter(id: CloudPrinterView.new)) }
            }
        } else {
            PSEmpty(icon: "printer", title: t(.noPrinters))
        }
    }

    @ViewBuilder
    private func printerSection(_ t: L10n) -> some View {
        if !(printers.isEmpty && error.isEmpty) {
            PSSection(title: t(.printer)) {
                let current = printers.first { $0.id == printer }
                PSRow(icon: "printer", label: current?.name ?? (printer.isEmpty ? "…" : printer),
                      value: kindLabel(t, printer), chevron: printers.count > 1,
                      action: printers.count > 1 ? { sheet = .printer } : nil,
                      right: { if !printer.isEmpty { statusDot(printer) } })
            }
        }
    }

    @ViewBuilder
    private func optionSections(_ t: L10n, _ opts: Options) -> some View {
        let d = opts.defaults
        ForEach(Format.comboWarnings(t, filament: multi ? filament : material(for: 1), plate: plate), id: \.self) { PSBanner(kind: .warn, text: $0) }
        if multi, let colors {
            PSSection(title: t(.colors), footer: slotMode ? t(.slotsPrepareHint) : t(colors.painted ? .colorsPainted : .colorsHint)) {
                ForEach(Array(colors.usedFilaments.enumerated()), id: \.element.index) { i, f in
                    if i > 0 { PSDivider() }
                    if slotMode {
                        slotRow(t, index: f.index, label: t(.colorN, ["n": String(f.index)]), modelColor: f.color)
                    } else {
                        PSRow(label: t(.colorN, ["n": String(f.index)]), value: Format.shortName(perColor[f.index] ?? filament),
                              action: { sheet = .color(f.index) },
                              right: { ColorDot(color: Color(hexString: f.color)).padding(.leading, 10) })
                    }
                }
            }
        }
        if slotMode {
            ForEach(slotWarnings(t), id: \.self) { PSBanner(kind: .warn, text: $0) }
        }
        PSSection {
            if !multi && slotMode {
                slotRow(t, index: 1, label: t(.slot), modelColor: nil)
                PSDivider()
                PSRow(icon: "paintpalette", label: t(.material), value: Format.shortName(material(for: 1)),
                      action: { sheet = .color(1) }, right: { if colorsLoading { ProgressView().padding(.leading, 8) } })
                PSDivider()
            } else if !multi {
                PSRow(icon: "paintpalette", label: t(.material), value: Format.shortName(filament),
                      action: { sheet = .filament }, right: { if colorsLoading { ProgressView().padding(.leading, 8) } })
                PSDivider()
            }
            PSRow(icon: "speedometer", label: t(.quality), value: Format.shortName(process)) { sheet = .process }
            PSDivider()
            PSRow(icon: "square.grid.3x3", label: t(.plate), value: Format.plateName(t, plate)) { sheet = .plate }
        }
        PSSection {
            PSField(label: t(.supports)) {
                PSSegmented(values: opts.supports, selection: $supports) { supportLabel(t, $0) }
            }
        }
        PSSection(title: t(.arrange), footer: copies > 1 ? t(.arrangeHint) : nil) {
            PSField(label: t(.copies)) {
                PSStepper(value: copies, range: 1...PlateOptions.maxCopies, format: { t(.copiesV, ["n": String($0)]) }) { copies = $0 }
            }
            PSDivider()
            PSRow(icon: "cube", label: t(.tilt), value: t(tilt.label)) { sheet = .tilt }
            PSDivider()
            PSField(label: t(.size), hint: scale == 100 ? t(.standard) : nil) {
                PSStepper(value: scale, range: PlateOptions.scaleRange, step: 25, format: { "\($0) %" }) { scale = $0 }
            }
        }
        Button { Haptics.tap(); withAnimation { showMore.toggle() } } label: {
            HStack {
                Text(t(.more)).font(.body).foregroundStyle(Theme.accent)
                Spacer()
                Image(systemName: showMore ? "chevron.up" : "chevron.down").foregroundStyle(Theme.accent)
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
        }
        .buttonStyle(.plain)
        if showMore {
            PSSection {
                PSField(label: t(.brim)) {
                    PSSegmented(values: opts.brims, selection: $brim) { brimLabel(t, $0) }
                }
                PSDivider()
                PSField(label: t(.infill), hint: infill == nil || infill == d.infill ? t(.standard) : nil) {
                    PSStepper(value: infill ?? d.infill ?? 15, range: 0...100, step: 5, format: { "\($0) %" }) { infill = $0 }
                }
                // server 0.15.2: pattern + a 3 × 3 cm picture in real size of what pattern and percentage give
                if let pattern = infillPattern ?? d.infillPattern,
                   !InfillPattern.choices(server: opts.infillPatterns, current: d.infillPattern).isEmpty {
                    PSDivider()
                    PSRow(label: t(.infillPattern), value: t.infillPattern(pattern),
                          sub: infillPattern == nil || infillPattern == d.infillPattern ? t(.standard) : nil,
                          action: { sheet = .infillPattern }, right: { InfillThumb(pattern: pattern, size: 28).padding(.leading, 4) })
                    InfillRealSize(pattern: pattern, density: infill ?? d.infill ?? 15,
                                   lineWidth: d.infillLineWidth ?? InfillPattern.defaultLineWidth, t: t)
                }
                PSDivider()
                PSField(label: t(.walls), hint: walls == nil || walls == d.walls ? t(.standard) : nil) {
                    PSStepper(value: walls ?? d.walls ?? 2, range: 1...10) { walls = $0 }
                }
            }
        }
    }

    /// One colour's slot: "Slot 1 · PLA" with the printer's filament colour; long-press to choose the material.
    private func slotRow(_ t: L10n, index: Int, label: String, modelColor: String?) -> some View {
        let lane = lane(for: index)
        return PSRow(icon: multi ? nil : "tray.2", label: label, value: LanePlan.label(t, lane: lane, lanes: lanes),
                     sub: multi ? Format.shortName(material(for: index)) : nil,
                     action: { sheet = .slot(index) }, right: {
            HStack(spacing: 4) {
                if let c = modelColor { ColorDot(color: Color(hexString: c), size: 14) }
                ColorDot(color: Color(hexString: lane?.color), size: 22)
            }
            .padding(.leading, 8)
        })
        .contextMenu {
            Button(t(.chooseMaterial), systemImage: "paintpalette") { sheet = .color(index) }
        }
    }

    /// Empty slot or another material than the chosen preset. Not blocking here: filament can still be loaded
    /// before printing, the job screen blocks the start.
    private func slotWarnings(_ t: L10n) -> [String] {
        let cols = modelColours.map { LanePlan.Colour(index: $0.index, color: $0.color, preset: material(for: $0.index)) }
        return LanePlan.warnings(t, colours: cols, lanes: lanes, tools: slotTools).map(\.text)
    }

    private func supportLabel(_ t: L10n, _ v: String) -> String {
        switch v {
        case "off": return t(.supOff)
        case "normal": return t(.supNormal)
        case "tree": return t(.supTree)
        default: return v
        }
    }

    private func brimLabel(_ t: L10n, _ v: String) -> String {
        switch v {
        case "auto": return t(.brimAuto)
        case "off": return t(.brimOff)
        case "outer": return t(.brimOuter)
        default: return v
        }
    }

    // MARK: printers

    private func kindLabel(_ t: L10n, _ id: String) -> String? {
        kinds[id].map { t.printerKind($0.rawValue) }
    }

    private func statusDot(_ id: String) -> some View {
        let color: Color
        switch kinds[id] {
        case nil: color = Theme.sub
        case .offline?, .error?: color = Theme.danger
        case .idle?, .done?, .stopped?: color = Theme.ok
        default: color = Theme.warn
        }
        return Circle().fill(color).frame(width: 10, height: 10).accessibilityHidden(true)
    }

    // MARK: picker sheets

    private func sheetTitle(_ t: L10n, _ k: SheetKind) -> String {
        switch k {
        case .printer: return t(.printer)
        case .filament: return t(.material)
        case .process: return t(.quality)
        case .plate: return t(.plate)
        case .file: return t(.file)
        case .tilt: return t(.tilt)
        case .infillPattern: return t(.infillPattern)
        case .color(let n): return multi ? t(.colorN, ["n": String(n)]) : t(.material)
        case .slot(let n): return multi ? t(.colorN, ["n": String(n)]) : t(.slot)
        }
    }

    private func sheetValue(_ k: SheetKind) -> String? {
        switch k {
        case .printer: return printer
        case .filament: return filament
        case .process: return process
        case .plate: return plate
        case .file: return file
        case .tilt: return tilt.rawValue
        case .infillPattern: return infillPattern ?? opts?.defaults.infillPattern
        case .color(let n): return material(for: n)
        case .slot(let n): return slotTools[n].map(String.init)
        }
    }

    @MainActor private static func infillThumb(_ pattern: String) -> AnyView { AnyView(InfillThumb(pattern: pattern)) }

    private func choices(_ t: L10n, _ k: SheetKind) -> [Choice] {
        switch k {
        case .printer:
            return printers.map { Choice(value: $0.id, label: $0.name, sub: kindLabel(t, $0.id)) }
        case .filament, .color:
            // uploaded presets come first from the server and get their own group (server 0.13.0)
            let own = Set(opts?.own?.materials ?? [])
            return (opts?.materials ?? []).map {
                Choice(value: $0, label: Format.shortName($0), group: own.contains($0) ? t(.ownProfiles) : Format.brandOf($0))
            }
        case .process:
            let own = Set(opts?.own?.processes ?? [])
            return (opts?.processes ?? []).map {
                Choice(value: $0, label: Format.shortName($0), group: own.contains($0) ? t(.ownProfiles) : nil)
            }
        case .plate:
            return (opts?.plates ?? []).map { Choice(value: $0, label: Format.plateName(t, $0)) }
        case .file:
            return (files ?? []).map { Choice(value: String($0.index), label: $0.name, sub: $0.size.map(Format.mb)) }
        case .slot:
            return LanePlan.choices(t, lanes: lanes)
        case .tilt:
            return PlateTilt.allCases.map { Choice(value: $0.rawValue, label: t($0.label)) }
        case .infillPattern:
            let standard = opts?.defaults.infillPattern
            return InfillPattern.choices(server: opts?.infillPatterns, current: standard).map {
                let hint = t.infillHint($0)
                let sub = $0 == standard ? [t(.standard), hint].compactMap { $0 }.joined(separator: " · ") : hint
                return Choice(value: $0, label: t.infillPattern($0), sub: sub)
            }
        }
    }

    private func pick(_ k: SheetKind, _ v: String) {
        switch k {
        case .printer: printer = v
        case .filament: filament = v
        case .process: Task { await changeProcess(v) }
        case .plate: plate = v
        case .file: file = v
        case .tilt: tilt = PlateTilt(rawValue: v) ?? .asModel
        case .infillPattern: infillPattern = v
        case .color(let n): perColor[n] = v
        case .slot(let n):
            // a new slot brings its own material: drop an earlier material choice for this colour
            if let tool = Int(v) { slotChoice[n] = tool; perColor[n] = nil }
        }
    }

    // MARK: loading (same order as the Expo screen)

    /// 1. file from the phone -> upload to the server first
    private func upload() async {
        guard let api = app.api, let url = args.fileURL, link == nil else { return }
        do {
            let u = try await api.upload(fileURL: url, name: args.fileName ?? "model.stl")
            link = u.link
            name = u.name
            SharedInbox.removeStaged(url)  // the server has it now (shared files would pile up in the App Group)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 2. files of the model (MQ-02)
    private func listFiles() async {
        guard let api = app.api, let link else { return }
        do {
            let fl = try await api.files(link: link)
            listed = (link, fl)
            if fl.count == 1 {
                file = nil
            } else if args.edit?.file == nil {
                let threeMf = fl.filter { $0.name.lowercased().hasSuffix(".3mf") }
                file = threeMf.count == 1 ? String(threeMf[0].index) : nil
            }
        } catch {
            listed = (link, [])
            self.error = error.localizedDescription
        }
    }

    /// 3. printers + their state (DV-01)
    private func loadPrinters() async {
        guard let api = app.api else { return }
        do {
            let list = try await api.printers()
            printers = list
            printersLoaded = true
            let last = args.edit?.printer ?? app.lastPrinter()
            printer = list.first { $0.id == last }?.id ?? list.first?.id ?? ""
            for p in list {
                Task {
                    let st = try? await app.printerStatus(p)  // cloud: the app asks the printer on the Wi-Fi
                    kinds[p.id] = st?.kind ?? .offline
                    if let st { statuses[p.id] = st }
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// 3b. fresh state of the chosen printer: its slots and what is loaded in them
    private func refreshStatus() async {
        slotChoice = [:]
        guard !printer.isEmpty, let p = printers.first(where: { $0.id == printer }) else { return }
        let chosen = printer
        guard let st = try? await app.printerStatus(p) else { return }
        statuses[chosen] = st
        kinds[chosen] = st.kind
    }

    /// 4. presets for the chosen printer, preselected with the last choices (spec 4)
    private func loadOptions() async {
        guard let api = app.api, !printer.isEmpty else { return }
        let chosen = printer
        do {
            let useEdit = firstLoad ? args.edit?.options : nil
            let prefs = app.loadPrefs(chosen)
            let prefFilament = useEdit?.filament ?? prefs?.filament
            let prefProcess = useEdit?.process ?? prefs?.process
            let prefPlate = useEdit?.bedType ?? prefs?.bedType
            var o = try await api.options(printer: chosen)
            let wanted = prefProcess.flatMap { o.processes.contains($0) ? $0 : nil } ?? o.defaults.process
            if wanted != o.defaults.process { o = try await api.options(printer: chosen, process: wanted) }
            guard chosen == printer else { return }
            opts = o
            filament = prefFilament.flatMap { o.materials.contains($0) ? $0 : nil } ?? o.defaults.filament
            process = o.defaults.process
            plate = prefPlate.flatMap { o.plates.contains($0) ? $0 : nil } ?? o.defaults.bedType
            applyDefaults(o, keep: useEdit)
            firstLoad = false
        } catch {
            if chosen == printer { self.error = error.localizedDescription }
        }
    }

    /// 2b. colours of a 3MF project (MA-04). Any failure falls back to the single-colour flow.
    private func inspectColors() async {
        guard let api = app.api, let key = colorKey, let link, let files else { return }
        do {
            let data = try await api.inspect(link: link, file: files.count > 1 ? file : nil)
            guard key == colorKey else { return }
            colorInfo = (key, data)
            if let saved = args.edit?.options?.filaments, perColor.isEmpty {
                for (i, f) in saved.enumerated() { if let f { perColor[i + 1] = f } }
            }
        } catch {
            if key == colorKey { colorInfo = (key, nil) }
        }
    }

    private func applyDefaults(_ o: Options, keep: JobOptions?) {
        let d = o.defaults
        supports = keep?.supports ?? d.supports
        brim = keep?.brim ?? d.brim
        infill = keep?.infill
        infillPattern = keep?.infillPattern
        walls = keep?.walls
    }

    private func changeProcess(_ p: String) async {
        guard let api = app.api, let current = opts, p != process else { return }
        process = p
        do {
            let o = try await api.options(printer: printer, process: p)
            var merged = current
            merged.defaults = o.defaults
            opts = merged
            applyDefaults(o, keep: nil)
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: submit

    private func submit() async {
        guard let api = app.api, let link, let opts else { return }
        let d = opts.defaults
        if needsFile { error = app.l10n(.chooseFile); return }
        var o = JobOptions(process: process, bedType: plate)
        let single = multi ? filament : material(for: 1)
        if single != d.filament { o.filament = single }
        if supports != d.supports { o.supports = supports }
        if brim != d.brim { o.brim = brim }
        if let infill, infill != d.infill { o.infill = infill }
        if let infillPattern, infillPattern != d.infillPattern { o.infillPattern = infillPattern }
        if let walls, walls != d.walls { o.walls = walls }
        PlateOptions.apply(copies: copies, tilt: tilt, scale: scale, to: &o)
        if multi, let colors {
            let used = Set(colors.usedFilaments.map(\.index))
            o.filaments = colors.filaments.map { f -> String? in
                slotMode && used.contains(f.index) ? material(for: f.index) : perColor[f.index]
            }
        }
        let slots = slotMode ? slotTools : [:]
        submitting = true
        error = ""
        defer { submitting = false }
        do {
            app.saveLastPrinter(printer)
            app.savePrefs(printer, PrinterPrefs(filament: filament, process: process, bedType: plate))
            let job = try await api.createJob(link: link, printer: printer, file: file, options: o)
            if !slots.isEmpty { app.plannedSlots[job] = slots }
            app.replaceTop(with: .job(job))
        } catch {
            self.error = error.localizedDescription
        }
    }
}
