import SwiftUI

enum BridgeCode {
    /// "k7q4m2zx" / "K7Q4 M2ZX" → "K7Q4-M2ZX" while typing (codes have no 0/O and 1/I).
    static func format(_ input: String) -> String {
        let raw = String(input.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
        return raw.count > 4 ? "\(raw.prefix(4))-\(raw.dropFirst(4))" : raw
    }
}

/// Cloud (server 0.24.0-0.26.0, upstream docs/BRIDGE.md): bridges at home - "print from anywhere". A bridge is the user's
/// own PocketPrint3D server (Unraid, Home Assistant, Docker) with "Connect to PocketPrint3D Cloud" switched on; it shows
/// a code that is entered here. Its printers then appear in the account by themselves, more can be added through it.
struct BridgesView: View {
    @Environment(AppModel.self) private var app
    @State private var bridges: [Bridge]?
    @State private var code = ""
    @State private var busy = false
    @State private var error = ""
    @State private var paired: String?
    @State private var removeTarget: Bridge?

    var body: some View {
        let t = app.l10n
        PSScreen(refresh: { await load() }) {
            Text(t(.bridgeIntro)).font(.subheadline).foregroundStyle(Theme.sub).padding(.bottom, 16)
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if let paired { PSBanner(kind: .ok, text: t(.bridgePaired, ["name": paired])) }

            PSSection(title: t(.bridgeConnect), footer: t(.bridgeCodeHint)) {
                TextField("K7Q4-M2ZX", text: Binding(get: { code }, set: { code = BridgeCode.format($0); error = "" }))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.space).padding(.vertical, 14)
                    .accessibilityLabel(t(.bridgeCode))
                    .onSubmit { Task { await pair() } }
                PSDivider()
                PSButton(title: t(.bridgeConnectBtn), icon: "link", loading: busy,
                         disabled: code.filter { $0 != "-" }.count != 8) { Task { await pair() } }
                    .padding(Theme.space)
            }

            if bridges == nil { ProgressView().frame(maxWidth: .infinity).padding(.top, 20) }
            ForEach(bridges ?? []) { b in bridge(t, b) }
        }
        .navigationTitle(t(.bridgesTitle))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task { await load() }
        .alert(t(.bridgeRemoveQ, ["name": removeTarget?.name ?? ""]),
               isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } }),
               presenting: removeTarget) { b in
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.del), role: .destructive) { Task { await remove(b) } }
        }
    }

    private func bridge(_ t: L10n, _ b: Bridge) -> some View {
        let sub = [b.version.map { "PocketPrint3D \($0)" },
                   !b.online ? b.lastSeen.map { t(.bridgeLastSeen, ["v": Format.ago(t, $0)]) } : nil]
            .compactMap { $0 }.joined(separator: " · ")
        return PSSection {
            PSRow(icon: "point.3.connected.trianglepath.dotted", label: b.name, sub: sub.isEmpty ? nil : sub,
                  right: { PSBadge(text: b.online ? t(.connected) : t(.offline), kind: b.online ? .ok : .error) })
            ForEach(b.printers) { p in
                PSDivider()
                PSRow(icon: "printer", label: p.name, sub: p.type.map { t.printerTypeName($0) })
            }
            PSDivider()
            PSRow(icon: "plus.circle", label: t(.bridgeAddPrinter), sub: b.online ? nil : t(.bridgeNeedsOnline),
                  action: b.online ? { app.push(.bridgePrinter(bridge: b.id)) } : nil)
            PSDivider()
            PSRow(icon: "trash", label: t(.bridgeRemove), danger: true) { removeTarget = b }
        }
    }

    private func load() async {
        guard let api = app.api else { return }
        do {
            bridges = try await api.bridges()
        } catch {
            self.error = error.localizedDescription
            if bridges == nil { bridges = [] }
        }
    }

    private func pair() async {
        guard let api = app.api, !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            let b = try await api.pairBridge(code: code)
            paired = b.name
            code = ""
            await load()
            // the bridge picks up its token within a few seconds and connects
            try? await Task.sleep(for: .seconds(4))
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(_ b: Bridge) async {
        guard let api = app.api else { return }
        do {
            try await api.deleteBridge(id: b.id)
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
