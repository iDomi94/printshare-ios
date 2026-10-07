import Foundation

/// Bambu Lab printer in LAN-only mode, reached by the phone itself (beginner mode without a bridge). Port of the Expo
/// app's `lib/lan/bambu.ts` (upstream 0e0e8a7): one MQTT connection per printer stays open, prints start like in
/// Bambu Studio (`project_file` with `ams_mapping`) after an FTPS upload of the wrapped ".gcode.3mf".
struct BambuPrinter: LanPrinter {
    static let readyTimeout: TimeInterval = 10
    static let lanMode = "Switch on LAN-only mode on the printer (Settings → WLAN), with newer firmware also developer mode - "
        + "without it Bambu printers take no print jobs from other apps."

    let host: String
    let code: String
    /// Tests: plain MQTT / FTP on other ports and a known serial number (no certificate to read it from).
    var mqttPort: UInt16 = 8883
    var tls = true
    var serial: String?
    /// How long the printer may take to show that it starts the print.
    var startTimeout: TimeInterval = 45
    var uploader: any BambuUploading = BambuFTPS()
    var links: BambuLinks = .shared

    init(host: String, code: String) {
        self.host = host
        self.code = code
    }

    /// The open connection, once the printer has sent its state.
    private func ready() async throws -> BambuLink {
        let link = try await links.link(host: host, code: code, port: mqttPort, tls: tls, serial: serial)
        let until = Date().addingTimeInterval(Self.readyTimeout)
        while !link.read({ $0["gcode_state"] != nil }) && Date() < until && link.connected {
            try await Task.sleep(for: .milliseconds(200))
        }
        guard link.read({ $0["gcode_state"] != nil }) else { throw LanError(link.error ?? "no answer from the printer") }
        return link
    }

    func status() async throws -> PrinterStatus {
        try await ready().read { BambuState.status($0) }
    }

    func send(file: URL, name: String, options: SendOptions) async throws {
        let link = try await ready()
        let task = BambuState.taskName(name)
        let remote = "\(task).gcode.3mf"
        options.onStep?(.upload)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bambu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wrapped = dir.appendingPathComponent(remote)
        let filaments: Int
        do {
            let (uploader, host, code) = (self.uploader, self.host, self.code)
            filaments = try await Task.detached(priority: .userInitiated) { () throws -> Int in
                let n = try Bambu3MF.wrap(gcode: file, to: wrapped)
                try uploader.upload(host: host, code: code, file: wrapped, remoteName: remote, progress: options.onProgress)
                return n
            }.value
        } catch {
            throw LanError("upload to the printer failed: \(error.localizedDescription) - is an SD card in the printer?")
        }
        options.onProgress?(1)
        guard options.start else { return }
        options.onStep?(.start)
        let (mapping, ams) = link.read {
            (BambuState.amsMapping(filaments: filaments, tools: options.tools, report: $0), BambuState.hasAms($0))
        }
        let sentAt = Date()
        try await link.publish(BambuState.startCommand(task: task, remote: remote, mapping: mapping, ams: ams,
                                                       leveling: options.leveling != false))
        // the printer has to show that it starts: without LAN-only mode it ignores the command silently. This waits for
        // the one start the user confirmed; nothing is sent again.
        while Date().timeIntervalSince(sentAt) < startTimeout {
            if let reply = link.reply("project_file"), reply.at >= sentAt,
               BambuState.text(reply.msg["result"]).matches("^(fail|failed|error)$", options: .caseInsensitive) {
                let reason = BambuState.text(reply.msg["reason"] ?? reply.msg["err_code"])
                throw LanError("the printer refused the print (\(reason.isEmpty ? "refused" : reason)). \(Self.lanMode)")
            }
            let started = link.read { r -> Bool in
                let g = BambuState.text(r["gcode_state"]).uppercased()
                let sub = BambuState.text(r["subtask_name"])
                return BambuState.starting.contains(g) && (sub.isEmpty || sub == task)
            }
            if started { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw LanError("the printer didn't start the print. \(Self.lanMode)")
    }

    func control(_ action: String) async throws {
        guard ["pause", "resume", "cancel"].contains(action) else { throw LanError("unknown action \(action)") }
        try await ready().publish(["print": ["command": action == "cancel" ? "stop" : action, "param": ""]])
    }

    /// The MQTT connection stays open for the next status call (the P1 sends only changes after the first report).
    func close() async {}
}

/// The open printer connections, one per address.
actor BambuLinks {
    static let shared = BambuLinks()

    private var links: [String: BambuLink] = [:]
    private var opening: [String: Task<BambuLink, Error>] = [:]
    private var serials: [String: String] = [:]

    func link(host: String, code: String, port: UInt16, tls: Bool, serial: String?) async throws -> BambuLink {
        if let l = links[host], l.code == code, l.connected { return l }
        if let t = opening[host] {
            let l = try await t.value
            if l.code == code { return l }
        }
        links.removeValue(forKey: host)?.close()
        let known = serial ?? serials[host]
        let t = Task { () throws -> BambuLink in
            var id = known
            if id == nil {
                guard let cert = await BambuNet.readCert(host: host, port: port), cert.bambu, !cert.serial.isEmpty else {
                    throw LanError("printer not reachable on the Wi-Fi - is it on, in LAN-only mode?")
                }
                id = cert.serial
            }
            let l = BambuLink(host: host, serial: id ?? "", code: code, port: port, tls: tls)
            try await l.open()
            return l
        }
        opening[host] = t
        defer { opening[host] = nil }
        let l = try await t.value
        links[host] = l
        serials[host] = l.serial
        return l
    }

    /// Tests: forget every connection.
    func reset() {
        for l in links.values { l.close() }
        links = [:]
        serials = [:]
    }
}
