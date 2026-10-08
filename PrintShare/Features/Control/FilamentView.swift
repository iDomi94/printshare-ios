import SwiftUI

/// Filament per slot (server 0.37.0, `filament/[id].tsx` of the Expo app): load / unload and what is in each AMS tray or
/// on the external spool holder. Loading and unloading heat the nozzle and move filament - only when no print runs, after
/// a confirmation, never sent twice without a new tap.
/// A spool can be put into a slot (server 0.38.0: NFC scan or the list, stored on the server): the slot gets the spool's
/// material and colour, and the print screen proposes and books that spool for the slot by itself. A chip nobody linked
/// yet (scanned here or seen by an NFC reader at the printer) is linked to a spool once ("which spool is this?").
struct FilamentView: View {
    let printer: String
    let name: String

    /// Common filament colours for the quick choice; any other with the hex field.
    static let swatches = ["#FFFFFF", "#000000", "#8A8A8A", "#E02020", "#FF7A00", "#FFD000", "#3CB043", "#0078BF",
                           "#1E3A8A", "#7B3FA0", "#FF69B4", "#8B5A2B", "#F5DEB3", "#C0C0C0", "#D4AF37", "#00B5B8"]

    private struct Question: Identifiable {
        let id = UUID()
        var text: String
        var confirm: String
        var onConfirm: @MainActor () -> Void
    }

    private enum Sheet: Identifiable {
        case material
        case spool(Lane)
        case link(Lane, uid: String)
        var id: String {
            switch self {
            case .material: return "material"
            case .spool(let l): return "spool-\(l.tool ?? -1)"
            case .link(let l, let uid): return "link-\(l.tool ?? -1)-\(uid)"
            }
        }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var info: FilamentInfo?
    @State private var error = ""
    @State private var done = ""
    @State private var busy = ""
    @State private var question: Question?
    @State private var sheet: Sheet?
    @State private var edit: Lane?
    @State private var material: String?
    @State private var color = "#FFFFFF"
    // spools: own Spoolman or the cloud account's (Settings → Spoolman); which spool sits in which slot
    @State private var spools: [Spool]?
    @State private var slotSpools = SlotSpools()
    @State private var reader: ReaderKey?

    private var hasSpools: Bool { app.spoolmanSetting() != nil }

    var body: some View {
        let t = app.l10n
        Group {
            if info == nil && error.isEmpty {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            } else {
                content(t)
            }
        }
        .navigationTitle(name.isEmpty ? t(.filamentTitle) : "\(t(.filamentTitle)) · \(name)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSpools() }
        .task(id: scenePhase == .active) { await poll() }
        .sheet(item: $sheet) { sheetView(t, $0) }
        .alert(question?.text ?? "", isPresented: Binding(get: { question != nil }, set: { if !$0 { question = nil } }),
               presenting: question) { q in
            Button(t(.cancelBtn), role: .cancel) {}
            Button(q.confirm) { q.onConfirm() }
        }
    }

    private func slotName(_ t: L10n, _ l: Lane) -> String {
        l.tool == FilamentInfo.externalTool ? t(.filamentExternal) : "\(t(.filamentSlot)) \(l.id)"
    }

    private func content(_ t: L10n) -> some View {
        PSScreen {
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if !done.isEmpty { PSBanner(kind: .ok, text: done) }
            if let info, !info.supported { PSBanner(kind: .info, text: t(.filamentUnsupported)) }
            if info?.busy == true { PSBanner(kind: .warn, text: t(.filamentBusy)) }

            if let info, info.supported {
                PSSection(title: t(.filamentSlots), footer: t(.filamentHint)) {
                    ForEach(Array(info.slots.enumerated()), id: \.element.id) { i, l in
                        if i > 0 { PSDivider() }
                        slotRow(t, info, l)
                    }
                }
                if let reader { readerSection(t, reader) }
                if let edit { editSection(t, edit) }
            }
        }
    }

    private func slotRow(_ t: L10n, _ info: FilamentInfo, _ l: Lane) -> some View {
        let scan = l.tool.flatMap { slotSpools.scans[String($0)] }
        let sp = l.tool.flatMap { tool in spools?.first { $0.id == slotSpools.slots[String(tool)]?.spool } }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ColorDot(color: Color(hexString: l.color), size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(slotName(t, l)) · \(l.material ?? (l.loaded ? t(.filamentUnknown) : t(.filamentEmpty)))")
                        .font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                    if let f = l.filament { Text(f).font(.footnote).foregroundStyle(Theme.sub) }
                    if let scan, scan.spool == nil {
                        Button(t(.readerUnknownChip)) { sheet = .link(l, uid: scan.uid) }
                            .font(.footnote).foregroundStyle(Theme.accent)
                    }
                    if let sp {
                        Text(t(.slotSpool, ["spool": sp.label]) + (sp.remainingG.map { " · \(Int($0.rounded())) g" } ?? ""))
                            .font(.footnote).foregroundStyle(Theme.sub)
                    }
                }
                Spacer()
                if l.inToolhead { PSBadge(text: t(.filamentInHead), kind: .accent) }
            }
            HStack(spacing: 8) {
                if info.load && !l.inToolhead && l.loaded {
                    PSButton(title: t(.filamentLoad), kind: .secondary, icon: "arrow.down.circle",
                             loading: busy == "load:\(l.tool ?? -1)", disabled: info.busy || !busy.isEmpty) { askLoad(t, l) }
                }
                if info.unload && l.inToolhead {
                    PSButton(title: t(.filamentUnload), kind: .secondary, icon: "arrow.up.circle",
                             loading: busy == "unload", disabled: info.busy || !busy.isEmpty) { askUnload(t) }
                }
                if info.set {
                    PSButton(title: t(.filamentEdit), kind: .secondary, icon: "paintpalette",
                             loading: busy == "set:\(l.tool ?? -1)", disabled: !busy.isEmpty) { openEdit(l) }
                }
                if hasSpools {
                    PSButton(title: t(.slotSpoolBtn), kind: .secondary, icon: "circle.circle",
                             loading: busy == "nfc:\(l.tool ?? -1)", disabled: !busy.isEmpty) { sheet = .spool(l) }
                }
            }
        }
        .padding(.horizontal, Theme.space).padding(.vertical, 12)
    }

    private func readerSection(_ t: L10n, _ reader: ReaderKey) -> some View {
        PSSection(title: t(.readerTitle), footer: reader.key != nil ? t(.readerKeyHint) : t(.readerHint)) {
            PSRow(icon: "dot.radiowaves.left.and.right", label: reader.enabled ? t(.readerOn) : t(.readerOff),
                  value: reader.enabled ? t(.readerKeyNew) : t(.readerKeyCreate)) { askReaderKey(t, reader) }
            if let key = reader.key {
                PSDivider()
                VStack(alignment: .leading, spacing: 6) {
                    Text(t(.readerUrl)).font(.footnote).foregroundStyle(Theme.sub)
                    Text(reader.url).font(.subheadline).foregroundStyle(Theme.text).textSelection(.enabled)
                    Text(t(.readerKey)).font(.footnote).foregroundStyle(Theme.sub)
                    Text(key).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Theme.space)
            }
        }
    }

    private func editSection(_ t: L10n, _ l: Lane) -> some View {
        let valid = color.matches("^#[0-9A-Fa-f]{6}$")
        return PSSection(title: t(.filamentEditTitle, ["slot": slotName(t, l)])) {
            PSRow(icon: "flask", label: t(.material), value: material ?? t(.chooseModel)) { sheet = .material }
            PSDivider()
            VStack(alignment: .leading, spacing: 12) {
                Text(t(.filamentColor)).font(.footnote).foregroundStyle(Theme.sub)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 40), spacing: 10)], spacing: 10) {
                    ForEach(Self.swatches, id: \.self) { s in
                        let on = color.uppercased() == s
                        Button { Haptics.tap(); color = s } label: {
                            Circle().fill(Color(hexString: s) ?? Theme.track).frame(width: 34, height: 34)
                                .overlay(Circle().stroke(on ? Theme.accent : Theme.line, lineWidth: on ? 3 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(s)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                HStack(spacing: 10) {
                    ColorDot(color: valid ? Color(hexString: color) : nil, size: 28)
                    TextField("#RRGGBB", text: Binding(get: { color }, set: { color = $0.hasPrefix("#") ? $0 : "#\($0)" }))
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .accessibilityLabel(t(.filamentColor))
                }
                PSButton(title: t(.save), icon: "checkmark", disabled: material == nil || !valid) { save(t, l) }
                PSButton(title: t(.cancelBtn), kind: .plain) { edit = nil }
            }
            .padding(Theme.space)
        }
    }

    @ViewBuilder
    private func sheetView(_ t: L10n, _ which: Sheet) -> some View {
        switch which {
        case .material:
            PickerSheet(title: t(.material),
                        choices: (info?.materials ?? []).map { Choice(value: $0.name, label: "\($0.name)  ·  \($0.tempMin)–\($0.tempMax) °C") },
                        selected: material, searchLabel: t(.search), closeLabel: "OK") { material = $0 }
        case .spool(let l):
            let current = l.tool.flatMap { slotSpools.slots[String($0)]?.spool }.map(String.init) ?? "none"
            PickerSheet(title: t(.slotSpoolTitle, ["slot": slotName(t, l)]),
                        choices: (NFC.available ? [Choice(value: "nfc", label: t(.slotSpoolScan))] : [])
                            + [Choice(value: "none", label: t(.slotSpoolNone))] + spoolChoices(t),
                        selected: current, searchLabel: t(.search), closeLabel: "OK") { v in
                Task { await pickSpool(t, l, v) }
            }
        case .link(let l, let uid):
            PickerSheet(title: t(.linkChipTitle, ["slot": slotName(t, l)]), choices: spoolChoices(t), selected: nil,
                        searchLabel: t(.search), closeLabel: "OK") { v in
                Task { await linkChip(t, l, uid: uid, v) }
            }
        }
    }

    private func spoolChoices(_ t: L10n) -> [Choice] {
        (spools ?? []).map { s in
            Choice(value: String(s.id), label: s.label + (s.remainingG.map { " · \(Int($0.rounded())) g" } ?? ""),
                   group: s.material ?? "?")
        }
    }

    // MARK: load / unload / set

    private func askLoad(_ t: L10n, _ l: Lane) {
        let temp = info?.loadTemp(l) ?? 220
        question = Question(text: t(.filamentLoadQ, ["slot": slotName(t, l), "temp": String(temp)]), confirm: t(.filamentLoad)) {
            Task { await run("load:\(l.tool ?? -1)", .load(l.tool), t(.filamentLoading, ["slot": slotName(t, l)])) }
        }
    }

    private func askUnload(_ t: L10n) {
        let temp = info?.loadTemp(info?.slots.first { $0.inToolhead }) ?? 220
        question = Question(text: t(.filamentUnloadQ, ["temp": String(temp)]), confirm: t(.filamentUnload)) {
            Task { await run("unload", .unload, t(.filamentUnloading)) }
        }
    }

    private func openEdit(_ l: Lane) {
        edit = l
        material = info?.material(of: l)?.name
        color = l.color ?? "#FFFFFF"
    }

    private func save(_ t: L10n, _ l: Lane) {
        guard let material else { return }
        let c = color.uppercased()
        edit = nil
        Task { await run("set:\(l.tool ?? -1)", .set(l.tool, material: material, color: c), t(.filamentSaved, ["slot": slotName(t, l)])) }
    }

    private func run(_ key: String, _ action: FilamentAction, _ message: String) async {
        guard let api = app.api else { return }
        busy = key
        done = ""
        defer { busy = "" }
        do {
            try await api.filament(printer: printer, action)
            done = message
            error = ""
            try? await Task.sleep(for: .milliseconds(1500))
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: spools per slot (server 0.38.0)

    /// Put a spool into a slot (on the server); the printer's slot gets the spool's material and colour - by the server
    /// where it can, else here.
    private func assign(_ t: L10n, _ l: Lane, _ spool: Spool?) async {
        guard let api = app.api, let tool = l.tool else { return }
        do {
            let r = try await api.setSlotSpool(printer: printer, tool: tool, spool: spool?.id)
            slotSpools.slots = r.slots
            guard let spool else { done = t(.slotSpoolCleared, ["slot": slotName(t, l)]); return }
            let message = t(.slotSpoolSet, ["slot": slotName(t, l), "spool": spool.label])
            if r.printerSet {
                done = message
                try? await Task.sleep(for: .milliseconds(1500))
                await load()
                return
            }
            if let info, info.set, let m = info.material(forSpool: spool.material), let c = spool.color,
               c.matches("^#[0-9A-Fa-f]{6}") {
                await run("set:\(tool)", .set(tool, material: m.name, color: String(c.prefix(7)).uppercased()), message)
            } else {
                done = message
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func pickSpool(_ t: L10n, _ l: Lane, _ v: String) async {
        if v == "none" { return await assign(t, l, nil) }
        if v == "nfc" {
            busy = "nfc:\(l.tool ?? -1)"
            error = ""
            done = ""
            defer { busy = "" }
            do {
                let chip = try await NFC.scanChip(t)
                if let hit = await NFC.identify(app.api, chip, spools ?? []) { return await assign(t, l, hit) }
                if let tag = chip.tag, spools?.isEmpty ?? true {
                    error = t(.slotSpoolNoMatch, ["material": tag.materialType ?? "?"])
                    return
                }
                // unknown chip: link it to a spool now
                try? await Task.sleep(for: .milliseconds(450))
                sheet = .link(l, uid: chip.uid)
            } catch let e as NFCError {
                error = e.text(t)
            } catch {
                self.error = error.localizedDescription
            }
            return
        }
        if let sp = spools?.first(where: { String($0.id) == v }) { await assign(t, l, sp) }
    }

    /// Link an unknown chip to a spool - from now on the phone and the readers know it - and put the spool in the slot.
    private func linkChip(_ t: L10n, _ l: Lane, uid: String, _ v: String) async {
        guard let api = app.api, let sp = spools?.first(where: { String($0.id) == v }) else { return }
        do {
            try await api.linkSpoolTag(uid: uid, spool: sp.id)
            await assign(t, l, sp)
            if let s = try? await api.slotSpools(printer: printer) { slotSpools = s }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func askReaderKey(_ t: L10n, _ reader: ReaderKey) {
        guard reader.enabled else { Task { await newReaderKey() }; return }
        question = Question(text: t(.readerKeyRenewQ), confirm: t(.readerKeyNew)) { Task { await newReaderKey() } }
    }

    private func newReaderKey() async {
        guard let api = app.api else { return }
        do { reader = try await api.createReaderKey(printer: printer) } catch { self.error = error.localizedDescription }
    }

    // MARK: loading

    private func load() async {
        guard let api = app.api else { return }
        do {
            info = try await api.filamentInfo(printer: printer)
            error = ""
        } catch {
            if info == nil || error.localizedDescription != self.error { self.error = error.localizedDescription }
        }
    }

    /// Every 4 s while visible: loading / unloading can be followed as it happens.
    private func poll() async {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(4))
        }
    }

    private func loadSpools() async {
        guard let api = app.api else { return }
        if let s = try? await api.slotSpools(printer: printer) { slotSpools = s }   // older servers: none
        reader = try? await api.readerKey(printer: printer)
        if let setting = app.spoolmanSetting(), let sm = app.openSpoolman(setting) {
            spools = (try? await sm.spools()) ?? []
        }
    }
}
