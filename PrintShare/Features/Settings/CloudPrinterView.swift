import SwiftUI

/// Cloud (server 0.15.0/0.15.3): a printer of the account - name, type, OrcaSlicer model, COSMOS - and how the app
/// reaches it on the home Wi-Fi (address, PrusaLink password, API key). That part is stored only on this phone; the
/// app talks to the printer itself (docs/CLOUD.md).
/// New printers are found on the Wi-Fi first (server 0.25, `Discovery`); the form opens when one is picked or "enter
/// yourself" is tapped. With a bridge (server 0.24, docs/BRIDGE.md; `bridge` or a printer that has one) the bridge
/// searches its home network, and address/password/key are sealed for the bridge - the cloud passes them on without
/// being able to read them, and this phone doesn't keep them.
struct CloudPrinterView: View {
    static let new = "new"

    let id: String
    var bridge: String?

    private enum ScanState: Equatable { case running(pct: Int), done, noWifi }

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
    @State private var found: [FoundPrinter] = []
    @State private var scan: ScanState?
    @State private var scanRun = 0
    @State private var picked: String?
    @State private var manual = false
    @State private var known: [String] = []
    @State private var viaBridge: String?
    @State private var bridgeInfo: (name: String, key: String?)?

    private var isNew: Bool { id == Self.new }
    /// PrusaLink / OctoPrint printers are sliced with the chosen model; there is no default for them. Bambu Lab too:
    /// the model comes from the serial number when the bridge found the printer.
    private var needsModel: Bool { type == "prusalink" || type == "octoprint" || type == "bambu_lan" }
    private var showsModel: Bool { needsModel || (type == "moonraker" && !cosmos) }
    private var missingModel: Bool { needsModel && machine == nil }
    private var missingCreds: Bool {
        (type == "prusalink" && password.isEmpty && apiKey.isEmpty) || (type == "octoprint" && apiKey.isEmpty)
            || (type == "bambu_lan" && password.isEmpty)
    }
    private var cameraText: String { cameraUrl.trimmingCharacters(in: .whitespaces) }
    /// rtsp(s):// or http(s):// with a host.
    private var badCamera: Bool {
        !cameraText.isEmpty && !cameraText.matches(#"^(rtsps?|https?)://[^\s/]+"#, options: .caseInsensitive)
    }
    private var bridgeTypes: [String] { viaBridge != nil || bridge != nil ? Lan.bridgeTypes : Lan.types }
    /// A name is optional: without one the printer is called after its model or type.
    private var autoName: String {
        if let machine, needsModel || type == "moonraker" {
            let short = machine.replacingRegex(#"(?i)\s+[\d.]+\s*nozzle$"#, with: "")
            if !short.isEmpty { return short }
        }
        if type == "moonraker" && cosmos { return "Centauri Carbon" }
        return app.l10n.printerTypeName(type)
    }
    private var access: LanAccess {
        LanAccess(address: address, password: type == "prusalink" || type == "bambu_lan" ? password : nil,
                  apiKey: type == "elegoo_sdcp" || type == "bambu_lan" ? nil : apiKey)
    }

    var body: some View {
        let t = app.l10n
        Group {
            if loaded { form(t) } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg) }
        }
        .navigationTitle(isNew ? t(.addPrinter) : (name.isEmpty ? t(.printer) : name))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .task(id: scanRun) { await runScan() }
        .task(id: viaBridge) { await loadBridge() }
        .sheet(item: $sheet) { sheetView(t, $0) }
        .alert(t(.deletePrinterQ, ["name": name]), isPresented: $confirmDelete) {
            Button(t(.cancelBtn), role: .cancel) {}
            Button(t(.del), role: .destructive) { Task { await remove() } }
        }
    }

    private func form(_ t: L10n) -> some View {
        PSScreen {
            if !error.isEmpty { PSBanner(kind: .error, text: error) }
            if viaBridge != nil {
                PSBanner(kind: .info, text: t(isNew ? .bridgeAddHint : .bridgePrinterHint, ["bridge": bridgeInfo?.name ?? "…"]))
            }

            if isNew { discoverSection(t) }

            if manual || picked != nil {
                PSSection(title: t(.printerType), footer: t.printerTypeHint(type)) {
                    let locked = viaBridge != nil && !isNew
                    PSRow(icon: "printer", label: t.printerTypeName(type), value: locked ? nil : t(.change),
                          action: locked ? nil : { sheet = .type })
                    if type == "moonraker" {
                        PSDivider()
                        Toggle(t(.cosmos), isOn: $cosmos).tint(Theme.accent)
                            .padding(.horizontal, Theme.space).padding(.vertical, 10)
                    }
                    if showsModel {
                        PSDivider()
                        PSRow(icon: "cube", label: t(.printerModel), value: machine ?? t(.chooseModel),
                              sub: missingModel ? t(.modelNeeded) : nil) { sheet = .model }
                    }
                }
                if type == "moonraker" {
                    Text(t(.cosmosHint)).font(.footnote).foregroundStyle(Theme.sub)
                        .padding(.horizontal, 16).padding(.top, -12).padding(.bottom, 20)
                }

                PSSection(title: t(.lanAddress),
                          footer: t(viaBridge == nil ? .lanAddressHint : isNew ? .bridgeAddressHint : .bridgeAccessHint)) {
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
                    if viaBridge == nil {
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

                if viaBridge != nil {
                    PSSection(title: t(.ownCamera),
                              footer: badCamera ? t(.ownCameraBad)
                                  : cameraMsg.isEmpty ? t(isNew ? .ownCameraHint : .ownCameraEditHint) : cameraMsg) {
                        TextField("rtsp://benutzer:passwort@192.168.1.60:554/stream1",
                                  text: Binding(get: { cameraUrl }, set: { cameraUrl = $0; cameraMsg = "" }))
                            .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                            .padding(.horizontal, Theme.space).padding(.vertical, 14)
                            .accessibilityLabel(t(.ownCamera))
                        if !isNew {
                            PSDivider()
                            PSRow(icon: "xmark.circle", label: t(.ownCameraRemove)) { Task { await removeCamera() } }
                        }
                    }
                }

                PSSection(title: t(.printerNameAuto),
                          footer: name.trimmingCharacters(in: .whitespaces).isEmpty ? t(.printerNameAutoHint, ["name": autoName]) : nil) {
                    TextField(autoName, text: Binding(get: { name }, set: { name = String($0.prefix(60)) }))
                        .padding(.horizontal, Theme.space).padding(.vertical, 14)
                        .accessibilityLabel(t(.printerName))
                }
            }

            if !isNew {
                PSSection {
                    PSRow(icon: "desktopcomputer", label: t(.orcaRow)) {
                        app.push(.orcaUpload(id: id, name: name.isEmpty ? autoName : name))
                    }
                    PSDivider()
                    PSRow(icon: "doc.text", label: t(.printerProfile)) {
                        app.push(.printerProfile(id: id, name: name))
                    }
                    PSDivider()
                    PSRow(icon: "trash", label: t(.deletePrinter), danger: true) { confirmDelete = true }
                }
            }
        } footer: {
            PSButton(title: t(.save), icon: "checkmark", loading: busy, disabled: saveDisabled) { Task { await save() } }
        }
    }

    private var saveDisabled: Bool {
        missingModel || badCamera || (isNew && address.trimmingCharacters(in: .whitespaces).isEmpty)
            || (isNew && viaBridge != nil && missingCreds)
    }

    @ViewBuilder
    private func discoverSection(_ t: L10n) -> some View {
        PSSection(title: t(bridge != nil ? .bridgeFindTitle : .lanFindTitle), footer: found.isEmpty ? nil : t(.discoverHint)) {
            ForEach(Array(found.enumerated()), id: \.element.address) { i, f in
                if i > 0 { PSDivider() }
                let added = known.contains(f.address)
                let sub = [t.printerTypeName(f.type), f.address, added ? t(.discoverAdded) : nil].compactMap { $0 }
                    .joined(separator: " · ")
                PSRow(icon: "printer", label: f.name, sub: sub, action: { pick(f) }) {
                    if picked == f.address {
                        Image(systemName: "checkmark.circle.fill").font(.title3).foregroundStyle(Theme.accent)
                    }
                }
            }
            if !found.isEmpty { PSDivider() }
            if case .running(let pct) = scan {
                HStack(spacing: 10) {
                    ProgressView()
                    Text(bridge != nil ? t(.bridgeSearching) : t(.discoverRunning, ["pct": String(pct)]))
                        .font(.subheadline).foregroundStyle(Theme.sub)
                    Spacer()
                }
                .padding(Theme.space)
            } else {
                if scan == .noWifi || (scan == .done && found.isEmpty) {
                    Text(t(scan == .noWifi ? .discoverNoWifi : bridge != nil ? .bridgeNone : .discoverNone))
                        .font(.subheadline).foregroundStyle(Theme.sub)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(Theme.space)
                }
                PSRow(icon: "arrow.clockwise", label: t(.discoverAgain)) { found = []; scanRun += 1 }
            }
            if !manual && picked == nil {
                PSDivider()
                PSRow(icon: "square.and.pencil", label: t(.discoverManual)) { manual = true }
            }
        }
    }

    private func pick(_ f: FoundPrinter) {
        picked = f.address
        type = bridgeTypes.contains(f.type) ? f.type : "elegoo_sdcp"
        address = f.address
        cosmos = f.cosmos
        if let m = f.machine { machine = m }                   // Bambu: the model comes from the serial number
        // Centauri / Klipper report a real name; for Prusa and OctoPrint the model (chosen below) names the printer
        name = f.type == "elegoo_sdcp" || f.type == "moonraker" ? f.name : ""
        test = nil
        error = ""
    }

    /// The bridge searches its own network (one request), else this phone searches the Wi-Fi.
    private func runScan() async {
        guard isNew else { return }
        scan = .running(pct: 0)
        if let bridge {
            guard let api = app.api else { scan = .done; return }
            do {
                // the phone's Wi-Fi goes along as a hint: a bridge in Docker's bridge network can't see it (server 0.35.1)
                let hint = Discovery.wifiAddress().flatMap { Discovery.subnet(address: $0.address, prefix: $0.prefix) }
                let list = try await api.bridgeDiscover(id: bridge, subnet: hint)
                found = list
                known = list.filter(\.added).map(\.address)
            } catch {
                if !Task.isCancelled { self.error = errorText(app.l10n, error) }
            }
            if !Task.isCancelled { scan = .done }
            return
        }
        known = app.lanAccess().values.map { $0.address.replacingRegex("^https?://", with: "") }
        do {
            for try await event in Discovery.printers() {
                switch event {
                case .found(let f): found.append(f)
                case .progress(let done, let total): scan = .running(pct: total > 0 ? done * 100 / total : 100)
                }
            }
            if !Task.isCancelled { scan = .done }
        } catch {
            if !Task.isCancelled { scan = error is Discovery.NoWifi ? .noWifi : .done }
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
                        choices: bridgeTypes.map { Choice(value: $0, label: t.printerTypeName($0), sub: t.printerTypeHint($0)) },
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
        manual = !isNew
        if viaBridge == nil { viaBridge = bridge }
        guard !isNew, let api = app.api else { return }
        do {
            if let p = try await api.printers().first(where: { $0.id == id }) {
                name = p.name
                type = Lan.bridgeTypes.contains(p.type) ? p.type : "elegoo_sdcp"
                cosmos = p.cosmos
                machine = p.machine.isEmpty ? nil : p.machine
                if let b = p.bridge { viaBridge = b }
            }
        } catch {
            self.error = errorText(app.l10n, error)
        }
        if viaBridge != nil { return }                          // a bridge keeps the address, not this phone
        let stored = app.lanAccess()[id]
        address = stored?.address ?? ""
        password = stored?.password ?? ""
        apiKey = stored?.apiKey ?? ""
    }

    /// Name and public key of the bridge this printer sits behind.
    private func loadBridge() async {
        guard let viaBridge, let api = app.api else { return }
        if let b = try? await api.bridges().first(where: { $0.id == viaBridge }) {
            bridgeInfo = (b.name, b.publicKey)
        }
    }

    private func loadMachines() async {
        guard let api = app.api else { return }
        do {
            machines = try await api.machines()
        } catch {
            self.error = errorText(app.l10n, error)
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
            let friendly = errorText(t, error)
            test = (false, friendly != error.localizedDescription ? friendly
                    : "\(t(.lanUnreachable)) (\(error.localizedDescription))")
        }
    }

    private func save() async {
        guard let api = app.api else { return }
        busy = true
        error = ""
        defer { busy = false }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let settings = PrinterSettings(name: trimmed.isEmpty ? autoName : trimmed, type: type,
                                       cosmos: type == "moonraker" ? cosmos : false,
                                       machine: needsModel || type == "moonraker" ? machine : nil)
        do {
            if let viaBridge {
                // address and secrets go sealed to the bridge; the cloud and this phone don't keep them
                let secrets = Self.secrets(access, camera: cameraText)
                func sealed() throws -> String {
                    guard let key = bridgeInfo?.key, !key.isEmpty else { throw LanError(app.l10n(.errBridgeKey)) }
                    do { return try Seal.seal(publicKey: key, secrets) } catch { throw LanError(app.l10n(.errBridgeKey)) }
                }
                if isNew {
                    _ = try await api.bridgeAddPrinter(bridge: viaBridge, settings, sealed: try sealed())
                } else {
                    _ = try await api.updatePrinter(id: id, settings)
                    if !secrets.isEmpty { try await api.bridgePrinterAccess(printer: id, sealed: try sealed()) }
                }
                dismiss()
                return
            }
            let p: Printer
            if isNew { p = try await api.addPrinter(settings) } else { p = try await api.updatePrinter(id: id, settings) }
            app.saveLanAccess(p.id, access)
            dismiss()
        } catch {
            self.error = errorText(app.l10n, error)
        }
    }

    /// What is sealed for the bridge: only the fields that are filled in.
    static func secrets(_ a: LanAccess, camera: String? = nil) -> Seal.Secrets {
        func value(_ s: String?) -> String? {
            let v = s?.trimmingCharacters(in: .whitespaces) ?? ""
            return v.isEmpty ? nil : v
        }
        return Seal.Secrets(address: value(a.address), password: a.password.flatMap { $0.isEmpty ? nil : $0 },
                            apiKey: value(a.apiKey), cameraUrl: value(camera))
    }

    /// "" tells the bridge to forget the own camera.
    private func removeCamera() async {
        guard let api = app.api, viaBridge != nil else { return }
        do {
            guard let key = bridgeInfo?.key, !key.isEmpty else { throw LanError(app.l10n(.errBridgeKey)) }
            try await api.bridgePrinterAccess(printer: id, sealed: try Seal.seal(publicKey: key, Seal.Secrets(cameraUrl: "")))
            cameraUrl = ""
            cameraMsg = app.l10n(.ownCameraRemoved)
        } catch {
            self.error = errorText(app.l10n, error)
        }
    }

    private func remove() async {
        guard let api = app.api else { return }
        do {
            try await api.deletePrinter(id: id)
            app.saveLanAccess(id, nil)
            dismiss()
        } catch {
            self.error = errorText(app.l10n, error)
        }
    }
}
