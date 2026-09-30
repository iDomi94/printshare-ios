import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var online: Bool?
    @State private var serverVersion = ""
    @State private var route: Route?
    @State private var confirmDisconnect = false
    @State private var printers: [Printer] = []

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    var body: some View {
        let t = app.l10n
        let server = app.server
        PSScreen {
            PSSection(title: t(.server)) {
                PSRow(icon: "server.rack", label: server.map { $0.url.replacingRegex("^https?://", with: "") } ?? t(.notConnected),
                      sub: serverSub(t), right: { statusBadge(t) })
                if let remote = server?.remoteUrl, !remote.isEmpty {
                    PSDivider()
                    PSRow(icon: "globe", label: t(.remoteUrl), sub: remote.replacingRegex("^https?://", with: ""))
                }
                PSDivider()
                PSRow(icon: "qrcode", label: server != nil ? t(.changeServer) : t(.connectNow)) { app.showConnect() }
                if server != nil {
                    PSDivider()
                    PSRow(icon: "rectangle.portrait.and.arrow.right", label: t(.disconnect), danger: true) {
                        confirmDisconnect = true
                    }
                }
            }

            if server != nil && !printers.isEmpty {
                PSSection(title: t(.tabPrinters)) {
                    ForEach(Array(printers.enumerated()), id: \.element.id) { i, p in
                        if i > 0 { PSDivider() }
                        PSRow(icon: "printer", label: p.name, sub: t(.printerProfile)) {
                            app.push(.printerProfile(id: p.id, name: p.name))
                        }
                    }
                }
            }

            PSSection(title: t(.language)) {
                Picker("", selection: Binding(get: { app.langPref }, set: { app.setLangPref($0) })) {
                    Text(t(.langAuto)).tag(LangPref.auto)
                    Text("Deutsch").tag(LangPref.de)
                    Text("English").tag(LangPref.en)
                }
                .pickerStyle(.segmented).labelsHidden().padding(12)
            }

            PSSection(title: t(.about), footer: t(.aboutText)) {
                PSRow(icon: "info.circle", label: t(.version), value: appVersion)
                PSDivider()
                PSRow(icon: "chevron.left.forwardslash.chevron.right", label: t(.sourceCode)) {
                    if let u = URL(string: "https://github.com/halvar20000/printshare") { openURL(u) }
                }
            }
            Text("PocketPrint3D · MIT").font(.caption).foregroundStyle(Theme.sub).frame(maxWidth: .infinity)
        }
        .navigationTitle(t(.tabSettings))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: app.server) { await loadInfo() }
        .alert(t(.disconnectQ), isPresented: $confirmDisconnect) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.disconnect), role: .destructive) { app.setServer(nil) }
        }
    }

    private func serverSub(_ t: L10n) -> String? {
        guard app.server != nil, !serverVersion.isEmpty else { return nil }
        var parts = ["PocketPrint3D \(serverVersion)"]
        if let route { parts.append(t(route == .home ? .routeHome : .routeRemote)) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func statusBadge(_ t: L10n) -> some View {
        if app.server != nil {
            PSBadge(text: online == false ? t(.offline) : online == true ? t(.connected) : "…",
                    kind: online == false ? .error : online == true ? .ok : .neutral)
        }
    }

    private func loadInfo() async {
        guard let api = app.api else { online = nil; printers = []; return }
        printers = (try? await api.printers()) ?? []
        do {
            let info = try await api.info()
            online = true
            serverVersion = info.version
            route = await api.route()
        } catch {
            online = false
            route = nil
        }
    }
}
