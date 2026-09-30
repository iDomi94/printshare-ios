import SwiftUI

/// Live status and control of every printer (DR-04, DR-05, DR-06).
struct PrintersView: View {
    private struct Entry: Identifiable {
        var printer: Printer
        var status: PrinterStatus?
        var id: String { printer.id }
    }

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    @State private var entries: [Entry]?
    @State private var error = ""
    @State private var acting = ""
    @State private var cancelTarget: Printer?
    @State private var camera: CameraTarget?

    private struct CameraTarget: Identifiable {
        var url: URL
        var name: String
        var id: String { url.absoluteString }
    }

    var body: some View {
        let t = app.l10n
        PSScreen(refresh: { await load() }) {
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if let entries {
                if entries.isEmpty { PSEmpty(icon: "printer", title: t(.noPrinters)) }
                ForEach(entries) { card(t, $0) }
            }
        }
        .navigationTitle(t(.tabPrinters))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .sheet(item: $camera) { CameraView(url: $0.url, title: $0.name) }
        .task(id: scenePhase == .active) { await pollWhileVisible() }
        .alert(t(.cancelPrint), isPresented: Binding(get: { cancelTarget != nil }, set: { if !$0 { cancelTarget = nil } }),
               presenting: cancelTarget) { p in
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.cancelPrint), role: .destructive) { Task { await run(p, "cancel") } }
        } message: { p in
            Text(t(.cancelPrintQ, ["printer": p.name]))
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
                    Text(p.name).font(.title3.bold()).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 8)
                    PSBadge(text: label, kind: badge)
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
                } else {
                    Text(t(.errPrinterOffline)).font(.subheadline).foregroundStyle(Theme.sub)
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
                if let cam = s?.camera, let url = URL(string: cam) {
                    PSButton(title: t(.camera), kind: .plain, icon: "video") {
                        camera = CameraTarget(url: url, name: p.name)
                    }
                    .padding(.top, 6)
                }
            }
        }
        .padding(.bottom, 16)
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

    private func load() async {
        guard let api = app.api else { return }
        do {
            let list = try await api.printers()
            var out: [Entry] = []
            for p in list {
                out.append(Entry(printer: p, status: try? await api.status(printer: p.id)))
            }
            entries = out
            error = ""
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run(_ p: Printer, _ action: String) async {
        guard let api = app.api else { return }
        acting = "\(p.id):\(action)"
        do { try await api.control(printer: p.id, action: action) }
        catch { self.error = error.localizedDescription }
        acting = ""
        try? await Task.sleep(for: .milliseconds(800))
        await load()
    }
}
