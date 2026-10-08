import SwiftUI

/// Own OrcaSlicer presets from an Orca Cloud account (server 0.42.0, issue #7). Orca Cloud lets apps read a user's synced
/// presets after a pairing (code confirmed on the Orca Cloud page); each app needs an app ID (`client_id`) from the Orca
/// Cloud team. PocketPrint3D has none yet, so the user enters one unless the server sets it. The server keeps the tokens
/// and pulls the presets now and every 6 hours; they then show up like uploaded presets.
struct OrcaAccountView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var state: OrcaAccount?
    @State private var idInput = ""
    @State private var busy = ""
    @State private var error = ""
    @State private var done = ""
    @State private var confirmDisconnect = false
    @State private var askRemove = false

    /// A pairing waits for the user's OK in Orca Cloud: follow it.
    private var waiting: Bool { state?.pending.map { $0.error == nil } ?? false }

    var body: some View {
        let t = app.l10n
        Group {
            if let state { content(t, state) } else if !error.isEmpty {
                PSScreen { PSBanner(kind: .error, text: error) }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            }
        }
        .navigationTitle(t(.orcaAccountTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: waiting) {
            guard waiting else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await load()
            }
        }
        .alert(t(.orcaDisconnectQ), isPresented: $confirmDisconnect) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.orcaDisconnect), role: .destructive) { askRemove = true }
        }
        .alert(t(.orcaRemovePresetsQ), isPresented: $askRemove) {
            Button(t(.orcaKeepPresets)) { Task { await disconnect(removePresets: false) } }
            Button(t(.del), role: .destructive) { Task { await disconnect(removePresets: true) } }
        }
    }

    private func content(_ t: L10n, _ s: OrcaAccount) -> some View {
        let fromServer = s.clientIdFrom == "server"
        return PSScreen {
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if !done.isEmpty { PSBanner(kind: .ok, text: done) }
            if let e = s.lastError, error.isEmpty { PSBanner(kind: .warn, text: e) }
            Text(t(.orcaAccountIntro)).font(.subheadline).foregroundStyle(Theme.sub)
                .padding(.horizontal, 4).padding(.bottom, 16)

            PSSection(title: t(.orcaIdTitle), footer: fromServer ? t(.orcaIdServer) : t(.orcaIdHint)) {
                if fromServer {
                    PSRow(icon: "key", label: t(.orcaIdTitle), value: s.clientId ?? "")
                } else {
                    TextField("oc_app_…", text: $idInput)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .padding(.horizontal, Theme.space).padding(.vertical, 14)
                        .accessibilityLabel(t(.orcaIdTitle))
                    PSDivider()
                    PSButton(title: t(.save), kind: .secondary, icon: "checkmark", loading: busy == "id",
                             disabled: idInput.trimmed == (s.clientId ?? "")) { Task { await saveId() } }
                        .padding(Theme.space)
                }
            }

            if let p = s.pending { pairing(t, p) }

            if s.connected {
                PSSection(title: t(.orcaAccountTitle)) {
                    PSRow(icon: "checkmark.circle", label: t(.orcaConnected),
                          sub: s.lastSync.map { t(.orcaLastSync, ["when": Format.ago(t, $0), "n": String(s.count)]) })
                    if !s.skipped.isEmpty {
                        PSDivider()
                        PSRow(icon: "exclamationmark.circle", label: t(.orcaSkipped, ["n": String(s.skipped.count)]),
                              sub: s.skipped.prefix(4).map(\.name).joined(separator: ", "))
                    }
                    PSDivider()
                    PSRow(icon: "arrow.triangle.2.circlepath", label: t(.orcaSyncNow), chevron: false,
                          action: busy.isEmpty ? { Task { await sync() } } : nil) {
                        if busy == "sync" { ProgressView().padding(.leading, 8) }
                    }
                    PSDivider()
                    PSRow(icon: "rectangle.portrait.and.arrow.right", label: t(.orcaDisconnect), danger: true) {
                        confirmDisconnect = true
                    }
                }
            } else {
                PSButton(title: t(s.pending != nil ? .orcaConnectAgain : .orcaConnect), icon: "link",
                         loading: busy == "connect", disabled: (s.clientId ?? "").isEmpty) { Task { await connect() } }
            }
        }
    }

    @ViewBuilder
    private func pairing(_ t: L10n, _ p: OrcaAccount.Pending) -> some View {
        PSSection(title: t(.orcaPairTitle), footer: p.error == nil ? t(.orcaPairHint) : nil) {
            if let e = p.error {
                Text(e == "denied" ? t(.orcaPairDenied) : e == "expired" ? t(.orcaPairExpired) : e)
                    .font(.subheadline).foregroundStyle(Theme.danger).padding(Theme.space)
            } else {
                VStack(spacing: 8) {
                    Text(p.userCode).font(.system(size: 34, weight: .heavy, design: .monospaced)).tracking(3)
                        .foregroundStyle(Theme.text).textSelection(.enabled)
                    HStack(spacing: 8) {
                        ProgressView()
                        Text(t(.orcaPairWaiting)).font(.subheadline).foregroundStyle(Theme.sub)
                    }
                    HStack(spacing: 10) {
                        PSButton(title: t(.orcaCopyCode), kind: .secondary, icon: "doc.on.doc") {
                            UIPasteboard.general.string = p.userCode
                        }
                        if let url = p.verificationUriComplete ?? p.verificationUri {
                            PSButton(title: t(.orcaOpen), kind: .secondary, icon: "arrow.up.right.square") {
                                open(url)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity).padding(Theme.space)
            }
        }
    }

    /// Only the Orca Cloud confirmation page is opened, never an address the user can't see (https only).
    private func open(_ address: String) {
        if let u = URL(string: address), u.scheme == "https" { openURL(u) }
    }

    // MARK: server

    private func load() async {
        guard let api = app.api else { return }
        do {
            let s = try await api.orcaAccount()
            state = s
            if idInput.isEmpty, s.clientIdFrom == "user" { idInput = s.clientId ?? "" }
        } catch {
            if state == nil { self.error = error.localizedDescription }
        }
    }

    private func act(_ key: String, message: String = "", _ call: (APIClient) async throws -> OrcaAccount) async {
        guard let api = app.api else { return }
        busy = key
        error = ""
        done = ""
        defer { busy = "" }
        do {
            state = try await call(api)
            if !message.isEmpty { done = message }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func saveId() async {
        let id = idInput.trimmed
        await act("id", message: app.l10n(.orcaIdSaved)) { try await $0.setOrcaClientId(id.isEmpty ? nil : id) }
    }

    private func connect() async {
        await act("connect") { try await $0.connectOrca() }
        if let p = state?.pending, p.error == nil, let url = p.verificationUriComplete ?? p.verificationUri { open(url) }
    }

    private func sync() async {
        await act("sync") { try await $0.syncOrca() }
        if error.isEmpty, let n = state?.count { done = app.l10n(.orcaSynced, ["n": String(n)]) }
    }

    private func disconnect(removePresets: Bool) async {
        await act("off", message: app.l10n(.orcaDisconnected)) { try await $0.disconnectOrca(removePresets: removePresets) }
    }
}
