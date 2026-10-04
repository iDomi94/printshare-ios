import SwiftUI

/// Cloud (server 0.15.0/0.15.3): a printer of the account - name, type, OrcaSlicer model, COSMOS - and how the app
/// reaches it on the home Wi-Fi (address, PrusaLink password, API key). That part is stored only on this phone; the
/// app talks to the printer itself (docs/CLOUD.md).
///
/// Behind a bridge at home (server 0.26.0, upstream docs/BRIDGE.md; `bridge` = add one through it, or an existing
/// printer that has one): the bridge searches its own network, and address / password / key are sealed for the bridge
/// (`Seal`) - the cloud passes them on without being able to read them, and this phone does not keep them.
struct CloudPrinterView: View {
    static let new = "new"

    let id: String
    /// New printer through this bridge (id); an existing bridge printer is recognised from the printer itself.
    var bridge: String?

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
    /// Own camera (RTSP / HTTP webcam) instead of the built-in one - bridge printers only, sealed like a password.
    @State private var cameraUrl = ""
    @State private var cameraMsg = ""
    @State private var machines: [Machine]?
    @State private var sheet: Sheet?
    @State private var busy = false
    @State private var error = ""
    @State private var test: (ok: Bool, text: String)?
    @State private var testing = false
    @State private var confirmDelete = false
    @State private var viaBridge: String?
    @State private var bridgeInfo: Bridge?
    @State private var found: [BridgeFound]?
    @State private var picked: String?
    /// The name filled in by the last pick, so a second pick may replace it but a typed name stays.
    @State private var pickedName = ""

    private var isNew: Bool { id == Self.new }
    /// PrusaLink / OctoPrint printers are sliced with the chosen model; there is no default for them.
    /// Bambu Lab too: the model comes from the serial number when the bridge found the printer.
    private var needsModel: Bool { type == "prusalink" || type == "octoprint" || type == "bambu_lan" }
    private var showsModel: Bool { needsModel || (type == "moonraker" && !cosmos) }
    private var missingModel: Bool { needsModel && machine == nil }
    private var missingCreds: Bool {
        (type == "prusalink" && password.isEmpty && apiKey.isEmpty) || (type == "octoprint" && apiKey.isEmpty)
            || (type == "bambu_lan" && password.isEmpty)
    }
    private var cameraText: String { cameraUrl.trimmingCharacters(in: .whitespaces) }
    /// rtsp(s):// or http(s):// with a host.
    private var badCamera: Bool { !cameraText.isEmpty && !cameraText.matches("^(rtsps?|https?)://[^\\s/]+", options: .caseInsensitive) }
    private var isBridge: Bool { viaBridge != nil }
    /// A new printer behind a bridge needs the same credentials the Wi-Fi test would.
    private var missingAddress: Bool { isBridge && isNew && address.trimmingCharacters(in: .whitespaces).isEmpty }
    private var secrets: Seal.Secrets {
        let a = address.trimmingCharacters(in: .whitespaces), k = apiKey.trimmingCharacters(in: .whitespaces)
        let usesPassword = type == "prusalink" || type == "bambu_lan"
        return Seal.Secrets(address: a.isEmpty ? nil : a, password: usesPassword && !password.isEmpty ? password : nil,
                            apiKey: type != "elegoo_sdcp" && type != "bambu_lan" && !k.isEmpty ? k : nil,
                            cameraUrl: cameraText.isEmpty ? nil : cameraText)
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
            if isBridge {
                PSBanner(kind: .info, text: t(isNew ? .bridgeAddHint : .bridgePrinterHint, ["bridge": bridgeInfo?.name ?? "…"]))
            }
            if isNew, bridge != nil { foundSection(t) }

            PSSection(title: t(.printerName)) {
                TextField("Centauri Carbon", text: Binding(get: { name }, set: { name = String($0.prefix(60)) }))
                    .padding(.horizontal, Theme.space).padding(.vertical, 14)
                    .accessibilityLabel(t(.printerName))
            }

            PSSection(title: t(.printerType), footer: t.printerTypeHint(type)) {
                PSRow(icon: "printer", label: t(.printerType), value: t.printerTypeName(type),
                      action: isBridge && !isNew ? nil : { sheet = .type })
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

            PSSection(title: t(.lanAddress), footer: t(!isBridge ? .lanAddressHint : isNew ? .bridgeAddressHint : .bridgeAccessHint)) {
                TextField(type == "octoprint" ? "octopi.local" : "192.168.1.50", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .padding(.horizontal, Theme.space).padding(.vertical, 14)
                    .accessibilityLabel(t(.lanAddress))
                if type == "prusalink" {
                    PSDivider()
                    secret(t(.prusaPassword), $password)
                }
                if type == "bambu_lan" {
                    PSDivider()
                    secret(t(.bambuCode), $password)
                }
                if type != "elegoo_sdcp" && type != "bambu_lan" {
                    PSDivider()
                    secret(type == "octoprint" ? t(.octoApiKey) : t(.apiKeyOptional), $apiKey)
                }
                if !isBridge {
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
            }
            .onChange(of: access) { _, _ in test = nil }
            if type == "prusalink" || type == "octoprint" || type == "bambu_lan" {
                Text(t(type == "prusalink" ? .prusaHint : type == "octoprint" ? .octoHint : .bambuHint))
                    .font(.footnote).foregroundStyle(Theme.sub)
                    .padding(.horizontal, 16).padding(.top, -12).padding(.bottom, 20)
            }

            if isBridge {
                PSSection(title: t(.ownCamera),
                          footer: badCamera ? t(.ownCameraBad) : cameraMsg.isEmpty ? t(isNew ? .ownCameraHint : .ownCameraEditHint) : cameraMsg) {
                    TextField("rtsp://benutzer:passwort@192.168.1.60:554/stream1", text: Binding(get: { cameraUrl }, set: { cameraUrl = $0; cameraMsg = "" }))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .padding(.horizontal, Theme.space).padding(.vertical, 14)
                        .accessibilityLabel(t(.ownCamera))
                    if !isNew {
                        PSDivider()
                        PSRow(icon: "xmark.circle", label: t(.ownCameraRemove)) { Task { await removeCamera() } }
                    }
                }
            }

            if !isNew {
                PSSection {
                    if app.isCloud {
                        PSRow(icon: "desktopcomputer", label: t(.orcaRow)) { app.push(.orcaUpload(id: id, name: name)) }
                        PSDivider()
                    }
                    PSRow(icon: "doc.text", label: t(.printerProfile)) {
                        app.push(.printerProfile(id: id, name: name))
                    }
                    PSDivider()
                    PSRow(icon: "trash", label: t(.deletePrinter), danger: true) { confirmDelete = true }
                }
            }
        } footer: {
            PSButton(title: t(.save), icon: "checkmark", loading: busy,
                     disabled: name.trimmingCharacters(in: .whitespaces).isEmpty || missingModel || missingAddress || badCamera
                         || (isBridge && isNew && missingCreds)) { Task { await save() } }
        }
    }

    /// Printers the bridge found at home (server 0.26.0): tap one to fill in type, address and name.
    @ViewBuilder
    private func foundSection(_ t: L10n) -> some View {
        PSSection(title: t(.bridgeFindTitle), footer: found?.isEmpty == false ? t(.discoverHint) : nil) {
            ForEach(Array((found ?? []).enumerated()), id: \.element.id) { i, f in
                if i > 0 { PSDivider() }
                PSRow(icon: picked == f.id ? "checkmark.circle.fill" : "printer", label: f.name,
                      sub: [t.printerTypeName(f.type), f.address, f.added ? t(.discoverAdded) : nil]
                          .compactMap { $0 }.joined(separator: " · ")) { pick(f) }
            }
            if found == nil {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(t(.bridgeSearching)).font(.subheadline).foregroundStyle(Theme.sub)
                }
                .padding(Theme.space)
            } else {
                if found?.isEmpty == true {
                    Text(t(.bridgeNone)).font(.subheadline).foregroundStyle(Theme.sub).padding(Theme.space)
                    PSDivider()
                }
                if found?.isEmpty == false { PSDivider() }
                PSRow(icon: "arrow.clockwise", label: t(.discoverAgain)) { Task { await discover() } }
            }
        }
    }

    private func pick(_ f: BridgeFound) {
        guard Lan.bridgeTypes.contains(f.type) else { return }
        picked = f.id
        type = f.type
        cosmos = f.cosmos
        address = f.address
        if let m = f.machine { machine = m }   // Bambu: the model comes from the serial number
        password = ""
        apiKey = ""
        if name.trimmingCharacters(in: .whitespaces).isEmpty || name == pickedName { name = String(f.name.prefix(60)) }
        pickedName = name
    }

    /// The bridge scans its own network - one request, no progress.
    private func discover() async {
        guard let api = app.api, let bridge else { return }
        found = nil
        do {
            // the phone's Wi-Fi goes along as a hint: a bridge in Docker's bridge network can't see it itself (server 0.35.1)
            found = try await api.bridgeDiscover(id: bridge, subnet: WifiSubnet.current())
        } catch {
            found = []
            self.error = error.localizedDescription
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
                        choices: (isBridge ? Lan.bridgeTypes : Lan.types).map { Choice(value: $0, label: t.printerTypeName($0), sub: t.printerTypeHint($0)) },
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
        viaBridge = bridge
        if let api = app.api, let bridge {
            bridgeInfo = (try? await api.bridges())?.first { $0.id == bridge }
            Task { await discover() }
        }
        guard !isNew, let api = app.api else { return }
        do {
            if let p = try await api.printers().first(where: { $0.id == id }) {
                viaBridge = p.bridge
                if let b = p.bridge, bridgeInfo?.id != b { bridgeInfo = (try? await api.bridges())?.first { $0.id == b } }
                name = p.name
                type = Lan.bridgeTypes.contains(p.type) ? p.type : "elegoo_sdcp"
                cosmos = p.cosmos
                machine = p.machine.isEmpty ? nil : p.machine
            }
        } catch {
            self.error = error.localizedDescription
        }
        // behind a bridge the address stays on the bridge: nothing to show or keep here
        let stored = isBridge ? nil : app.lanAccess()[id]
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
            if let via = viaBridge {
                // address and secrets go sealed to the bridge; the cloud and this phone don't keep them
                func sealed() throws -> String {
                    guard let key = bridgeInfo?.publicKey else { throw Seal.Failure(message: app.l10n(.errBridgeKey)) }
                    return try Seal.seal(publicKey: key, secrets: secrets)
                }
                if isNew {
                    _ = try await api.bridgeAddPrinter(bridge: via, settings, sealed: try sealed())
                } else {
                    _ = try await api.updatePrinter(id: id, settings)
                    if secrets != Seal.Secrets() { try await api.bridgePrinterAccess(printer: id, sealed: try sealed()) }
                }
                dismiss()
                return
            }
            let p: Printer
            if isNew { p = try await api.addPrinter(settings) } else { p = try await api.updatePrinter(id: id, settings) }
            app.saveLanAccess(p.id, access)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func removeCamera() async {
        guard let api = app.api, isBridge else { return }
        do {
            guard let key = bridgeInfo?.publicKey else { throw Seal.Failure(message: app.l10n(.errBridgeKey)) }
            try await api.bridgePrinterAccess(printer: id, sealed: try Seal.seal(publicKey: key, secrets: Seal.Secrets(cameraUrl: "")))
            cameraUrl = ""
            cameraMsg = app.l10n(.ownCameraRemoved)
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
