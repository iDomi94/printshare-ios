import SwiftUI

/// Cloud (server 0.15.0/0.15.3): a printer of the account - name, type, OrcaSlicer model, COSMOS - and how the app
/// reaches it on the home Wi-Fi (address, PrusaLink password, API key). That part is stored only on this phone; the
/// app talks to the printer itself (docs/CLOUD.md).
struct CloudPrinterView: View {
    static let new = "new"

    let id: String

    private enum Sheet: String, Identifiable { case type, model; var id: String { rawValue } }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    @State private var name = ""
    @State private var type = "elegoo_sdcp"
    @State private var cosmos = false
    @State private var machine: String?
    @State private var address = ""
    @State private var password = ""
    @State private var apiKey = ""
    @State private var machines: [Machine]?
    @State private var sheet: Sheet?
    @State private var busy = false
    @State private var error = ""
    @State private var test: (ok: Bool, text: String)?
    @State private var testing = false
    @State private var confirmDelete = false

    private var isNew: Bool { id == Self.new }
    /// PrusaLink / OctoPrint printers are sliced with the chosen model; there is no default for them.
    private var needsModel: Bool { type == "prusalink" || type == "octoprint" }
    private var showsModel: Bool { needsModel || (type == "moonraker" && !cosmos) }
    private var missingModel: Bool { needsModel && machine == nil }
    private var missingCreds: Bool {
        (type == "prusalink" && password.isEmpty && apiKey.isEmpty) || (type == "octoprint" && apiKey.isEmpty)
    }
    private var access: LanAccess {
        LanAccess(address: address, password: type == "prusalink" ? password : nil,
                  apiKey: type == "elegoo_sdcp" ? nil : apiKey)
    }

    var body: some View {
        let t = app.l10n
        Group {
            if loaded { form(t) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg) }
        }
        .navigationTitle(isNew ? t(.addPrinter) : (name.isEmpty ? t(.printer) : name))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(item: $sheet) { sheetView(t, $0) }
        .alert(t(.deletePrinterQ, ["name": name]), isPresented: $confirmDelete) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.del), role: .destructive) { Task { await remove() } }
        }
    }

    private func form(_ t: L10n) -> some View {
        PSScreen {
            if !error.isEmpty { PSBanner(kind: .error, text: error) }

            PSSection(title: t(.printerName)) {
                TextField("Centauri Carbon", text: Binding(get: { name }, set: { name = String($0.prefix(60)) }))
                    .padding(.horizontal, Theme.space).padding(.vertical, 14)
                    .accessibilityLabel(t(.printerName))
            }

            PSSection(title: t(.printerType), footer: t.printerTypeHint(type)) {
                PSRow(icon: "printer", label: t(.printerType), value: t.printerTypeName(type)) { sheet = .type }
                if showsModel {
                    PSDivider()
                    PSRow(icon: "cube", label: t(.printerModel), value: machine ?? t(.chooseModel),
                          sub: missingModel ? t(.modelNeeded) : nil) { sheet = .model }
                }
                if type == "moonraker" {
                    PSDivider()
                    Toggle(t(.cosmos), isOn: $cosmos).tint(Theme.accent)
                        .padding(.horizontal, Theme.space).padding(.vertical, 10)
                }
            }
            if type == "moonraker" {
                Text(t(.cosmosHint)).font(.footnote).foregroundStyle(Theme.sub)
                    .padding(.horizontal, 16).padding(.top, -12).padding(.bottom, 20)
            }

            PSSection(title: t(.lanAddress), footer: t(.lanAddressHint)) {
                TextField(type == "octoprint" ? "octopi.local" : "192.168.1.50", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .padding(.horizontal, Theme.space).padding(.vertical, 14)
                    .accessibilityLabel(t(.lanAddress))
                if type == "prusalink" {
                    PSDivider()
                    secret(t(.prusaPassword), $password)
                }
                if type != "elegoo_sdcp" {
                    PSDivider()
                    secret(type == "octoprint" ? t(.octoApiKey) : t(.apiKeyOptional), $apiKey)
                }
                PSDivider()
                VStack(alignment: .leading, spacing: 10) {
                    PSButton(title: t(.testConnection), kind: .secondary, icon: "wifi", loading: testing,
                             disabled: address.trimmingCharacters(in: .whitespaces).isEmpty || missingCreds) {
                        Task { await testConnection() }
                    }
                    if let test {
                        Text(test.text).font(.subheadline).foregroundStyle(test.ok ? Theme.ok : Theme.danger)
                    }
                }
                .padding(Theme.space)
            }
            .onChange(of: access) { _, _ in test = nil }
            if type == "prusalink" || type == "octoprint" {
                Text(t(type == "prusalink" ? .prusaHint : .octoHint)).font(.footnote).foregroundStyle(Theme.sub)
                    .padding(.horizontal, 16).padding(.top, -12).padding(.bottom, 20)
            }

            if !isNew {
                PSSection {
                    PSRow(icon: "doc.text", label: t(.printerProfile)) {
                        app.push(.printerProfile(id: id, name: name))
                    }
                    PSDivider()
                    PSRow(icon: "trash", label: t(.deletePrinter), danger: true) { confirmDelete = true }
                }
            }
        } footer: {
            PSButton(title: t(.save), icon: "checkmark", loading: busy,
                     disabled: name.trimmingCharacters(in: .whitespaces).isEmpty || missingModel) { Task { await save() } }
        }
    }

    private func secret(_ label: String, _ text: Binding<String>) -> some View {
        SecureField(label, text: text)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(.horizontal, Theme.space).padding(.vertical, 14)
            .accessibilityLabel(label)
    }

    @ViewBuilder
    private func sheetView(_ t: L10n, _ which: Sheet) -> some View {
        switch which {
        case .type:
            PickerSheet(title: t(.printerType),
                        choices: Lan.types.map { Choice(value: $0, label: t.printerTypeName($0), sub: t.printerTypeHint($0)) },
                        selected: type, searchLabel: t(.search), closeLabel: "OK") { type = $0 }
        case .model:
            if let machines {
                PickerSheet(title: t(.printerModel),
                            choices: machines.map { Choice(value: $0.name, label: $0.name, group: $0.vendor) },
                            selected: machine, searchLabel: t(.search), closeLabel: "OK") { machine = $0 }
            } else {
                ProgressView().controlSize(.large)
                    .task { await loadMachines() }
            }
        }
    }

    private func load() async {
        guard !loaded else { return }
        defer { loaded = true }
        guard !isNew, let api = app.api else { return }
        do {
            if let p = try await api.printers().first(where: { $0.id == id }) {
                name = p.name
                type = Lan.types.contains(p.type) ? p.type : "elegoo_sdcp"
                cosmos = p.cosmos
                machine = p.machine.isEmpty ? nil : p.machine
            }
        } catch {
            self.error = error.localizedDescription
        }
        let stored = app.lanAccess()[id]
        address = stored?.address ?? ""
        password = stored?.password ?? ""
        apiKey = stored?.apiKey ?? ""
    }

    private func loadMachines() async {
        guard let api = app.api else { return }
        do {
            machines = try await api.machines()
        } catch {
            self.error = error.localizedDescription
            sheet = nil
        }
    }

    private func testConnection() async {
        let t = app.l10n
        testing = true
        test = nil
        defer { testing = false }
        do {
            let lan = try Lan.printer(type: type, access: access)
            defer { Task { await lan.close() } }
            let st = try await lan.status()
            let state = st.kind == .unknown ? (st.state ?? "") : t.printerKind(st.kind.rawValue)
            let temp = st.nozzle.map { "\(Int($0.rounded())) °C" } ?? "–"
            test = (true, t(.lanReachable, ["state": state, "temp": temp]))
        } catch {
            test = (false, "\(t(.lanUnreachable)) (\(error.localizedDescription))")
        }
    }

    private func save() async {
        guard let api = app.api else { return }
        busy = true
        error = ""
        defer { busy = false }
        let settings = PrinterSettings(name: name.trimmingCharacters(in: .whitespaces), type: type,
                                       cosmos: type == "moonraker" ? cosmos : false,
                                       machine: needsModel || type == "moonraker" ? machine : nil)
        do {
            let p: Printer
            if isNew { p = try await api.addPrinter(settings) } else { p = try await api.updatePrinter(id: id, settings) }
            app.saveLanAccess(p.id, access)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() async {
        guard let api = app.api else { return }
        do {
            try await api.deletePrinter(id: id)
            app.saveLanAccess(id, nil)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
