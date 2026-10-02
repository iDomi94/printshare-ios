import SwiftUI

/// Own Manyfold library (server 0.21.0, own servers only): address + API key; the server checks both before saving.
/// Its models then show up as a search source in "Entdecken".
struct ManyfoldView: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var state: ManyfoldConfig?
    @State private var url = ""
    @State private var key = ""
    @State private var busy = false
    @State private var error = ""
    @State private var done = ""
    @State private var confirmRemove = false

    var body: some View {
        let t = app.l10n
        Group {
            if let state { content(t, state) } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            }
        }
        .navigationTitle("Manyfold")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert(t(.manyfoldRemoveQ), isPresented: $confirmRemove) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.del), role: .destructive) { Task { await remove() } }
        }
    }

    private func content(_ t: L10n, _ s: ManyfoldConfig) -> some View {
        let canSave = !url.trimmed.isEmpty && (!key.trimmed.isEmpty || s.tokenSet)
        return PSScreen {
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if !done.isEmpty { PSBanner(kind: .ok, text: done) }
            PSSection(title: t(.manyfoldAddress), footer: t(.manyfoldHint)) {
                TextField("http://192.168.1.20:3214", text: $url)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .padding(.horizontal, Theme.space).padding(.vertical, 14)
                    .accessibilityLabel(t(.manyfoldAddress))
                PSDivider()
                SecureField(s.tokenSet ? t(.manyfoldKeyKept) : t(.manyfoldKey), text: $key)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(.horizontal, Theme.space).padding(.vertical, 14)
                    .accessibilityLabel(t(.manyfoldKey))
            }
            if s.configured {
                PSSection {
                    PSRow(icon: "trash", label: t(.manyfoldRemove), danger: true) { confirmRemove = true }
                }
            }
            Button("manyfold.app") { if let u = URL(string: "https://manyfold.app") { openURL(u) } }
                .font(.subheadline).foregroundStyle(Theme.accent).padding(.leading, Theme.space)
        } footer: {
            PSButton(title: t(.save), icon: "checkmark", loading: busy, disabled: !canSave) { Task { await save() } }
        }
    }

    private func load() async {
        guard let api = app.api else { return }
        do {
            let s = try await api.manyfoldConfig()
            state = s
            url = s.url ?? ""
        } catch {
            self.error = error.localizedDescription
            state = ManyfoldConfig(configured: false)
        }
    }

    private func save() async {
        guard let api = app.api else { return }
        busy = true
        error = ""
        done = ""
        defer { busy = false }
        do {
            let r = try await api.setManyfold(url: url.trimmed, token: key.trimmed.isEmpty ? nil : key.trimmed)
            state = ManyfoldConfig(configured: true, url: r.url, tokenSet: true)
            key = ""
            done = app.l10n(.manyfoldOk, ["n": String(r.models ?? 0)])
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() async {
        guard let api = app.api else { return }
        do {
            let r = try await api.removeManyfold()
            state = ManyfoldConfig(configured: r.configured, url: state?.url, tokenSet: false)
            done = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension String {
    /// Without leading / trailing spaces and line breaks.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
