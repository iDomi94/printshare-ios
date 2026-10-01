import CryptoKit
import Foundation

/// Elegoo Centauri Carbon (stock firmware) on the home Wi-Fi: SDCP over WebSocket :3030 + chunked HTTP upload :80.
/// Port of the Expo app's `lib/lan/sdcp.ts` (itself a port of the server's `printers/elegoo.py`). The printer answers a
/// status request without its MainboardID and sends the ID along, so no UDP discovery is needed.
actor SDCPPrinter: LanPrinter {
    private typealias Raw = [String: Any]

    static let chunkSize = 1 << 20              // Elegoo's maximum per request
    static let fileTimeout: TimeInterval = 20   // a fresh upload shows up in the file list
    static let startTimeout: TimeInterval = 25  // the printer leaves its resting state
    static let states: [Int: String] = [
        0: "idle", 1: "homing", 5: "pausing", 6: "paused", 7: "stopping", 8: "stopped", 9: "completed",
        10: "file_checking", 11: "printer_checking", 12: "resuming", 13: "printing", 14: "error", 15: "auto_leveling",
        16: "preheating", 18: "resuming", 20: "heating", 21: "leveling",
    ]
    /// idle / stopped / completed: nothing runs (after a print the CC stays in 9).
    static let atRestCodes: Set<Int> = [0, 8, 9]
    static let startAcks: [Int: String] = [
        1: "the printer is busy", 2: "file not found on the printer", 3: "MD5 check failed",
        4: "the printer could not read the file", 5: "resolution mismatch", 6: "unknown file format",
        7: "the file was sliced for a different printer model",
    ]
    private static let unreachable = "printer not reachable on the Wi-Fi"

    nonisolated let host: String
    private let session: URLSession
    private let wsURL: URL?
    private let httpBase: String
    private var ws: URLSessionWebSocketTask?
    private var mainboard = ""

    init(host: String, session: URLSession = .shared, wsURL: URL? = nil, httpBase: String? = nil) {
        self.host = host
        self.session = session
        self.wsURL = wsURL ?? URL(string: "ws://\(host):3030/websocket")
        self.httpBase = httpBase ?? "http://\(host)"
    }

    // MARK: WebSocket

    private func socket() throws -> URLSessionWebSocketTask {
        if let ws, ws.state == .running { return ws }
        guard let wsURL else { throw LanError(Self.unreachable) }
        let task = session.webSocketTask(with: wsURL)
        task.maximumMessageSize = 8 << 20
        task.resume()
        ws = task
        return task
    }

    /// Send `text` (if any) and read messages until `match` returns one. A watchdog closes the socket after
    /// `timeout`, which ends the pending receive; the next call opens a new connection.
    private func exchange(_ text: String?, timeout: TimeInterval, failure: String,
                          match: (Raw) -> Raw?) async throws -> Raw {
        let ws = try socket()
        let deadline = Date().addingTimeInterval(timeout)
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(timeout))
            if !Task.isCancelled { ws.cancel(with: .goingAway, reason: nil) }
        }
        defer { watchdog.cancel() }
        do {
            if let text { try await ws.send(.string(text)) }
        } catch {
            drop(ws)
            throw LanError(Date() >= deadline ? failure : Self.unreachable)
        }
        while true {
            let message: URLSessionWebSocketTask.Message
            do { message = try await ws.receive() } catch {
                drop(ws)
                throw LanError(Date() >= deadline.addingTimeInterval(-0.5) ? failure : Self.unreachable)
            }
            let text: String
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(decoding: d, as: UTF8.self)
            @unknown default: continue
            }
            // "pong" and the like are not JSON
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? Raw else { continue }
            let data = obj["Data"] as? Raw ?? [:]
            if let id = (obj["MainboardID"] as? String) ?? (data["MainboardID"] as? String), !id.isEmpty { mainboard = id }
            if let hit = match(obj) { return hit }
        }
    }

    private func drop(_ task: URLSessionWebSocketTask) {
        task.cancel(with: .goingAway, reason: nil)
        if ws === task { ws = nil }
    }

    private func message(_ cmd: Int, _ payload: Raw, requestId: String) -> String {
        let msg: Raw = [
            "Id": Lan.randomHex(), "Topic": "sdcp/request/\(mainboard)",
            "Data": ["Cmd": cmd, "Data": payload, "RequestID": requestId, "MainboardID": mainboard,
                     "TimeStamp": Int(Date().timeIntervalSince1970 * 1000), "From": 1] as Raw,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: msg)) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// One SDCP command; returns the response message.
    private func request(_ cmd: Int, _ payload: Raw = [:], timeout: TimeInterval = 8) async throws -> Raw {
        let requestId = Lan.randomHex()
        return try await exchange(message(cmd, payload, requestId: requestId), timeout: timeout,
                                  failure: "the printer did not answer") { msg in
            let topic = msg["Topic"] as? String ?? ""
            let data = msg["Data"] as? Raw ?? [:]
            return topic.contains("sdcp/response") && data["RequestID"] as? String == requestId ? msg : nil
        }
    }

    /// Ask for the status (Cmd 0) and wait for the printer's next status message.
    private func rawStatus() async throws -> Raw {
        try await exchange(message(0, [:], requestId: Lan.randomHex()), timeout: 8,
                           failure: "the printer did not send its status") { msg in
            let topic = msg["Topic"] as? String ?? ""
            let status = (msg["Status"] as? Raw) ?? ((msg["Data"] as? Raw)?["Status"] as? Raw)
            if let status { return status }
            return topic.contains("sdcp/status") ? [:] : nil
        }
    }

    // MARK: status

    func status() async throws -> PrinterStatus {
        Self.status(from: try await rawStatus(), host: host)
    }

    static func status(from st: [String: Any], host: String) -> PrinterStatus {
        let pi = st["PrintInfo"] as? [String: Any] ?? [:]
        let fans = st["CurrentFanSpeed"] as? [String: Any] ?? [:]
        let light = st["LightStatus"] as? [String: Any] ?? [:]
        let code = int(pi["Status"])
        let state = code.map { states[$0] ?? "status_\($0)" } ?? "idle"
        var out = PrinterStatus(kind: Lan.kind(state), state: state)
        out.file = (pi["Filename"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        out.progress = num(pi["Progress"])
        out.layer = int(pi["CurrentLayer"])
        out.layers = int(pi["TotalLayer"])
        let ticks = num(pi["CurrentTicks"]), total = num(pi["TotalTicks"])
        out.printDurationS = ticks
        if let total, total > 0, let ticks { out.timeRemainingS = max(0, total - ticks) }
        out.nozzle = num(st["TempOfNozzle"])
        out.nozzleTarget = num(st["TempTargetNozzle"])
        out.bed = num(st["TempOfHotbed"])
        out.bedTarget = num(st["TempTargetHotbed"])
        out.camera = "http://\(host):3031/video"
        out.heaters = [
            "nozzle": HeaterState(actual: out.nozzle, target: out.nozzleTarget),
            "bed": HeaterState(actual: out.bed, target: out.bedTarget),
            "chamber": HeaterState(actual: num(st["TempOfBox"]), target: num(st["TempTargetBox"])),
        ]
        var fanValues: [String: Double] = [:]
        fanValues["part"] = num(fans["ModelFan"])
        fanValues["aux"] = num(fans["AuxiliaryFan"])
        fanValues["chamber"] = num(fans["BoxFan"])
        out.fans = fanValues
        if let second = light["SecondLight"] { out.lights = ["light": (second as? Bool) ?? ((num(second) ?? 0) != 0)] }
        out.speed = int(pi["PrintSpeedPct"])
        return out
    }

    private func atRest() async throws -> Bool {
        let st = try await rawStatus()
        let code = Self.int((st["PrintInfo"] as? Raw)?["Status"])
        let current = (st["CurrentStatus"] as? [Any])?.compactMap { Self.int($0) } ?? [0]
        return (code == nil || Self.atRestCodes.contains(code!)) && current == [0]
    }

    // MARK: upload + start

    static func md5(of file: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = Insecure.MD5()
        while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func upload(_ file: URL, name: String, onProgress: (@Sendable (Double) -> Void)?) async throws {
        let size = ((try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? NSNumber)?.intValue ?? 0
        guard size > 0 else { throw LanError("the G-code is empty") }
        guard let target = URL(string: "\(httpBase)/uploadFile/upload") else { throw LanError(Self.unreachable) }
        let md5 = try Self.md5(of: file)
        let uuid = Lan.randomHex()
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var offset = 0
        while offset < size {
            let chunk = try input.read(upToCount: Self.chunkSize) ?? Data()
            if chunk.isEmpty { break }
            let boundary = Multipart.boundary()
            let body = Multipart.body(boundary: boundary,
                                      fields: [("Check", "1"), ("S-File-MD5", md5), ("Offset", String(offset)),
                                               ("Uuid", uuid), ("TotalSize", String(size))],
                                      fileField: "File", fileName: name, data: chunk)
            var req = URLRequest(url: target)
            req.httpMethod = "POST"
            req.timeoutInterval = 60
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            let (data, res): (Data, URLResponse)
            do { (data, res) = try await session.upload(for: req, from: body) } catch { throw LanError(Self.unreachable) }
            let status = (res as? HTTPURLResponse)?.statusCode ?? 0
            let code = ((try? JSONSerialization.jsonObject(with: data)) as? Raw)?["code"] as? String
            guard status == 200, code == "000000" else {
                throw LanError("the printer refused the upload (HTTP \(status))")
            }
            offset += chunk.count
            onProgress?(Double(offset) / Double(size))
        }
    }

    private func waitForFile(_ name: String) async {
        let end = Date().addingTimeInterval(Self.fileTimeout)
        while Date() < end {
            // the listing is only a readiness hint
            if let r = try? await request(258, ["Url": "/local"]) {
                let files = ((r["Data"] as? Raw)?["Data"] as? Raw)?["FileList"] as? [Raw] ?? []
                if files.contains(where: { (($0["name"] as? String ?? "") as NSString).lastPathComponent == name }) { return }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    func send(file: URL, name: String, options: SendOptions) async throws {
        options.onStep?(.upload)
        try await upload(file, name: name, onProgress: options.onProgress)
        guard options.start else { return }
        options.onStep?(.start)
        // CC1 V0.3.0-o acknowledges a start sent right after the upload but drops it: wait for the file to be
        // listed, then check that the printer really leaves its resting state, and send the start once more
        // (server finding 11). This is part of the one start the user confirmed, not a repeated request.
        await waitForFile(name)
        for attempt in 1...2 {
            let r = try await request(128, [
                "Filename": name, "StartLayer": 0, "Calibration_switch": options.leveling == false ? 0 : 1,
                "PrintPlatformType": 0, "Tlp_Switch": 0, "slot_map": [Any](), "path_prefix": "/local",
            ])
            if let ack = Self.int(((r["Data"] as? Raw)?["Data"] as? Raw)?["Ack"]), ack != 0 {
                throw LanError("the printer refused to start: \(Self.startAcks[ack] ?? "error code \(ack)")")
            }
            let end = Date().addingTimeInterval(Self.startTimeout)
            while Date() < end {
                try await Task.sleep(for: .seconds(2))
                if !(try await atRest()) { return }
            }
            if attempt == 2 { break }
        }
        throw LanError("the printer accepted the start but did not begin - the file is on the printer, start it on its screen")
    }

    func control(_ action: String) async throws {
        let cmds = ["pause": 129, "cancel": 130, "resume": 131]
        guard let cmd = cmds[action] else { throw LanError("unknown action \(action)") }
        _ = try await request(cmd)
    }

    func close() async {
        ws?.cancel(with: .normalClosure, reason: nil)
        ws = nil
    }

    // MARK: JSON numbers

    static func num(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        return nil
    }

    static func int(_ v: Any?) -> Int? { num(v).map { Int($0) } }
}
