import SwiftUI
import UIKit

/// "Open in PocketPrint3D" from a CAD program (SolidCraft, server 0.48.0): the CAD program uploads the part with this
/// key and opens the prepare page in the browser. Own servers use their access token, the cloud one key per account.
/// Same layout as the Expo app's `import-key.tsx`.
struct ImportKeyView: View {
    @Environment(AppModel.self) private var app
    @State private var state: ImportKey?
    @State private var key: String?
    @State private var busy = false
    @State private var error = ""
    @State private var copied = ""
    @State private var confirmRenew = false
    @State private var confirmOff = false

    var body: some View {
        let t = app.l10n
        let own = state?.serverToken == true
        PSScreen {
            Text(t(.importIntro)).font(.subheadline).foregroundStyle(Theme.sub).padding(.bottom, 16)
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if state == nil && error.isEmpty { ProgressView().frame(maxWidth: .infinity) }

            if let state, key != nil || (state.enabled && !own) {
                PSSection(title: t(.importAccess), footer: key != nil && !own ? t(.orcaKeyOnce) : nil) {
                    PSRow(icon: "link", label: t(.importUrl), value: copied == "url" ? t(.copied) : nil) { copy("url", state.url) }
                    mono(state.url)
                    PSDivider()
                    if let key {
                        PSRow(icon: "key", label: t(.orcaKey), value: copied == "key" ? t(.copied) : nil,
                              action: key.isEmpty ? nil : { copy("key", key) })
                        mono(key.isEmpty ? t(.importNoKey) : key)
                    } else {
                        let used = state.lastUsed.map { t(.orcaLastUsed, ["v": Format.ago(t, $0)]) } ?? t(.orcaNeverUsed)
                        PSRow(icon: "key", label: t(.orcaKey), sub: "\(t(.orcaKeySet)) · \(used)")
                    }
                }
            }

            if let state {
                PSSection(title: t(.importSteps)) {
                    Text(t(.importHowTo)).font(.body).foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.space)
                }
                VStack(spacing: 10) {
                    if own {
                        if key == nil {
                            PSButton(title: t(.importShowToken), icon: "key", loading: busy) { Task { await create() } }
                        }
                    } else {
                        PSButton(title: t(state.enabled ? .orcaRenew : .orcaCreate), kind: state.enabled ? .secondary : .primary,
                                 icon: "key", loading: busy) {
                            if state.enabled { confirmRenew = true } else { Task { await create() } }
                        }
                        if state.enabled {
                            PSButton(title: t(.orcaOff), kind: .danger, icon: "xmark.circle") { confirmOff = true }
                        }
                    }
                }
            }
        }
        .navigationTitle(t(.importTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert(t(.orcaRenewQ), isPresented: $confirmRenew) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.orcaRenew)) { Task { await create() } }
        }
        .alert(t(.importOffQ), isPresented: $confirmOff) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.orcaOff), role: .destructive) { Task { await remove() } }
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(.system(.subheadline, design: .monospaced)).foregroundStyle(Theme.text).textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.space).padding(.bottom, Theme.space)
    }

    private func copy(_ what: String, _ value: String) {
        UIPasteboard.general.string = value
        copied = what
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == what { copied = "" }
        }
    }

    private func load() async {
        guard let api = app.api else { return }
        do { state = try await api.importKey() } catch { self.error = errorText(app.l10n, error) }
    }

    private func create() async {
        guard let api = app.api else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            let r = try await api.createImportKey()
            key = r.key ?? ""
            var s = r
            s.key = nil
            s.created = s.created ?? Date().timeIntervalSince1970
            state = s
        } catch {
            self.error = errorText(app.l10n, error)
        }
    }

    private func remove() async {
        guard let api = app.api else { return }
        do {
            try await api.deleteImportKey()
            key = nil
            await load()
        } catch {
            self.error = errorText(app.l10n, error)
        }
    }
}
