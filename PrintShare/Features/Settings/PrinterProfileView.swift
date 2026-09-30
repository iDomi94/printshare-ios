import SwiftUI
import UniformTypeIdentifiers

/// Printer settings: own OrcaSlicer printer profile (issue #2, spec PR-01/02, server 0.7.0).
struct PrinterProfileView: View {
    let printer: String
    let name: String

    @Environment(AppModel.self) private var app
    @State private var current: PrinterProfile?
    @State private var profiles: [UserProfile] = []
    @State private var busy = false
    @State private var error = ""
    @State private var done = ""
    @State private var importing = false
    @State private var deleteTarget: UserProfile?

    var body: some View {
        let t = app.l10n
        PSScreen {
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if !done.isEmpty { PSBanner(kind: .ok, text: done) }

            PSSection(title: t(.printerProfile), footer: t(.profileHelp)) {
                if let current {
                    PSRow(icon: "cube", label: t(.useStandardProfile), sub: standardSub(t, current), chevron: false,
                          action: choose(nil, enabled: current.machineFile != nil),
                          right: { if current.machineFile == nil { check } })
                    ForEach(profiles) { p in
                        PSDivider()
                        PSRow(icon: "doc.text", label: p.name ?? p.file, sub: describe(t, p), chevron: false,
                              action: choose(p.file, enabled: current.machineFile != p.file),
                              right: { if current.machineFile == p.file { check } })
                            .contextMenu {
                                Button(t(.del), systemImage: "trash", role: .destructive) { deleteTarget = p }
                            }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(16)
                }
            }

            PSButton(title: t(.uploadProfile), icon: "icloud.and.arrow.up", loading: busy, disabled: current == nil) {
                importing = true
            }
            if !profiles.isEmpty {
                Text(t(.longPressDelete)).font(.caption).foregroundStyle(Theme.sub)
                    .frame(maxWidth: .infinity).padding(.top, 10)
            }
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .zip, .data]) { result in
            if case .success(let url) = result { Task { await upload(url) } }
        }
        .alert(t(.deleteProfileQ, ["name": deleteTarget?.name ?? deleteTarget?.file ?? ""]),
               isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
               presenting: deleteTarget) { p in
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.del), role: .destructive) { Task { await remove(p) } }
        }
    }

    /// Tap action of a profile row: nil for the profile in use (and while something is running).
    private func choose(_ file: String?, enabled: Bool) -> (() -> Void)? {
        guard enabled && !busy else { return nil }
        return { Task { await use(file) } }
    }

    private var check: some View {
        Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Theme.accent)
            .accessibilityLabel(app.l10n(.profileInUse))
    }

    private func standardSub(_ t: L10n, _ c: PrinterProfile) -> String {
        [t(.standardProfileSub, ["name": c.machine]),
         c.machinePreset == "cosmos" && c.machineFile == nil ? t(.builtInCosmos) : nil,
         c.configFile.map { t(.configFile, ["name": $0]) }].compactMap { $0 }.joined(separator: " · ")
    }

    private func describe(_ t: L10n, _ p: UserProfile) -> String? {
        let parts = [p.inherits.map { t(.basedOn, ["name": $0]) }, p.printStart ? t(.ownStartCode) : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func load() async {
        guard let api = app.api else { return }
        do {
            current = try await api.printerProfile(printer: printer)
            profiles = try await api.profiles().filter { $0.kind == "machine" }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func use(_ file: String?) async {
        guard let api = app.api else { return }
        busy = true
        error = ""
        done = ""
        defer { busy = false }
        do { current = try await api.setPrinterProfile(printer: printer, machineFile: file) }
        catch { self.error = error.localizedDescription }
    }

    private func upload(_ url: URL) async {
        guard let api = app.api else { return }
        busy = true
        error = ""
        done = ""
        defer { busy = false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let stored = try await api.uploadProfile(fileURL: url, name: url.lastPathComponent)
            if let machine = stored.first(where: { $0.kind == "machine" }) {
                // the usual case: one printer preset -> use it for this printer right away (issue #2)
                current = try await api.setPrinterProfile(printer: printer, machineFile: machine.file)
                done = app.l10n(.profileUploaded, ["name": machine.name ?? machine.file, "printer": name])
                Haptics.success()
            }
            profiles = try await api.profiles().filter { $0.kind == "machine" }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(_ p: UserProfile) async {
        guard let api = app.api else { return }
        do {
            try await api.deleteProfile(file: p.file)
            profiles.removeAll { $0.file == p.file }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
