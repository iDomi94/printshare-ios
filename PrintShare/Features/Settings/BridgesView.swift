import SwiftUI

/// Cloud (server 0.24-0.34, docs/BRIDGE.md): bridges at home - "print from anywhere". A bridge is the user's own
/// PocketPrint3D server (Unraid, Home Assistant, Docker, or the ready-made Raspberry Pi image) with "Connect to
/// PocketPrint3D Cloud" on; it shows a code that is entered here. Its printers then appear in the account by
/// themselves; more can be added through the bridge. A Pi bridge on the same Wi-Fi is found by itself and paired with
/// one tap: the app fetches its code from the bridge (only handed out on the home network).
struct BridgesView: View {
    private enum LanState { case searching, done, noWifi }

    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var bridges: [Bridge]?
    @State private var code = ""
    @State private var busy = false
    @State private var error = ""
    @State private var paired: String?
    @State private var lan: [Discovery.FoundBridge] = []
    @State private var lanState = LanState.searching
    @State private var lanRun = 0
    @State private var joining: String?
    @State private var removeTarget: Bridge?

    /// "k7q4m2zx" / "K7Q4 M2ZX" → "K7Q4-M2ZX" while typing.
    static func formatCode(_ v: String) -> String {
        let raw = String(v.uppercased().filter { ($0.isASCII && $0.isLetter) || ($0.isASCII && $0.isNumber) }.prefix(8))
        return raw.count > 4 ? "\(raw.prefix(4))-\(raw.dropFirst(4))" : raw
    }

    var body: some View {
        let t = app.l10n
        PSScreen {
            Text(t(.bridgeIntro)).font(.subheadline).foregroundStyle(Theme.sub).padding(.bottom, 16)
            PSCard {
                PSRow(icon: "cpu", label: t(.bridgeGuide), sub: t(.bridgeGuideSub)) {
                    let u = t.lang == .de ? "https://pocketprint3d.com/de/bruecke/" : "https://pocketprint3d.com/bridge/"
                    if let url = URL(string: u) { openURL(url) }
                }
            }
            .padding(.bottom, 16)
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if let paired { PSBanner(kind: .ok, text: t(.bridgePaired, ["name": paired])) }

            PSSection(title: t(.bridgeLanTitle), footer: lanFooter(t)) {
                ForEach(Array(lan.enumerated()), id: \.element.id) { i, b in
                    if i > 0 { PSDivider() }
                    lanRow(t, b)
                }
                if !lan.isEmpty { PSDivider() }
                if lanState == .searching {
                    PSRow(icon: "magnifyingglass", label: t(.bridgeLanSearching), right: { ProgressView() })
                } else {
                    PSRow(icon: "arrow.clockwise", label: t(.discoverAgain)) { lan = []; lanState = .searching; lanRun += 1 }
                }
            }

            PSSection(title: t(.bridgeConnect), footer: t(.bridgeCodeHint)) {
                TextField("K7Q4-M2ZX", text: Binding(get: { code }, set: { code = Self.formatCode($0); error = "" }))
                    .font(.title2.weight(.semibold)).kerning(3).multilineTextAlignment(.center)
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    .padding(.horizontal, Theme.space).padding(.vertical, 14)
                    .accessibilityLabel(t(.bridgeCode))
                    .onSubmit { Task { await pair(code) } }
                PSButton(title: t(.bridgeConnectBtn), icon: "link", loading: busy,
                         disabled: code.replacingOccurrences(of: "-", with: "").count != 8) {
                    Task { await pair(code) }
                }
                .padding([.horizontal, .bottom], Theme.space)
            }

            if bridges == nil { ProgressView().frame(maxWidth: .infinity).padding(.top, 20) }
            ForEach(bridges ?? []) { b in bridgeCard(t, b) }
        }
        .navigationTitle(t(.bridgesTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: lanRun) { await scan() }
        .alert(t(.bridgeRemoveQ, ["name": removeTarget?.name ?? ""]),
               isPresented: Binding(get: { removeTarget != nil }, set: { if !$0 { removeTarget = nil } })) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.del), role: .destructive) {
                if let b = removeTarget { Task { await remove(b) } }
            }
        }
    }

    private func lanFooter(_ t: L10n) -> String {
        switch lanState {
        case .noWifi: return t(.bridgeLanNoWifi)
        case .done where lan.isEmpty: return t(.bridgeLanNone)
        default: return t(.bridgeLanHint)
        }
    }

    @ViewBuilder
    private func lanRow(_ t: L10n, _ b: Discovery.FoundBridge) -> some View {
        let mine = b.bridgeId.map { id in (bridges ?? []).contains { $0.id == id } } ?? false
        let state = mine ? t(.bridgeLanMine)
            : b.paired ? t(.bridgeLanOther, ["account": b.account ?? "?"])
            : b.pairable ? t(.bridgeLanFree) : b.bridgeOnly ? t(.bridgeLanStarting) : t(.bridgeLanServer)
        let sub = "\(state) · \(b.address.replacingRegex("^https?://", with: ""))"
        let canJoin = b.pairable && !mine && joining == nil
        PSRow(icon: "cpu", label: b.name, sub: sub, action: canJoin ? { Task { await join(b) } } : nil) {
            if joining == b.address {
                ProgressView()
            } else if b.pairable && !mine {
                PSBadge(text: t(.bridgeConnectBtn), kind: .accent)
            } else if mine {
                PSBadge(text: t(.connected), kind: .ok)
            }
        }
    }

    private func bridgeCard(_ t: L10n, _ b: Bridge) -> some View {
        var sub: [String] = []
        if let v = b.version, !v.isEmpty { sub.append("PocketPrint3D \(v)") }
        if !b.online, let seen = b.lastSeen { sub.append(t(.bridgeLastSeen, ["v": Format.ago(t, seen)])) }
        return PSCard { VStack(spacing: 0) {
            PSRow(icon: "point.3.connected.trianglepath.dotted", label: b.name,
                  sub: sub.isEmpty ? nil : sub.joined(separator: " · ")) {
                PSBadge(text: b.online ? t(.connected) : t(.offline), kind: b.online ? .ok : .error)
            }
            ForEach(b.printers) { p in
                PSDivider()
                PSRow(icon: "printer", label: p.name, sub: p.type.map { t.printerTypeName($0) })
            }
            PSDivider()
            PSRow(icon: "plus.circle", label: t(.bridgeAddPrinter), sub: b.online ? nil : t(.bridgeNeedsOnline),
                  action: b.online ? { app.push(.cloudPrinter(id: CloudPrinterView.new, bridge: b.id)) } : nil)
            PSDivider()
            PSRow(icon: "trash", label: t(.bridgeRemove), danger: true) { removeTarget = b }
        } }
        .padding(.bottom, 16)
    }

    private func load() async {
        guard let api = app.api else { return }
        do {
            bridges = try await api.bridges()
        } catch {
            self.error = errorText(app.l10n, error)
            if bridges == nil { bridges = [] }
        }
    }

    /// Pair with a code (typed, or fetched from a bridge on the Wi-Fi); the bridge picks up its token within a few
    /// seconds and connects, so the list is loaded again after a moment.
    private func pair(_ code: String) async {
        guard let api = app.api, !busy else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            let b = try await api.pairBridge(code: code)
            paired = b.name
            self.code = ""
            await load()
            Task {
                try? await Task.sleep(for: .seconds(4))
                await load()
            }
        } catch {
            self.error = errorText(app.l10n, error)
        }
    }

    private func scan() async {
        lanState = .searching
        do {
            for try await b in Discovery.bridges() { lan.append(b) }
            if !Task.isCancelled { lanState = .done }
        } catch {
            if !Task.isCancelled { lanState = error is Discovery.NoWifi ? .noWifi : .done }
        }
    }

    private func join(_ b: Discovery.FoundBridge) async {
        guard let api = app.api else { return }
        joining = b.address
        error = ""
        defer { joining = nil }
        do {
            let res = try await api.pairBridge(code: try await Discovery.bridgeLocalCode(b.address))
            paired = res.name
            if let i = lan.firstIndex(of: b) { lan[i].paired = true; lan[i].pairable = false }
            await load()
            Task {
                try? await Task.sleep(for: .seconds(4))
                await load()
            }
        } catch {
            self.error = errorText(app.l10n, error)
        }
    }

    private func remove(_ b: Bridge) async {
        guard let api = app.api else { return }
        do {
            try await api.deleteBridge(id: b.id)
            await load()
        } catch {
            self.error = errorText(app.l10n, error)
        }
    }
}
