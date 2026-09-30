import Foundation

/// Trim, drop trailing slashes, default to http:// (same as `normalizeUrl` in api.ts).
func normalizeUrl(_ url: String) -> String {
    var u = url.trimmingCharacters(in: .whitespacesAndNewlines)
    while u.hasSuffix("/") { u.removeLast() }
    if !u.isEmpty && !u.matches("^https?://", options: .caseInsensitive) { u = "http://" + u }
    return u
}

/// Address that answered last, per server (`url|remoteUrl`). Kept outside the client so it survives re-creating it.
actor RouteCache {
    static let shared = RouteCache()
    private var active: [String: String] = [:]

    func address(for key: String) -> String? { active[key] }
    func set(_ address: String, for key: String) { active[key] = address }
    func remove(_ key: String) { active[key] = nil }
    func clear() { active.removeAll() }
}

private let probeTimeout: TimeInterval = 4

private struct Ack: Decodable, Sendable {
    init(from decoder: Decoder) throws {}
}

private struct ControlBody: Encodable { var action: String; var confirm: Bool }
private struct CreateJobBody: Encodable {
    var link: String
    var printer: String
    var file: String?
    var options: JobOptions
}
/// `leveling`: bed leveling before the print (DO-01), nil = printer default. Only sent with a print start.
/// `lanes`: {"<model filament, 1-based>": <printer tool of the chosen lane>} (AFC, server 0.8.0).
private struct SendBody: Encodable {
    var start: Bool
    var confirm: Bool
    var leveling: Bool?
    var lanes: [String: Int]?
}
private struct AdjustBody: Encodable {
    var kind: String
    var id: String
    var value: AdjustValue
    var confirm: Bool
}
private struct ProfileBody: Encodable {
    var machineFile: String?

    enum CodingKeys: String, CodingKey { case machineFile = "machine_file" }

    // null means "back to the standard profile", so it must be sent, not left out
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(machineFile, forKey: .machineFile)
    }
}

/// What a printer control changes (`POST /api/printers/{id}/adjust`).
enum AdjustKind: String, Sendable { case heater, fan, light, speed }

/// A number (temperature, fan %, speed %) or on/off (light).
enum AdjustValue: Encodable, Sendable, Equatable {
    case number(Double)
    case flag(Bool)

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let v): try c.encode(v)
        case .flag(let v): try c.encode(v)
        }
    }
}

enum CameraKind: String, Sendable { case snapshot, stream }

/// Client for the PrintShare server API (see printshare/api.py).
actor APIClient {
    private let server: Server
    private let l10n: L10n
    private let session: URLSession
    private let cache: RouteCache

    init(server: Server, l10n: L10n, session: URLSession = .shared, cache: RouteCache = .shared) {
        self.server = server
        self.l10n = l10n
        self.session = session
        self.cache = cache
    }

    /// Forget which address worked, e.g. when the app returns to the foreground (maybe left home).
    static func resetRoutes(cache: RouteCache = .shared) async { await cache.clear() }

    private nonisolated var key: String { "\(server.url)|\(server.remoteUrl ?? "")" }

    /// Home address, then the optional away address, without duplicates.
    nonisolated var addresses: [String] {
        var out: [String] = []
        for a in [server.url, server.remoteUrl ?? ""] where !a.isEmpty && !out.contains(a) { out.append(a) }
        return out
    }

    /// Which address is in use, once known.
    func route() async -> Route? {
        guard let a = await cache.address(for: key) else { return nil }
        return a == server.url ? .home : .remote
    }

    private nonisolated func headers(json: Bool) -> [String: String] {
        var h = ["Authorization": "Bearer \(server.token)"]
        if json { h["Content-Type"] = "application/json" }
        return h
    }

    // MARK: routing

    /// Ask all addresses at once; the first that answers at all (even 401) wins.
    private func probe() async -> String? {
        let addrs = addresses
        if addrs.count == 1 { return addrs[0] }
        let hdrs = headers(json: false)
        let session = session
        return await withTaskGroup(of: String?.self) { group in
            for a in addrs {
                group.addTask {
                    guard let url = URL(string: "\(a)/api/info") else { return nil }
                    var req = URLRequest(url: url)
                    req.timeoutInterval = probeTimeout
                    req.allHTTPHeaderFields = hdrs
                    do { _ = try await session.data(for: req); return a } catch { return nil }
                }
            }
            for await found in group {
                if let found { group.cancelAll(); return found }
            }
            return nil
        }
    }

    private func base() async -> String {
        if let known = await cache.address(for: key) { return known }
        if let found = await probe() {
            await cache.set(found, for: key)
            return found
        }
        return server.url
    }

    // MARK: transport

    private func networkError(_ error: Error) -> APIError {
        let timedOut = (error as? URLError)?.code == .timedOut
        return APIError(message: l10n(timedOut ? .errTimeout : .errOffline), status: 0, detail: "\(error)")
    }

    private func fetch(_ urlString: String, method: String, body: Data?, timeout: TimeInterval,
                       file: URL? = nil, contentType: String? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString) else {
            throw APIError(message: l10n(.errOffline), status: 0, detail: "bad URL \(urlString)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = timeout
        req.allHTTPHeaderFields = headers(json: body != nil)
        if let contentType { req.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        do {
            let result: (Data, URLResponse)
            if let file {
                result = try await session.upload(for: req, fromFile: file)
            } else {
                req.httpBody = body
                result = try await session.data(for: req)
            }
            let (data, res) = result
            guard let http = res as? HTTPURLResponse else {
                throw APIError(message: l10n(.errOffline), status: 0, detail: "no HTTP response")
            }
            return (data, http)
        } catch let e as APIError {
            throw e
        } catch {
            throw networkError(error)
        }
    }

    private func perform(_ path: String, method: String, body: Data?, timeout: TimeInterval) async throws
        -> (Data, HTTPURLResponse) {
        let base = await base()
        do {
            return try await fetch(base + path, method: method, body: body, timeout: timeout)
        } catch let e as APIError {
            // Maybe we moved between home and away: find the address that works now. Only reads are
            // repeated automatically - a print start or new job is never sent twice.
            guard addresses.count > 1 else { throw e }
            await cache.remove(key)
            guard let other = await probe() else { throw e }
            await cache.set(other, for: key)
            if other == base || method != "GET" { throw e }
            return try await fetch(other + path, method: method, body: body, timeout: timeout)
        }
    }

    private func failure(_ data: Data, status: Int) -> APIError {
        var detail = "HTTP \(status)"
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let d = obj["detail"] as? String {
            detail = d
        }
        return APIError(message: friendlyError(l10n, status: status, detail: detail), status: status, detail: detail)
    }

    private func decode<R: Decodable & Sendable>(_ type: R.Type, _ data: Data, status: Int) throws -> R {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw APIError(message: l10n(.errUnknown), status: status, detail: "\(error)") }
    }

    private func request<R: Decodable & Sendable>(_ path: String, method: String = "GET", body: (any Encodable)? = nil,
                                                  timeout: TimeInterval = 15) async throws -> R {
        let data = try body.map { try JSONEncoder().encode(AnyEncodable($0)) }
        let (out, res) = try await perform(path, method: method, body: data, timeout: timeout)
        guard (200..<300).contains(res.statusCode) else { throw failure(out, status: res.statusCode) }
        return try decode(R.self, out, status: res.statusCode)
    }

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? s
    }

    // MARK: endpoints

    func info() async throws -> ServerInfo { try await request("/api/info", timeout: 8) }
    func printers() async throws -> [Printer] { try await request("/api/printers") }

    func options(printer: String, process: String? = nil) async throws -> Options {
        try await request("/api/printers/\(enc(printer))/options" + (process.map { "?process=\(enc($0))" } ?? ""),
                          timeout: 30)
    }

    func status(printer: String) async throws -> PrinterStatus {
        try await request("/api/printers/\(enc(printer))/status", timeout: 20)
    }

    func control(printer: String, action: String) async throws {
        let _: Ack = try await request("/api/printers/\(enc(printer))/control", method: "POST",
                                       body: ControlBody(action: action, confirm: action == "cancel"))
    }

    // MARK: printer control (server 0.10.0)

    func controls(printer: String) async throws -> Controls {
        try await request("/api/printers/\(enc(printer))/controls", timeout: 20)
    }

    /// `confirm`: the user agreed to change a heater / stop a fan while a print runs (else the server answers 409).
    /// Never repeated automatically.
    func adjust(printer: String, kind: AdjustKind, id: String, value: AdjustValue, confirm: Bool = false) async throws {
        let _: Ack = try await request("/api/printers/\(enc(printer))/adjust", method: "POST",
                                       body: AdjustBody(kind: kind.rawValue, id: id, value: value, confirm: confirm),
                                       timeout: 20)
    }

    func temperatures(printer: String) async throws -> TempHistory {
        try await request("/api/printers/\(enc(printer))/temperatures", timeout: 20)
    }

    // MARK: camera (server 0.9.0) - the picture comes through the server, so it works away from home too

    func cameraInfo(printer: String) async throws -> CameraInfo {
        try await request("/api/printers/\(enc(printer))/camera", timeout: 20)
    }

    /// URL + auth header for the camera image. Snapshots get a changing `t` so no cache answers.
    func cameraRequest(printer: String, kind: CameraKind, width: Int? = nil, timeout: TimeInterval = 15) async -> URLRequest? {
        var query: [String] = []
        if let width { query.append("w=\(width)") }
        if kind == .snapshot { query.append("t=\(Int(Date().timeIntervalSince1970 * 1000))") }
        let path = "/api/printers/\(enc(printer))/camera/\(kind.rawValue)" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
        guard let url = URL(string: await base() + path) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        req.allHTTPHeaderFields = headers(json: false)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        return req
    }

    /// One camera image (JPEG).
    func cameraSnapshot(printer: String, width: Int? = nil) async throws -> Data {
        guard let req = await cameraRequest(printer: printer, kind: .snapshot, width: width) else {
            throw APIError(message: l10n(.cameraOffline), status: 0, detail: "bad URL")
        }
        let (data, res): (Data, URLResponse)
        do { (data, res) = try await session.data(for: req) } catch { throw networkError(error) }
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw failure(data, status: status) }
        return data
    }

    // MARK: own printer profiles (server 0.7.0)

    func profiles() async throws -> [UserProfile] { try await request("/api/profiles", timeout: 30) }

    func deleteProfile(file: String) async throws {
        let _: Ack = try await request("/api/profiles/\(enc(file))", method: "DELETE")
    }

    func printerProfile(printer: String) async throws -> PrinterProfile {
        try await request("/api/printers/\(enc(printer))/profile")
    }

    /// nil = back to the standard (system) profile.
    func setPrinterProfile(printer: String, machineFile: String?) async throws -> PrinterProfile {
        try await request("/api/printers/\(enc(printer))/profile", method: "PUT",
                          body: ProfileBody(machineFile: machineFile), timeout: 30)
    }

    /// Upload an OrcaSlicer preset (JSON) or preset bundle (zip) as raw body. Never retried on the other address.
    func uploadProfile(fileURL: URL, name: String) async throws -> [UserProfile] {
        let target = "\(await base())/api/profiles?filename=\(enc(name))"
        let (data, res) = try await fetch(target, method: "POST", body: nil, timeout: 120, file: fileURL,
                                          contentType: "application/octet-stream")
        guard (200..<300).contains(res.statusCode) else { throw failure(data, status: res.statusCode) }
        return try decode([UserProfile].self, data, status: res.statusCode)
    }

    func files(link: String) async throws -> [ModelFile] {
        try await request("/api/files?link=\(enc(link))", timeout: 60)
    }

    func createJob(link: String, printer: String, file: String?, options: JobOptions) async throws -> String {
        struct Created: Decodable, Sendable { var job: String }
        let c: Created = try await request("/api/jobs", method: "POST",
                                           body: CreateJobBody(link: link, printer: printer, file: file, options: options),
                                           timeout: 30)
        return c.job
    }

    func jobs() async throws -> [JobSummary] { try await request("/api/jobs") }
    func job(id: String) async throws -> Job { try await request("/api/jobs/\(enc(id))") }

    /// `lanes` only when the printer reports lanes; sent with uploads too, so the file on the printer matches.
    func send(job id: String, start: Bool, leveling: Bool? = nil, lanes: [Int: Int]? = nil) async throws {
        var mapping: [String: Int]?
        if let lanes, !lanes.isEmpty {
            mapping = Dictionary(uniqueKeysWithValues: lanes.map { (String($0.key), $0.value) })
        }
        let _: Ack = try await request("/api/jobs/\(enc(id))/send", method: "POST",
                                       body: SendBody(start: start, confirm: start, leveling: start ? leveling : nil,
                                                      lanes: mapping))
    }

    /// Layer data for the G-code viewer. Format 2 (server 0.6.0) adds the filament per path; older servers ignore
    /// the parameter and answer with format 1.
    func preview(job id: String) async throws -> Preview {
        try await request("/api/jobs/\(enc(id))/preview?format=2", timeout: 60)
    }

    /// Colours/filaments of a 3MF project (MA-04). The server downloads the model for this, hence the long timeout.
    func inspect(link: String, file: String?) async throws -> ModelColors {
        try await request("/api/inspect?link=\(enc(link))" + (file.map { "&file=\(enc($0))" } ?? ""), timeout: 120)
    }

    /// Download the sliced G-code (SL-10) into a temporary file named like the model, for the share sheet.
    func downloadGcode(job id: String, name: String) async throws -> URL {
        try await download("/api/jobs/\(enc(id))/gcode", folder: "gcode-\(id)", name: name)
    }

    /// One file of a model (index as in `files(link:)`) for the 3D view, into a temporary file (server 0.10.1).
    func downloadModelFile(link: String, file: String?, name: String) async throws -> URL {
        let path = "/api/model-file?link=\(enc(link))" + (file.map { "&file=\(enc($0))" } ?? "")
        return try await download(path, folder: "model-\(UUID().uuidString)", name: name)
    }

    private func download(_ path: String, folder: String, name: String) async throws -> URL {
        let (data, res) = try await perform(path, method: "GET", body: nil, timeout: 120)
        guard (200..<300).contains(res.statusCode) else { throw failure(data, status: res.statusCode) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(folder, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = (name as NSString).lastPathComponent
        let url = dir.appendingPathComponent(safe.isEmpty ? "file" : safe)
        try data.write(to: url, options: .atomic)
        return url
    }

    func deleteJob(id: String) async throws {
        let _: Ack = try await request("/api/jobs/\(enc(id))", method: "DELETE")
    }

    func sources() async throws -> [Source] { try await request("/api/sources") }

    func search(query: String, source: String, page: Int, sort: SortKey) async throws -> SearchPage {
        try await request("/api/search?q=\(enc(query))&source=\(enc(source))&page=\(page)&sort=\(sort.rawValue)",
                          timeout: 30)
    }

    func model(source: String, id: String) async throws -> ModelDetail {
        try await request("/api/models/\(enc(source))/\(enc(id))", timeout: 30)
    }

    /// Upload a local model file (file picker or share menu) as raw body. Never retried on the other address.
    func upload(fileURL: URL, name: String) async throws -> Upload {
        let target = "\(await base())/api/uploads?name=\(enc(name))"
        let (data, res) = try await fetch(target, method: "POST", body: nil, timeout: 600, file: fileURL,
                                          contentType: "application/octet-stream")
        guard (200..<300).contains(res.statusCode) else { throw failure(data, status: res.statusCode) }
        return try decode(Upload.self, data, status: res.statusCode)
    }
}

/// Type eraser so request bodies can be passed as `any Encodable`.
private struct AnyEncodable: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init(_ value: any Encodable) { encodeFn = { try value.encode(to: $0) } }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}

extension CharacterSet {
    /// Like encodeURIComponent: everything except letters, digits and `-_.~`.
    static let urlQueryValueAllowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.~")
}
