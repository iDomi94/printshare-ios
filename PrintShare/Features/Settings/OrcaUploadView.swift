import SwiftUI
import UIKit

/// Cloud: send from OrcaSlicer on the computer (server 0.31.0). OrcaSlicer's physical printer "Octo/Klipper" uploads to
/// PocketPrint3D with this printer's key: the G-code becomes a job here and its spool is booked.
struct OrcaUploadView: View {
    let printer: String
    let name: String

    @Environment(AppModel.self) private var app
    @State private var state: OrcaUpload?
    /// The key is only known right after it was created; afterwards the server keeps just a hash.
    @State private var key: String?
    @State private var busy = false
    @State private var error = ""
    @State private var copied = ""
    @State private var confirmRenew = false
    @State private var confirmOff = false

    var body: some View {
        let t = app.l10n
        PSScreen {
            Text(t(.orcaIntro, ["printer": name.isEmpty ? printer : name])).font(.subheadline).foregroundStyle(Theme.sub)
                .padding(.bottom, 16)
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if state == nil && error.isEmpty { ProgressView().frame(maxWidth: .infinity) }

            PSSection(title: t(.orcaWhyTitle), footer: t(.orcaWhyNot)) {
                Text(t(.orcaWhy)).font(.subheadline).foregroundStyle(Theme.text).padding(Theme.space)
            }

            if let state, key != nil || state.enabled {
                PSSection(title: t(.orcaAccess), footer: key != nil ? t(.orcaKeyOnce) : nil) {
                    PSRow(icon: "link", label: t(.orcaUrl), value: copied == "url" ? t(.copied) : nil, chevron: false) {
                        copy("url", state.url)
                    }
                    mono(state.url)
                    PSDivider()
                    if let key {
                        PSRow(icon: "key", label: t(.orcaKey), value: copied == "key" ? t(.copied) : nil, chevron: false) {
                            copy("key", key)
                        }
                        mono(key)
                    } else {
                        PSRow(icon: "key", label: t(.orcaKey),
                              sub: [t(.orcaKeySet), state.lastUsed.map { t(.orcaLastUsed, ["v": Format.ago(t, $0)]) }
                                    ?? t(.orcaNeverUsed)].joined(separator: " · "))
                    }
                }
            }

            if state != nil {
                PSSection(title: t(.orcaSteps)) {
                    Text(t(.orcaHowTo)).font(.subheadline).foregroundStyle(Theme.text).padding(Theme.space)
                }
                Text(t(.orcaPrintNote)).font(.footnote).foregroundStyle(Theme.sub).padding(.horizontal, Theme.space)
                    .padding(.bottom, 20)
            }
        } footer: {
            if let state {
                PSButton(title: t(state.enabled ? .orcaRenew : .orcaCreate), kind: state.enabled ? .secondary : .primary,
                         icon: "key", loading: busy) {
                    if state.enabled { confirmRenew = true } else { Task { await create() } }
                }
                if state.enabled {
                    PSButton(title: t(.orcaOff), kind: .danger, icon: "xmark.circle") { confirmOff = true }
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
            Button(t(.orcaOff), role: .destructive) { Task { await turnOff() } }
        }
    }

    private func mono(_ text: String) -> some View {
        Text(text).font(.system(.subheadline, design: .monospaced)).foregroundStyle(Theme.text).textSelection(.enabled)
            .padding(.horizontal, Theme.space).padding(.bottom, 12)
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
        do { state = try await api.orcaUpload(printer: printer) } catch { self.error = error.localizedDescription }
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
            Haptics.success()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func turnOff() async {
        guard let api = app.api else { return }
        do {
            try await api.deleteOrcaUpload(printer: printer)
            key = nil
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
