import SwiftUI

/// Cloud (server 0.15.0): a printer of the account - name, type, COSMOS - and its address on the home Wi-Fi. The
/// address is stored only on this phone; the app talks to the printer itself (docs/CLOUD.md).
struct CloudPrinterView: View {
    static let new = "new"

    let id: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var loaded = false
    @State private var name = ""
    @State private var type = "elegoo_sdcp"
    @State private var cosmos = false
    @State private var address = ""
    @State private var busy = false
    @State private var error = ""
    @State private var test: (ok: Bool, text: String)?
    @State private var testing = false
    @State private var confirmDelete = false

    private var isNew: Bool { id == Self.new }

    var body: some View {
        let t = app.l10n
        Group {
            if loaded { form(t) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg) }
        }
        .navigationTitle(isNew ? t(.addPrinter) : (name.isEmpty ? t(.printer) : name))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
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

            PSSection(title: t(.printerType), footer: type == "moonraker" ? t(.cosmosHint) : nil) {
                PSSegmented(values: ["elegoo_sdcp", "moonraker"], selection: $type) {
                    $0 == "moonraker" ? t(.typeKlipper) : t(.typeCentauri)
                }
                .padding(12)
                .onChange(of: type) { _, _ in test = nil }
                if type == "moonraker" {
                    PSDivider()
                    Toggle(t(.cosmos), isOn: $cosmos).tint(Theme.accent)
                        .padding(.horizontal, Theme.space).padding(.vertical, 10)
                }
            }

            PSSection(title: t(.lanAddress), footer: t(.lanAddressHint)) {
                TextField("192.168.1.50", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .padding(.horizontal, Theme.space).padding(.vertical, 14)
                    .accessibilityLabel(t(.lanAddress))
                    .onChange(of: address) { _, _ in test = nil }
                PSDivider()
                VStack(alignment: .leading, spacing: 10) {
                    PSButton(title: t(.testConnection), kind: .secondary, icon: "wifi", loading: testing,
                             disabled: address.trimmingCharacters(in: .whitespaces).isEmpty) {
                        Task { await testConnection() }
                    }
                    if let test {
                        Text(test.text).font(.subheadline).foregroundStyle(test.ok ? Theme.ok : Theme.danger)
                    }
                }
                .padding(Theme.space)
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
                     disabled: name.trimmingCharacters(in: .whitespaces).isEmpty) { Task { await save() } }
        }
    }

    private func load() async {
        guard !loaded else { return }
        defer { loaded = true }
        guard !isNew, let api = app.api else { return }
        do {
            if let p = try await api.printers().first(where: { $0.id == id }) {
                name = p.name
                type = p.type == "moonraker" ? "moonraker" : "elegoo_sdcp"
                cosmos = p.cosmos
            }
        } catch {
            self.error = error.localizedDescription
        }
        address = app.lanAddresses()[id] ?? ""
    }

    private func testConnection() async {
        let t = app.l10n
        testing = true
        test = nil
        defer { testing = false }
        do {
            let lan = try Lan.printer(type: type, address: address)
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
                                       cosmos: type == "moonraker" ? cosmos : false)
        do {
            let p: Printer
            if isNew { p = try await api.addPrinter(settings) } else { p = try await api.updatePrinter(id: id, settings) }
            app.saveLanAddress(p.id, address)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove() async {
        guard let api = app.api else { return }
        do {
            try await api.deletePrinter(id: id)
            app.saveLanAddress(id, nil)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
