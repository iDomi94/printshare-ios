import SwiftUI

/// Smart plug of one printer through Home Assistant (issue #9, server 0.12.0; "switch on when needed" = `auto_on`,
/// 0.46.0). Own servers only. Until server 0.52.0 this was set up on the classic web page alone. The token is
/// write-only: left empty, the stored one is kept.
struct PowerSettingsView: View {
    let printer: String
    let name: String

    @Environment(AppModel.self) private var app
    @State private var cfg: PowerConfig?
    @State private var url = ""
    @State private var token = ""
    @State private var entity = ""
    @State private var autoOn = false
    @State private var entities: [PowerEntity] = []
    @State private var picking = false
    @State private var busy: Busy?
    @State private var error = ""
    @State private var done = ""
    @State private var confirmRemove = false

    private enum Busy { case load, test, save }

    var body: some View {
        let t = app.l10n
        Group {
            if let cfg { content(t, cfg) } else if !error.isEmpty {
                PSScreen { PSBanner(kind: .error, text: error) } footer: { EmptyView() }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            }
        }
        .navigationTitle("\(t(.plugTitle)) · \(name)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $picking) {
            PickerSheet(title: t(.plugChoose),
                        choices: entities.map { e in
                            Choice(value: e.entity, label: e.name,
                                   group: e.entity.split(separator: ".").first.map(String.init),
                                   sub: [e.entity, e.state.map { t.powerState($0) }].compactMap { $0 }.joined(separator: " · "))
                        },
                        selected: entity.isEmpty ? nil : entity, searchLabel: t(.search), closeLabel: "OK") { entity = $0 }
        }
        .alert(t(.plugRemoveQ, ["printer": name]), isPresented: $confirmRemove) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.del), role: .destructive) { Task { await remove() } }
        }
    }

    /// Through the Home Assistant add-on the supervisor is used when the address stays empty.
    private func supervisor(_ c: PowerConfig) -> Bool { c.addon && url.trimmed.isEmpty }

    private func content(_ t: L10n, _ c: PowerConfig) -> some View {
        let reachable = supervisor(c) || !url.trimmed.isEmpty
        return PSScreen {
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if !done.isEmpty { PSBanner(kind: .ok, text: done) }
            if c.addon { PSBanner(kind: .info, text: t(.plugAddon)) }
            PSSection(title: t(.plugTitle), footer: t(.plugHint)) {
                TextField(c.addon ? "\(t(.plugUrl)) (Add-on)" : "http://homeassistant.local:8123", text: $url)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .padding(.horizontal, Theme.space).padding(.vertical, 14)
                    .accessibilityLabel(t(.plugUrl))
                PSDivider()
                SecureField(c.tokenSet ? t(.plugTokenKept) : t(.plugToken), text: $token)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(.horizontal, Theme.space).padding(.vertical, 14)
                    .accessibilityLabel(t(.plugToken))
                PSDivider()
                TextField("\(t(.plugEntity)): switch.drucker", text: $entity)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .padding(.horizontal, Theme.space).padding(.vertical, 14)
                    .accessibilityLabel(t(.plugEntity))
                if let e = entities.first(where: { $0.entity == entity }) {
                    PSRow(icon: "bolt", label: e.name, sub: e.entity, chevron: false)
                }
                PSDivider()
                PSRow(icon: "list.bullet", label: entities.isEmpty ? t(.plugLoad) : t(.plugChoose),
                      action: busy == nil ? { if entities.isEmpty { Task { await loadEntities() } } else { picking = true } } : nil) {
                    if busy == .load { ProgressView() }
                }
            }
            PSSection(footer: t(.plugAutoOnHint)) {
                Toggle(isOn: $autoOn) {
                    Label {
                        Text(t(.plugAutoOn)).font(.body).foregroundStyle(Theme.text)
                    } icon: {
                        Image(systemName: "power").foregroundStyle(Theme.accent)
                    }
                }
                .tint(Theme.accent)
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
            PSButton(title: t(.plugTest), kind: .secondary, icon: "waveform.path.ecg", loading: busy == .test,
                     disabled: entity.trimmed.isEmpty || (!reachable && !c.tokenSet) || busy != nil) {
                Task { await test() }
            }
            .padding(.bottom, 22)
            if c.configured {
                PSSection {
                    PSRow(icon: "trash", label: t(.plugRemove), danger: true) { confirmRemove = true }
                }
            }
        } footer: {
            PSButton(title: t(.save), icon: "checkmark", loading: busy == .save,
                     disabled: entity.trimmed.isEmpty || !reachable || busy != nil) { Task { await save() } }
        }
    }

    private var settings: PowerSettingsBody {
        PowerSettingsBody(url: url.trimmed, entity: entity.trimmed, token: token.trimmed.isEmpty ? nil : token.trimmed,
                          autoOn: autoOn)
    }

    private func load() async {
        guard let api = app.api else { return }
        do {
            let c = try await api.powerConfig(printer: printer)
            cfg = c
            url = c.url
            entity = c.entity
            autoOn = c.autoOn
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func run(_ kind: Busy, _ work: (APIClient) async throws -> Void) async {
        guard let api = app.api else { return }
        busy = kind
        error = ""
        done = ""
        defer { busy = nil }
        do { try await work(api) } catch { self.error = error.localizedDescription }
    }

    private func loadEntities() async {
        await run(.load) { api in
            let list = try await api.powerEntities(printer: printer, settings)
            entities = list
            done = app.l10n(.plugLoaded, ["n": String(list.count)])
            if !list.isEmpty { picking = true }
        }
    }

    private func test() async {
        await run(.test) { api in
            let r = try await api.testPower(printer: printer, settings)
            if r.ok {
                done = app.l10n(.plugOk, ["name": r.name ?? entity, "state": r.state.map { app.l10n.powerState($0) } ?? ""])
            } else {
                error = r.error ?? ""
            }
        }
    }

    private func save() async {
        await run(.save) { api in
            cfg = try await api.setPowerConfig(printer: printer, settings)
            token = ""
            done = app.l10n(.plugSaved)
            Haptics.success()
        }
    }

    private func remove() async {
        await run(.save) { api in
            let c = try await api.deletePowerConfig(printer: printer)
            cfg = c
            entity = ""
            autoOn = false
        }
    }
}
