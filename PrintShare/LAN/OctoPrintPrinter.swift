import Foundation

/// Printers driven by OctoPrint (e.g. Creality Ender, Prusa MK3S, Anycubic) on the home Wi-Fi. Port of the Expo app's
/// `lib/lan/octoprint.ts` (server 0.15.3). Auth: API key (OctoPrint settings > Application keys).
actor OctoPrintPrinter: LanPrinter {
    private typealias Raw = [String: Any]
    private static let unreachable = "OctoPrint not reachable on the Wi-Fi"
    private static let rejected = "OctoPrint rejected the API key"
    private static let notConnected = "the printer is busy or not connected in OctoPrint"

    nonisolated let base: String
    private let apiKey: String
    private let session: URLSession

    init(address: String, apiKey: String, session: URLSession = .shared) throws {
        guard !apiKey.isEmpty else { throw LanError("enter the OctoPrint API key (Settings > Application keys)") }
        base = Lan.baseURL(address)
        self.apiKey = apiKey
        self.session = session
    }

    private func call(_ method: String, _ path: String, body: [String: String]? = nil,
                      timeout: TimeInterval = 10) async throws -> (Data, Int) {
        guard let url = URL(string: base + path) else { throw LanError(Self.unreachable) }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let (data, res): (Data, URLResponse)
        do { (data, res) = try await session.data(for: req) } catch { throw LanError(Self.unreachable) }
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw LanError(Self.rejected) }
        return (data, status)
    }

    func status() async throws -> PrinterStatus {
        let (jobData, jobStatus) = try await call("GET", "/api/job")
        guard (200..<300).contains(jobStatus) else { throw LanError("OctoPrint answered HTTP \(jobStatus)") }
        let job = (try? JSONSerialization.jsonObject(with: jobData)) as? Raw ?? [:]
        let (prData, prStatus) = try await call("GET", "/api/printer")
        // 409: OctoPrint runs but the printer is not connected
        let printer = (200..<300).contains(prStatus) ? (try? JSONSerialization.jsonObject(with: prData)) as? Raw : nil
        return Self.status(printer: printer, job: job)
    }

    static func state(printer: [String: Any]?, job: [String: Any]) -> String {
        guard let printer else { return "offline" }
        let f = (printer["state"] as? [String: Any])?["flags"] as? [String: Any] ?? [:]
        func on(_ k: String) -> Bool { (f[k] as? Bool) ?? false }
        if on("cancelling") { return "stopping" }
        if on("pausing") { return "pausing" }
        if on("paused") { return "paused" }
        if on("printing") { return "printing" }
        if on("error") || on("closedOrError") { return "error" }
        if (SDCPPrinter.num((job["progress"] as? [String: Any])?["completion"]) ?? 0) >= 100 { return "complete" }
        return "standby"
    }

    static func status(printer: [String: Any]?, job: [String: Any]) -> PrinterStatus {
        let state = state(printer: printer, job: job)
        let temps = printer?["temperature"] as? [String: Any] ?? [:]
        let tool = temps["tool0"] as? [String: Any] ?? [:], bed = temps["bed"] as? [String: Any] ?? [:]
        let progress = job["progress"] as? [String: Any] ?? [:]
        let file = (job["job"] as? [String: Any])?["file"] as? [String: Any] ?? [:]
        var out = PrinterStatus(kind: Lan.kind(state), state: state)
        out.file = (file["display"] as? String) ?? (file["name"] as? String)
        out.progress = ((SDCPPrinter.num(progress["completion"]) ?? 0) * 10).rounded() / 10
        out.printDurationS = SDCPPrinter.num(progress["printTime"])
        out.timeRemainingS = SDCPPrinter.num(progress["printTimeLeft"])
        out.nozzle = SDCPPrinter.num(tool["actual"])
        out.nozzleTarget = SDCPPrinter.num(tool["target"])
        out.bed = SDCPPrinter.num(bed["actual"])
        out.bedTarget = SDCPPrinter.num(bed["target"])
        out.heaters = ["nozzle": HeaterState(actual: out.nozzle, target: out.nozzleTarget),
                       "bed": HeaterState(actual: out.bed, target: out.bedTarget)]
        return out
    }

    /// Multipart upload to local storage; `select` + `print` start it (only after the user confirmed).
    func send(file: URL, name: String, options: SendOptions) async throws {
        options.onStep?(.upload)
        guard let target = URL(string: "\(base)/api/files/local") else { throw LanError(Self.unreachable) }
        let flag = options.start ? "true" : "false"
        let boundary = Multipart.boundary()
        let body = try Multipart.file(boundary: boundary, fields: [("select", flag), ("print", flag)],
                                      fileField: "file", fileName: name, source: file)
        defer { try? FileManager.default.removeItem(at: body) }
        var req = URLRequest(url: target)
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        let report = options.onProgress
        let progress = UploadProgress { sent, total in
            if let report, total > 0 { report(min(1, Double(sent) / Double(total))) }
        }
        let (data, res): (Data, URLResponse)
        do { (data, res) = try await session.upload(for: req, fromFile: body, delegate: progress) } catch {
            throw LanError(Self.unreachable)
        }
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 { throw LanError(Self.rejected) }
        if status == 409 { throw LanError(Self.notConnected) }
        guard status < 300 else { throw LanError("OctoPrint refused the upload (HTTP \(status))") }
        if options.start {
            options.onStep?(.start)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? Raw
            if obj?["effectivePrint"] as? Bool == false {
                throw LanError("OctoPrint stored the file but did not start it - is the printer connected?")
            }
        }
    }

    func control(_ action: String) async throws {
        let bodies = ["pause": ["command": "pause", "action": "pause"], "resume": ["command": "pause", "action": "resume"],
                      "cancel": ["command": "cancel"]]
        guard let body = bodies[action] else { throw LanError("unknown action \(action)") }
        let (_, status) = try await call("POST", "/api/job", body: body)
        if status == 409 { throw LanError(Self.notConnected) }
        guard status < 300 else { throw LanError("\(action) failed (HTTP \(status))") }
    }

    func close() async {}
}
