import SwiftUI
import UIKit

/// Cloud (server 0.30, docs/WEB.md step 3): send from OrcaSlicer on the computer. OrcaSlicer's physical printer
/// "Octo/Klipper" uploads to PocketPrint3D with this printer's key: the G-code becomes a job here and its spool is
/// booked. The key is shown once, right after it was made.
struct OrcaUploadView: View {
    let printer: String
    let name: String

    @Environment(AppModel.self) private var app
    @State private var state: OrcaUpload?
    @State private var key: String?
    @State private var busy = false
    @State private var error = ""
    @State private var copied = ""
    @State private var confirmRenew = false
    @State private var confirmOff = false

    var body: some View {
        let t = app.l10n
        PSScreen {
            Text(t(.orcaIntro, ["printer": name])).font(.subheadline).foregroundStyle(Theme.sub).padding(.bottom, 16)
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if state == nil && error.isEmpty { ProgressView().frame(maxWidth: .infinity) }

            PSSection(title: t(.orcaWhyTitle), footer: t(.orcaWhyNot)) {
                Text(t(.orcaWhy)).font(.body).foregroundStyle(Theme.text)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.space)
            }

            if let state, key != nil || state.enabled {
                PSSection(title: t(.orcaAccess), footer: key != nil ? t(.orcaKeyOnce) : nil) {
                    PSRow(icon: "link", label: t(.orcaUrl), value: copied == "url" ? t(.copied) : nil) { copy("url", state.url) }
                    mono(state.url)
                    PSDivider()
                    if let key {
                        PSRow(icon: "key", label: t(.orcaKey), value: copied == "key" ? t(.copied) : nil) { copy("key", key) }
                        mono(key)
                    } else {
                        let used = state.lastUsed.map { t(.orcaLastUsed, ["v": Format.ago(t, $0)]) } ?? t(.orcaNeverUsed)
                        PSRow(icon: "key", label: t(.orcaKey), sub: "\(t(.orcaKeySet)) · \(used)")
                    }
                }
            }

            if let state {
                PSSection(title: t(.orcaSteps)) {
                    Text(t(.orcaHowTo)).font(.body).foregroundStyle(Theme.text)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.space)
                }
                Text(t(.orcaPrintNote)).font(.footnote).foregroundStyle(Theme.sub)
                    .padding(.horizontal, 16).padding(.top, -8).padding(.bottom, 20)
                VStack(spacing: 10) {
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
        .navigationTitle(t(.orcaTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .alert(t(.orcaRenewQ), isPresented: $confirmRenew) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.orcaRenew)) { Task { await create() } }
        }
        .alert(t(.orcaOffQ), isPresented: $confirmOff) {
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
        do { state = try await api.orcaUpload(printer: printer) } catch { self.error = errorText(app.l10n, error) }
    }

    private func create() async {
        guard let api = app.api else { return }
        busy = true
        error = ""
        defer { busy = false }
        do {
            let r = try await api.createOrcaUpload(printer: printer)
            key = r.key
            state = OrcaUpload(enabled: true, url: r.url, created: Date().timeIntervalSince1970)
        } catch {
            self.error = errorText(app.l10n, error)
        }
    }

    private func remove() async {
        guard let api = app.api else { return }
        do {
            try await api.deleteOrcaUpload(printer: printer)
            key = nil
            await load()
        } catch {
            self.error = errorText(app.l10n, error)
        }
    }
}
