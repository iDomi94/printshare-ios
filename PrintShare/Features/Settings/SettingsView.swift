import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var online: Bool?
    @State private var serverVersion = ""
    @State private var route: Route?
    @State private var confirmDisconnect = false
    @State private var printers: [Printer] = []
    @State private var me: Me?
    @State private var confirmLogout = false
    @State private var confirmDelete = false
    @State private var confirmDeleteAgain = false
    @State private var accountError: String?
    @State private var spoolman: String?

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "–"
    }

    var body: some View {
        let t = app.l10n
        let server = app.server
        PSScreen {
            if let server, server.isCloud {
                account(t, server)
            } else {
                serverSection(t, server)
            }

            PSSection(title: t(.language)) {
                Picker("", selection: Binding(get: { app.langPref }, set: { app.setLangPref($0) })) {
                    Text(t(.langAuto)).tag(LangPref.auto)
                    Text("Deutsch").tag(LangPref.de)
                    Text("English").tag(LangPref.en)
                }
                .pickerStyle(.segmented).labelsHidden().padding(12)
            }

            if let server { advanced(t, cloud: server.isCloud) }

            PSSection(title: t(.about), footer: t(server?.isCloud == true ? .aboutTextCloud : .aboutText)) {
                PSRow(icon: "info.circle", label: t(.version), value: appVersion)
                if server?.isCloud == true {
                    PSDivider()
                    PSRow(icon: "checkmark.shield", label: "pocketprint3d.com/privacy") {
                        if let u = URL(string: "https://pocketprint3d.com/privacy/") { openURL(u) }
                    }
                }
                PSDivider()
                PSRow(icon: "chevron.left.forwardslash.chevron.right", label: t(.sourceCode)) {
                    if let u = URL(string: "https://github.com/halvar20000/printshare") { openURL(u) }
                }
            }
            if server?.isCloud == true {
                PSSection {
                    PSRow(icon: "trash", label: t(.deleteAccount), danger: true) { confirmDelete = true }
                }
            }
            Text("PocketPrint3D · MIT").font(.caption).foregroundStyle(Theme.sub).frame(maxWidth: .infinity)
        }
        .navigationTitle(t(.tabSettings))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .task(id: app.server) { await loadInfo() }
        .onAppear { spoolman = app.spoolmanSetting() }
        .alert(t(.disconnectQ), isPresented: $confirmDisconnect) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.disconnect), role: .destructive) { app.setServer(nil) }
        }
        .alert(t(.logoutQ), isPresented: $confirmLogout) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.logout), role: .destructive) { Task { await logout() } }
        }
        .alert(t(.deleteAccountQ), isPresented: $confirmDelete) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.deleteAccount), role: .destructive) { confirmDeleteAgain = true }
        }
        .alert(t(.deleteAccountQ2), isPresented: $confirmDeleteAgain) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.deleteAccount), role: .destructive) { Task { await deleteAccount() } }
        }
        .alert(t(.deleteAccount), isPresented: Binding(get: { accountError != nil }, set: { if !$0 { accountError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(accountError ?? "")
        }
    }

    /// Cloud (server 0.15.0): account, slices today, the account's printers with their Wi-Fi address on this phone.
    @ViewBuilder
    private func account(_ t: L10n, _ server: Server) -> some View {
        PSSection(title: t(.account)) {
            PSRow(icon: "icloud", label: t(.modeCloud), sub: server.email, right: { statusBadge(t) })
            if let me {
                PSDivider()
                PSRow(icon: "square.stack.3d.up", label: t(.slicesToday, ["used": String(me.limits.slicesToday),
                                                                          "limit": String(me.limits.slicesPerDay)]))
            }
            PSDivider()
            PSRow(icon: "arrow.left.arrow.right", label: t(.changeAccount)) { app.showConnect() }
            PSDivider()
            PSRow(icon: "rectangle.portrait.and.arrow.right", label: t(.logout)) { confirmLogout = true }
        }
        PSSection(title: t(.tabPrinters)) {
            ForEach(Array(printers.enumerated()), id: \.element.id) { i, p in
                if i > 0 { PSDivider() }
                PSRow(icon: "printer", label: p.name, sub: t.printerTypeName(p.type)) {
                    app.push(.cloudPrinter(id: p.id))
                }
            }
            if !printers.isEmpty { PSDivider() }
            PSRow(icon: "plus.circle", label: t(.addPrinter)) { app.push(.cloudPrinter(id: CloudPrinterView.new)) }
        }
    }

    @ViewBuilder
    private func serverSection(_ t: L10n, _ server: Server?) -> some View {
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
    }

    /// "Erweitert" (server 0.26): bridges + spools in the cloud; spools, Manyfold and failure detection on own
    /// servers (the last two answer 409 in the cloud).
    @ViewBuilder
    private func advanced(_ t: L10n, cloud: Bool) -> some View {
        PSSection(title: t(.advanced)) {
            if cloud {
                PSRow(icon: "point.3.connected.trianglepath.dotted", label: t(.bridgesTitle), sub: t(.bridgesSub)) {
                    app.push(.bridges)
                }
                PSDivider()
            }
            PSRow(icon: "circle.circle", label: t(.spoolman),
                  value: spoolman == nil ? t(.spoolsOptional) : nil,
                  sub: spoolman == Spoolman.cloudSetting ? t(.spoolsCloudOn) : spoolman ?? t(.spoolmanSub)) {
                app.push(.spoolman)
            }
            if !cloud {
                PSDivider()
                PSRow(icon: "books.vertical", label: t(.manyfoldTitle), sub: t(.manyfoldSub)) { app.push(.manyfold) }
                PSDivider()
                PSRow(icon: "eye", label: t(.failureTitle), sub: t(.failureSub)) { app.push(.failureDetection) }
            }
        }
    }

    private func logout() async {
        // offline: the session just stays unused on the server
        try? await app.api?.logout()
        app.setServer(nil)
    }

    private func deleteAccount() async {
        guard let api = app.api else { return }
        do {
            try await api.deleteAccount()
            app.setServer(nil)
        } catch {
            accountError = error.localizedDescription
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
        me = nil
        if app.isCloud { me = try? await api.me() }
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
