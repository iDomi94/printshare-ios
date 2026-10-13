import SwiftUI

/// Spool and NFC reader for printers with one slot (tool 0: Centauri Carbon without CANVAS, Prusa …), on the control page
/// (`SpoolReader.tsx` of the Expo app, upstream 04a9e4d): which spool is in the printer (the print screen proposes and
/// books it), the chip the reader last saw ("which spool is this?" for a new one) and the reader key for the ESP32 + PN5180
/// firmware. Printers with several slots have all of this on the filament screen (`FilamentView`).
struct SpoolReaderSection: View {
    let printer: String
    /// The slot of a printer without slots.
    static let slot = 0

    private enum Pick: Identifiable {
        case spool, link
        var id: Int { self == .spool ? 0 : 1 }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var slots: SlotSpools?
    @State private var reader: ReaderKey?
    @State private var spools: [Spool]?
    @State private var pick: Pick?
    @State private var error = ""
    @State private var askNewKey = false

    var body: some View {
        let t = app.l10n
        Group {
            // older server: nothing to show
            if slots != nil || reader != nil { content(t) }
        }
        .task { await load() }
        .task(id: scenePhase == .active) { await poll() }
        .sheet(item: $pick) { sheetView(t, $0) }
        .alert(t(.readerKeyRenewQ), isPresented: $askNewKey) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.readerKeyNew)) { Task { await newKey() } }
        }
    }

    private var scan: SlotSpools.Scan? { slots?.scans[String(Self.slot)] }
    private var spoolId: Int? { slots?.slots[String(Self.slot)]?.spool }
    private var spool: Spool? { spools?.first { $0.id == spoolId } }

    private func content(_ t: L10n) -> some View {
        VStack(alignment: .leading, spacing: Theme.space) {
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            PSSection(title: t(.spoolReaderTitle), footer: reader?.key != nil ? t(.readerKeyHint) : t(.spoolReaderHint)) {
                PSRow(icon: "circle.circle", label: t(.spoolInPrinter),
                      value: spool?.label ?? spoolId.map { "#\($0)" } ?? t(.spoolNone),
                      sub: spool?.remainingG.map { "\(Int($0.rounded())) g" },
                      action: (spools ?? []).isEmpty ? nil : { pick = .spool })
                if let scan, scan.spool == nil {
                    PSDivider()
                    PSRow(icon: "questionmark.circle", label: t(.readerUnknownChip), sub: scan.uid,
                          action: (spools ?? []).isEmpty ? nil : { pick = .link })
                }
                if let reader {
                    PSDivider()
                    PSRow(icon: "dot.radiowaves.left.and.right", label: t(.readerTitle),
                          value: reader.enabled ? t(.readerKeyNew) : t(.readerKeyCreate), sub: reader.enabled ? t(.readerOn) : t(.readerOff)) {
                        if reader.enabled { askNewKey = true } else { Task { await newKey() } }
                    }
                    if let key = reader.key {
                        PSDivider()
                        VStack(alignment: .leading, spacing: 6) {
                            Text(t(.readerUrl)).font(.footnote).foregroundStyle(Theme.sub)
                            Text(reader.url).font(.subheadline).foregroundStyle(Theme.text).textSelection(.enabled)
                            Text(t(.readerKey)).font(.footnote).foregroundStyle(Theme.sub)
                            Text(key).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text).textSelection(.enabled)
                            Text(t(.readerSlot, ["slot": String(Self.slot)])).font(.footnote).foregroundStyle(Theme.sub)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Theme.space)
                    }
                }
            }
        }
    }

    private func choices() -> [Choice] {
        (spools ?? []).map { s in
            Choice(value: String(s.id), label: s.label + (s.remainingG.map { " · \(Int($0.rounded())) g" } ?? ""),
                   group: s.material ?? "?")
        }
    }

    @ViewBuilder
    private func sheetView(_ t: L10n, _ which: Pick) -> some View {
        switch which {
        case .spool:
            PickerSheet(title: t(.spoolInPrinter), choices: [Choice(value: "none", label: t(.spoolNone))] + choices(),
                        selected: spoolId.map(String.init) ?? "none", searchLabel: t(.search), closeLabel: "OK") { v in
                Task { await onPick(v, link: false) }
            }
        case .link:
            PickerSheet(title: t(.linkChipTitle, ["slot": t(.spoolInPrinter)]), choices: choices(), selected: nil,
                        searchLabel: t(.search), closeLabel: "OK") { v in
                Task { await onPick(v, link: true) }
            }
        }
    }

    private func onPick(_ v: String, link: Bool) async {
        guard let api = app.api else { return }
        error = ""
        do {
            if link, let scan, let id = Int(v) {
                try await api.linkSpoolTag(uid: scan.uid, spool: id)      // the server puts it in the slot
            } else {
                _ = try await api.setSlotSpool(printer: printer, tool: Self.slot, spool: Int(v))   // "none" empties the slot
            }
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func newKey() async {
        guard let api = app.api else { return }
        do { reader = try await api.createReaderKey(printer: printer) } catch { self.error = error.localizedDescription }
    }

    private func load() async {
        guard let api = app.api else { return }
        slots = try? await api.slotSpools(printer: printer)
        if let r = try? await api.readerKey(printer: printer), reader?.key == nil { reader = r }   // keep a fresh key shown
        if let setting = app.spoolmanSetting(), let sm = app.openSpoolman(setting) {
            spools = (try? await sm.spools()) ?? []
        }
    }

    /// Every 5 s while visible: a reader may report a spool or an unknown chip.
    private func poll() async {
        guard scenePhase == .active else { return }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(5))
            if let api = app.api, let s = try? await api.slotSpools(printer: printer) { slots = s }
        }
    }
}
