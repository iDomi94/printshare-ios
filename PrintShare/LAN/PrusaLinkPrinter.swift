import CryptoKit
import Foundation

/// HTTP digest (RFC 7616, MD5) for PrusaLink - with qop=auth when the printer asks for it, else the RFC 2069 form.
struct DigestAuth: Sendable {
    let user: String
    let password: String
    private(set) var realm = ""
    private(set) var nonce = ""
    private(set) var opaque = ""
    private(set) var qop = ""
    private(set) var nc = 0

    init(user: String, password: String) { self.user = user; self.password = password }

    var ready: Bool { !nonce.isEmpty }

    static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Read the challenge of a 401 (`WWW-Authenticate: Digest …`); false when there is none.
    mutating func learn(_ header: String?) -> Bool {
        guard let header, header.lowercased().hasPrefix("digest ") else { return false }
        var fields: [String: String] = [:]
        let rest = String(header.dropFirst(7))
        let re = try? NSRegularExpression(pattern: #"(\w+)=(?:"([^"]*)"|([^,\s]*))"#)
        for m in re?.matches(in: rest, range: NSRange(rest.startIndex..., in: rest)) ?? [] {
            guard let k = Range(m.range(at: 1), in: rest) else { continue }
            let v = Range(m.range(at: 2), in: rest) ?? Range(m.range(at: 3), in: rest)
            fields[rest[k].lowercased()] = v.map { String(rest[$0]) } ?? ""
        }
        realm = fields["realm"] ?? ""
        nonce = fields["nonce"] ?? ""
        opaque = fields["opaque"] ?? ""
        qop = (fields["qop"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .contains("auth") ? "auth" : ""
        nc = 0
        return !nonce.isEmpty
    }

    mutating func header(method: String, uri: String, cnonce: String = Lan.randomHex(8)) -> String {
        let ha1 = Self.md5("\(user):\(realm):\(password)"), ha2 = Self.md5("\(method):\(uri)")
        var parts = #"username="\#(user)", realm="\#(realm)", nonce="\#(nonce)", uri="\#(uri)""#
        if !qop.isEmpty {
            nc += 1
            let count = String(format: "%08x", nc)
            let response = Self.md5("\(ha1):\(nonce):\(count):\(cnonce):auth:\(ha2)")
            parts += #", qop=auth, nc=\#(count), cnonce="\#(cnonce)", response="\#(response)""#
        } else {
            parts += #", response="\#(Self.md5("\(ha1):\(nonce):\(ha2)"))""#
        }
        if !opaque.isEmpty { parts += #", opaque="\#(opaque)""# }
        return "Digest \(parts), algorithm=MD5"
    }
}

/// Prusa printers with PrusaLink (MK4/MK4S, MK3.9, CORE One, MINI, XL) on the home Wi-Fi. Port of the Expo app's
/// `lib/lan/prusalink.ts` (server 0.15.3). Auth: HTTP digest, user "maker" + the password from the printer screen
/// (Settings > Network > PrusaLink); older firmware: X-Api-Key. Spec: prusa3d/Prusa-Link-Web spec/openapi.yaml.
actor PrusaLinkPrinter: LanPrinter {
    private typealias Raw = [String: Any]
    static let states = ["IDLE": "standby", "READY": "standby", "BUSY": "busy", "PRINTING": "printing",
                         "PAUSED": "paused", "FINISHED": "complete", "STOPPED": "cancelled", "ERROR": "error",
                         "ATTENTION": "attention"]
    private static let unreachable = "printer not reachable on the Wi-Fi"
    private static let rejected = "PrusaLink rejected the password / API key"

    nonisolated let base: String
    private let apiKey: String?
    private var digest: DigestAuth?
    private let session: URLSession

    init(address: String, password: String?, apiKey: String?, username: String = "maker",
         session: URLSession = .shared) throws {
        guard !(password ?? "").isEmpty || !(apiKey ?? "").isEmpty else {
            throw LanError("enter the PrusaLink password (shown on the printer)")
        }
        base = Lan.baseURL(address)
        self.apiKey = apiKey
        digest = (password ?? "").isEmpty ? nil : DigestAuth(user: username, password: password ?? "")
        self.session = session
    }

    private func auth(_ method: String, _ path: String) -> [String: String] {
        guard digest != nil else { return ["X-Api-Key": apiKey ?? ""] }
        guard digest?.ready == true else { return [:] }
        return ["Authorization": digest!.header(method: method, uri: path)]
    }

    /// First contact or an expired nonce: the printer answers 401 with a challenge, learn it and ask once more.
    /// The unauthenticated first try is refused by the printer, so nothing is done twice.
    private func call(_ method: String, _ path: String, timeout: TimeInterval = 10) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: base + path) else { throw LanError(Self.unreachable) }
        for attempt in 1...2 {
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.timeoutInterval = timeout
            for (k, v) in auth(method, path) { req.setValue(v, forHTTPHeaderField: k) }
            let data: Data, res: URLResponse
            do { (data, res) = try await session.data(for: req) } catch { throw LanError(Self.unreachable) }
            guard let http = res as? HTTPURLResponse else { throw LanError(Self.unreachable) }
            if http.statusCode == 401, attempt == 1,
               digest?.learn(http.value(forHTTPHeaderField: "WWW-Authenticate")) == true { continue }
            if http.statusCode == 401 { throw LanError(Self.rejected) }
            return (data, http)
        }
        throw LanError(Self.rejected)
    }

    private func json(_ path: String) async throws -> Raw {
        let (data, res) = try await call("GET", path)
        if res.statusCode == 204 { return [:] }
        guard (200..<300).contains(res.statusCode) else { throw LanError("PrusaLink answered HTTP \(res.statusCode)") }
        return (try? JSONSerialization.jsonObject(with: data)) as? Raw ?? [:]
    }

    func status() async throws -> PrinterStatus {
        let st = try await json("/api/v1/status")
        let job: Raw = st["job"] != nil ? ((try? await json("/api/v1/job")) ?? [:]) : [:]
        return Self.status(status: st, job: job)
    }

    static func status(status st: [String: Any], job: [String: Any]) -> PrinterStatus {
        let pr = st["printer"] as? [String: Any] ?? [:], sj = st["job"] as? [String: Any] ?? [:]
        let file = job["file"] as? [String: Any] ?? [:]
        let raw = "\(pr["state"] ?? "")".uppercased()
        let state = states[raw] ?? (raw.isEmpty ? nil : raw.lowercased())
        var out = PrinterStatus(kind: Lan.kind(state), state: state)
        out.file = (file["display_name"] as? String) ?? (file["name"] as? String)
        out.progress = ((SDCPPrinter.num(sj["progress"]) ?? SDCPPrinter.num(job["progress"]) ?? 0) * 10).rounded() / 10
        out.printDurationS = SDCPPrinter.num(sj["time_printing"]) ?? SDCPPrinter.num(job["time_printing"])
        out.timeRemainingS = SDCPPrinter.num(sj["time_remaining"]) ?? SDCPPrinter.num(job["time_remaining"])
        out.nozzle = SDCPPrinter.num(pr["temp_nozzle"])
        out.nozzleTarget = SDCPPrinter.num(pr["target_nozzle"])
        out.bed = SDCPPrinter.num(pr["temp_bed"])
        out.bedTarget = SDCPPrinter.num(pr["target_bed"])
        out.heaters = ["nozzle": HeaterState(actual: out.nozzle, target: out.nozzleTarget),
                       "bed": HeaterState(actual: out.bed, target: out.bedTarget)]
        out.speed = SDCPPrinter.int(pr["speed"])
        return out
    }

    private func storage() async throws -> String {
        let list = try await json("/api/v1/storage")["storage_list"] as? [Raw] ?? []
        guard let st = list.first(where: {
            ($0["available"] as? Bool) == true && ($0["read_only"] as? Bool) != true && !(($0["path"] as? String) ?? "").isEmpty
        }), let path = st["path"] as? String else {
            throw LanError("no writable storage on the printer - is a USB drive inserted?")
        }
        return path.replacingRegex("^/+|/+$", with: "")
    }

    /// The file goes as the raw body of a PUT; `Print-After-Upload` starts it (only after the user confirmed).
    func send(file: URL, name: String, options: SendOptions) async throws {
        options.onStep?(.upload)
        let storage = try await storage()                     // also gets a fresh digest nonce
        let remote = Self.remoteName(name)
        let path = "/api/v1/files/\(storage)/\(remote.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? remote)"
        guard let url = URL(string: base + path) else { throw LanError(Self.unreachable) }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.timeoutInterval = 600
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue("?1", forHTTPHeaderField: "Overwrite")
        req.setValue(options.start ? "?1" : "?0", forHTTPHeaderField: "Print-After-Upload")
        for (k, v) in auth("PUT", path) { req.setValue(v, forHTTPHeaderField: k) }
        let report = options.onProgress
        let progress = UploadProgress { sent, total in
            if let report, total > 0 { report(min(1, Double(sent) / Double(total))) }
        }
        let res: URLResponse
        do { (_, res) = try await session.upload(for: req, fromFile: file, delegate: progress) } catch {
            throw LanError(Self.unreachable)
        }
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 { throw LanError(Self.rejected) }
        if status == 409 { throw LanError("the printer is busy") }
        guard (200..<300).contains(status) else { throw LanError("the printer refused the upload (HTTP \(status))") }
        if options.start { options.onStep?(.start) }
    }

    func control(_ action: String) async throws {
        guard ["pause", "resume", "cancel"].contains(action) else { throw LanError("unknown action \(action)") }
        let job = try await json("/api/v1/job")
        guard let id = SDCPPrinter.int(job["id"]) else { throw LanError("no print is running") }
        let res: HTTPURLResponse
        if action == "cancel" {
            (_, res) = try await call("DELETE", "/api/v1/job/\(id)")
        } else {
            (_, res) = try await call("PUT", "/api/v1/job/\(id)/\(action)")
        }
        guard res.statusCode < 300 else { throw LanError("\(action) failed (HTTP \(res.statusCode))") }
    }

    func close() async {}

    /// Printer USB drives are FAT: short, plain names.
    static func remoteName(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        var stem = ext.isEmpty ? name : (name as NSString).deletingPathExtension
        stem = stem.replacingRegex("[^A-Za-z0-9_.-]+", with: "_").replacingRegex("^[._]+|[._]+$", with: "")
        if stem.isEmpty { stem = "print" }
        return String(stem.prefix(60)) + (ext.isEmpty ? ".gcode" : ".\(ext.lowercased())")
    }
}
