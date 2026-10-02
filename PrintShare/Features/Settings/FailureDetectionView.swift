import SwiftUI

/// AI failure detection (server 0.23.0, own servers only): Obico's ML API on the user's server checks camera pictures
/// while printing. The server saves the setting only after the ML API fetched and checked a test picture.
struct FailureDetectionView: View {
    @Environment(AppModel.self) private var app
    @State private var cfg: FailureConfig?
    @State private var mlUrl = ""
    @State private var token = ""
    @State private var serverUrl = ""
    @State private var sensitivity = "medium"
    @State private var action = "notify"
    @State private var busy = false
    @State private var error = ""
    @State private var done = ""
    @State private var confirmRemove = false

    var body: some View {
        let t = app.l10n
        Group {
            if let cfg { content(t, cfg) } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            }
        }
        .navigationTitle(t(.failureTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert(t(.failureRemove) + "?", isPresented: $confirmRemove) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.del), role: .destructive) { Task { await remove() } }
        }
    }

    private func field(_ placeholder: String, _ text: Binding<String>, label: String) -> some View {
        TextField(placeholder, text: text)
            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            .padding(.horizontal, Theme.space).padding(.vertical, 14)
            .accessibilityLabel(label)
    }

    private func content(_ t: L10n, _ c: FailureConfig) -> some View {
        PSScreen {
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if !done.isEmpty { PSBanner(kind: .ok, text: done) }
            PSSection(title: t(.failureTitle), footer: t(.failureHint)) {
                field("http://192.168.1.10:3333", $mlUrl, label: t(.failureMl))
                PSDivider()
                SecureField(c.tokenSet ? t(.failureTokenKept) : t(.failureToken), text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(.horizontal, Theme.space).padding(.vertical, 14)
                    .accessibilityLabel(t(.failureToken))
                PSDivider()
                Text(t(.failureServer)).font(.footnote).foregroundStyle(Theme.sub)
                    .padding(.horizontal, Theme.space).padding(.top, 10)
                field("http://192.168.1.10:8484", $serverUrl, label: t(.failureServer))
            }
            PSSection(title: t(.failureSensitivity)) {
                PSSegmented(values: ["low", "medium", "high"], selection: $sensitivity, label: {
                    t($0 == "low" ? .sensLow : $0 == "high" ? .sensHigh : .sensMedium)
                })
                .padding(12)
            }
            PSSection(title: t(.failureAction), footer: t(.failureNote)) {
                PSSegmented(values: ["notify", "pause"], selection: $action, label: {
                    t($0 == "pause" ? .actionPause : .actionNotify)
                })
                .padding(12)
            }
            if c.configured {
                PSSection {
                    PSRow(icon: "trash", label: t(.failureRemove), danger: true) { confirmRemove = true }
                }
            }
        } footer: {
            PSButton(title: t(.save), icon: "checkmark", loading: busy, disabled: mlUrl.trimmed.isEmpty || serverUrl.trimmed.isEmpty) {
                Task { await save() }
            }
        }
    }

    private func load() async {
        guard let api = app.api else { return }
        do {
            let c = try await api.failureConfig()
            cfg = c
            mlUrl = c.mlUrl ?? ""
            sensitivity = c.sensitivity
            action = c.action
            serverUrl = c.serverUrl ?? app.server?.url ?? ""
        } catch {
            self.error = error.localizedDescription
            cfg = try? JSONDecoder().decode(FailureConfig.self, from: Data(#"{"configured": false}"#.utf8))
            serverUrl = app.server?.url ?? ""
        }
    }

    private func save() async {
        guard let api = app.api else { return }
        busy = true
        error = ""
        done = ""
        defer { busy = false }
        do {
            cfg = try await api.setFailureConfig(mlUrl: mlUrl.trimmed, mlToken: token.trimmed.isEmpty ? nil : token.trimmed,
                                                 serverUrl: serverUrl.trimmed, sensitivity: sensitivity, action: action)
            token = ""
            done = app.l10n(.failureOk)
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() async {
        guard let api = app.api else { return }
        do {
            let r = try await api.removeFailureConfig()
            cfg?.configured = r.configured
            done = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}
