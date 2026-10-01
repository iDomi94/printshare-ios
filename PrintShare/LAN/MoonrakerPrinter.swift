import Foundation

/// Klipper printers (e.g. Centauri Carbon with OpenCentauri COSMOS) on the home Wi-Fi through Moonraker's HTTP API.
/// Port of the Expo app's `lib/lan/moonraker.ts`: status incl. AFC lanes (CANVAS), upload + start, pause/resume/cancel.
actor MoonrakerPrinter: LanPrinter {
    private typealias Raw = [String: Any]
    private static let unreachable = "printer not reachable on the Wi-Fi"

    nonisolated let candidates: [String]
    private let session: URLSession
    private let apiKey: String?
    private var base: String?

    /// `apiKey`: only for Moonraker installs that require one (sent as X-Api-Key).
    init(address: String, apiKey: String? = nil, session: URLSession = .shared) {
        self.apiKey = apiKey
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while a.hasSuffix("/") { a.removeLast() }
        let url = a.matches("^https?://", options: .caseInsensitive) ? a : "http://\(a)"
        // COSMOS serves Moonraker on port 80, a classic Klipper install on 7125
        let hostPart = url.replacingRegex("^https?://", with: "")
        candidates = hostPart.matches(":\\d+$") ? [url] : [url, "\(url):7125"]
        self.session = session
    }

    private func fetch(_ url: String, method: String = "GET", timeout: TimeInterval) async throws -> (Data, Int) {
        guard let u = URL(string: url) else { throw LanError(Self.unreachable) }
        var req = URLRequest(url: u)
        req.httpMethod = method
        req.timeoutInterval = timeout
        if let apiKey { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        do {
            let (data, res) = try await session.data(for: req)
            return (data, (res as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw LanError(Self.unreachable)
        }
    }

    private func resolve() async throws -> String {
        if let base { return base }
        for candidate in candidates {
            guard let r = try? await fetch("\(candidate)/server/info", timeout: 5), r.1 == 200,
                  let obj = (try? JSONSerialization.jsonObject(with: r.0)) as? Raw, obj["result"] != nil else { continue }
            base = candidate
            return candidate
        }
        throw LanError(Self.unreachable)
    }

    private func get(_ path: String, timeout: TimeInterval = 8) async throws -> Raw {
        let base = try await resolve()
        let (data, status) = try await fetch(base + path, timeout: timeout)
        guard (200..<300).contains(status) else { throw LanError("the printer answered HTTP \(status)") }
        return ((try? JSONSerialization.jsonObject(with: data)) as? Raw)?["result"] as? Raw ?? [:]
    }

    private static func query(_ objects: [String]) -> String {
        "/printer/objects/query?" + objects.map {
            $0.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? $0
        }.joined(separator: "&")
    }

    func status() async throws -> PrinterStatus {
        let objects = ((try? await get("/printer/objects/list"))?["objects"] as? [String]) ?? []
        let wanted = ["print_stats", "display_status", "extruder", "heater_bed", "virtual_sdcard", "gcode_move"]
        let st = try await get(Self.query(wanted))["status"] as? Raw ?? [:]
        let base = try await resolve()
        var out = Self.status(from: st, base: base)
        out.lanes = await lanes(objects)
        return out
    }

    static func status(from st: [String: Any], base: String) -> PrinterStatus {
        func obj(_ k: String) -> [String: Any] { st[k] as? [String: Any] ?? [:] }
        let ps = obj("print_stats"), info = ps["info"] as? [String: Any] ?? [:]
        let ext = obj("extruder"), bed = obj("heater_bed")
        let state = (ps["state"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        var out = PrinterStatus(kind: Lan.kind(state), state: state)
        out.file = (ps["filename"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let display = SDCPPrinter.num(obj("display_status")["progress"]) ?? 0
        let progress = (display != 0 ? display : SDCPPrinter.num(obj("virtual_sdcard")["progress"]) ?? 0) * 100
        out.progress = (progress * 10).rounded() / 10
        out.layer = SDCPPrinter.int(info["current_layer"])
        out.layers = SDCPPrinter.int(info["total_layer"])
        out.printDurationS = SDCPPrinter.num(ps["print_duration"])
        out.nozzle = SDCPPrinter.num(ext["temperature"])
        out.nozzleTarget = SDCPPrinter.num(ext["target"])
        out.bed = SDCPPrinter.num(bed["temperature"])
        out.bedTarget = SDCPPrinter.num(bed["target"])
        out.camera = "\(base)/webcam/?action=stream"
        out.heaters = ["nozzle": HeaterState(actual: out.nozzle, target: out.nozzleTarget),
                       "bed": HeaterState(actual: out.bed, target: out.bedTarget)]
        out.speed = SDCPPrinter.num(obj("gcode_move")["speed_factor"]).map { Int(($0 * 100).rounded()) }
        return out
    }

    /// AFC lanes (CANVAS): one Klipper object per lane, "AFC_lane <name>" (AFC 1.2) or "AFC_stepper <name>".
    /// Lanes are extra information; the status works without them.
    private func lanes(_ objects: [String]) async -> [Lane] {
        guard objects.contains("AFC"),
              let afcStatus = try? await get(Self.query(["AFC"]))["status"] as? Raw else { return [] }
        let afc = afcStatus["AFC"] as? Raw ?? [:]
        let have = Set(objects)
        let objs = (afc["lanes"] as? [String] ?? []).compactMap { n in
            ["AFC_lane \(n)", "AFC_stepper \(n)"].first { have.contains($0) }
        }
        guard !objs.isEmpty, let st = try? await get(Self.query(objs))["status"] as? Raw else { return [] }
        return Self.lanes(objects: objs, status: st, currentLoad: afc["current_load"] as? String)
    }

    static func lanes(objects: [String], status st: [String: Any], currentLoad: String?) -> [Lane] {
        let out: [Lane] = objects.map { obj in
            let ln = st[obj] as? [String: Any] ?? [:]
            let name = obj.split(separator: " ").dropFirst().joined(separator: " ")
            let map = "\(ln["map"] ?? "")"
            let tool = map.matches("^T\\d+$") ? Int(map.dropFirst()) : nil
            let color = ln["color"] as? String ?? ""
            let hex = color.matches("^#?[0-9A-Fa-f]{6,8}$")
                ? "#" + String(color.replacingOccurrences(of: "#", with: "").prefix(6)).uppercased() : nil
            let material = (ln["material"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let filament = (ln["filament_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let loaded = ((ln["prep"] as? Bool) ?? false) || ((ln["load"] as? Bool) ?? false)
            let inToolhead = ((ln["tool_loaded"] as? Bool) ?? false) || name == currentLoad
            var lane = Lane(id: name, tool: tool, material: material, color: hex, filament: filament, loaded: loaded,
                            inToolhead: inToolhead)
            lane.unit = ln["unit"] as? String
            lane.weightG = SDCPPrinter.num(ln["weight"])
            lane.status = ln["status"] as? String
            return lane
        }
        return out.sorted { a, b in
            let ta = a.tool ?? 99, tb = b.tool ?? 99
            return ta != tb ? ta < tb : a.id < b.id
        }
    }

    /// Bed leveling is part of the printer's start G-code; it can't be switched per print here.
    func send(file: URL, name: String, options: SendOptions) async throws {
        options.onStep?(.upload)
        let base = try await resolve()
        guard let target = URL(string: "\(base)/server/files/upload") else { throw LanError(Self.unreachable) }
        let boundary = Multipart.boundary()
        let body = try Multipart.file(boundary: boundary,
                                      fields: [("root", "gcodes"), ("print", options.start ? "true" : "false")],
                                      fileField: "file", fileName: name, source: file)
        defer { try? FileManager.default.removeItem(at: body) }
        var req = URLRequest(url: target)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let apiKey { req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key") }
        let report = options.onProgress
        let progress = UploadProgress { sent, total in
            if let report, total > 0 { report(min(1, Double(sent) / Double(total))) }
        }
        let (data, res): (Data, URLResponse)
        do { (data, res) = try await session.upload(for: req, fromFile: body, delegate: progress) } catch {
            throw LanError(Self.unreachable)
        }
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 || status == 201 else { throw LanError("the printer refused the upload (HTTP \(status))") }
        if options.start {
            options.onStep?(.start)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? Raw
            let result = obj?["result"] as? Raw ?? obj
            if result?["print_started"] as? Bool == false {
                throw LanError("the printer stored the file but did not start it")
            }
        }
    }

    func control(_ action: String) async throws {
        guard ["pause", "resume", "cancel"].contains(action) else { throw LanError("unknown action \(action)") }
        let base = try await resolve()
        let (_, status) = try await fetch("\(base)/printer/print/\(action)", method: "POST", timeout: 15)
        guard (200..<300).contains(status) else { throw LanError("\(action) failed (HTTP \(status))") }
    }

    func close() async {}
}
