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
private struct PowerBody: Encodable { var on: Bool }
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
    /// Server 0.16.0: Spoolman spool Moonraker books the print on (left out when nil).
    var spoolId: Int?
    /// Server 0.32.0: record a time-lapse. Left out = the server's "always" setting (0.37.0).
    var timelapse: Bool?

    enum CodingKeys: String, CodingKey {
        case start, confirm, leveling, lanes, timelapse
        case spoolId = "spool_id"
    }
}
private struct RelayedBody: Encodable { var start: Bool; var file: String }
private struct ObserveBody: Encodable { var statuses: [String: PrinterStatus?] }
private struct PairBody: Encodable { var code: String; var name: String? }
private struct NameBody: Encodable { var name: String }
private struct SealedBody: Encodable { var sealed: String }
private struct DiscoverBody: Encodable { var subnet: String }
private struct BridgePrinterBody: Encodable { var printer: PrinterSettings; var sealed: String }
private struct ResolveBody: Encodable { var part: Double }
struct BookingRequest: Encodable, Sendable, Equatable {
    struct Use: Encodable, Sendable, Equatable { var spool: Int; var grams: Double; var label: String? }
    var printer: String
    var file: String
    var uses: [Use]
    var printerName: String?
    var job: String?

    enum CodingKeys: String, CodingKey {
        case printer, file, uses, job
        case printerName = "printer_name"
    }
}
private struct AdjustBody: Encodable {
    var kind: String
    var id: String
    var value: AdjustValue
    var confirm: Bool
}
private struct LinkBody: Encodable { var link: String }
private struct ManyfoldBody: Encodable {
    var url: String
    var token: String?
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url)
        try c.encodeIfPresent(token, forKey: .token)   // left out = keep the stored key
    }
    enum CodingKeys: String, CodingKey { case url, token }
}
private struct FailureBody: Encodable {
    var mlUrl: String
    var mlToken: String?
    var serverUrl: String
    var sensitivity: String
    var action: String
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(mlUrl, forKey: .mlUrl)
        try c.encodeIfPresent(mlToken, forKey: .mlToken)   // left out = keep the stored token
        try c.encode(serverUrl, forKey: .serverUrl)
        try c.encode(sensitivity, forKey: .sensitivity)
        try c.encode(action, forKey: .action)
    }
    enum CodingKeys: String, CodingKey {
        case sensitivity, action
        case mlUrl = "ml_url"
        case mlToken = "ml_token"
        case serverUrl = "server_url"
    }
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
                    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
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
        // never from URLCache: the server sends no cache headers and lists like /api/printers change with every save
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
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
        // cloud: a 401 means the session ran out (or was logged out elsewhere), not a wrong pairing token
        let message = status == 401 && server.isCloud ? l10n(.errSession) : friendlyError(l10n, status: status, detail: detail)
        return APIError(message: message, status: status, detail: detail)
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

    // MARK: power through Home Assistant (server 0.12.0)

    func power(printer: String) async throws -> PowerInfo {
        try await request("/api/printers/\(enc(printer))/power", timeout: 20)
    }

    /// Switching off is refused by the server while a print runs (409). Never repeated automatically.
    func setPower(printer: String, on: Bool) async throws {
        let _: Ack = try await request("/api/printers/\(enc(printer))/power", method: "POST", body: PowerBody(on: on),
                                       timeout: 20)
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
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
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

    /// Import a public bundle shared on cloud.orcaslicer.com (server 0.18.0) - no Orca account needed.
    func importOrcaCloud(link: String) async throws -> OrcaCloudImport {
        try await request("/api/profiles/orca-cloud", method: "POST", body: LinkBody(link: link), timeout: 60)
    }

    // MARK: SpoolmanDB filament presets (server 0.19.0)

    func filamentBrands() async throws -> [FilamentBrand] { try await request("/api/filament-db/brands", timeout: 60) }

    func filamentPresets(brand: String) async throws -> [FilamentPreset] {
        try await request("/api/filament-db/filaments?brand=\(enc(brand))", timeout: 60)
    }

    // MARK: own Manyfold library (server 0.21.0, own servers only)

    func manyfoldConfig() async throws -> ManyfoldConfig { try await request("/api/manyfold/config") }

    /// `token` nil = keep the stored key. The server checks the connection before saving.
    func setManyfold(url: String, token: String?) async throws -> ManyfoldConfig {
        try await request("/api/manyfold/config", method: "PUT", body: ManyfoldBody(url: url, token: token), timeout: 60)
    }

    func removeManyfold() async throws -> ManyfoldConfig {
        try await request("/api/manyfold/config", method: "DELETE")
    }

    /// Images the server serves itself (Manyfold previews, "/api/…"): full address with the key, as image views can't
    /// send headers. Other addresses are returned as they are.
    func imageURL(_ u: String) async -> URL? {
        guard u.hasPrefix("/api/") else { return URL(string: u) }
        let sep = u.contains("?") ? "&" : "?"
        return URL(string: "\(await base())\(u)\(sep)token=\(enc(server.token))")
    }

    // MARK: AI failure detection (server 0.23.0, own servers only)

    func failureConfig() async throws -> FailureConfig { try await request("/api/failure-detection/config") }

    /// `mlToken` nil = keep the stored token. Saved only after the ML API checked a test frame.
    func setFailureConfig(mlUrl: String, mlToken: String?, serverUrl: String, sensitivity: String,
                          action: String) async throws -> FailureConfig {
        try await request("/api/failure-detection/config", method: "PUT",
                          body: FailureBody(mlUrl: mlUrl, mlToken: mlToken, serverUrl: serverUrl,
                                            sensitivity: sensitivity, action: action), timeout: 90)
    }

    func removeFailureConfig() async throws -> FailureConfig {
        try await request("/api/failure-detection/config", method: "DELETE")
    }

    /// "False alarm": no more alerts for this print.
    func muteWatch(printer: String) async throws -> WatchState {
        try await request("/api/printers/\(enc(printer))/watch/mute", method: "POST")
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
    func send(job id: String, start: Bool, leveling: Bool? = nil, lanes: [Int: Int]? = nil, spoolId: Int? = nil,
              timelapse: Bool? = nil) async throws {
        var mapping: [String: Int]?
        if let lanes, !lanes.isEmpty {
            mapping = Dictionary(uniqueKeysWithValues: lanes.map { (String($0.key), $0.value) })
        }
        let _: Ack = try await request("/api/jobs/\(enc(id))/send", method: "POST",
                                       body: SendBody(start: start, confirm: start, leveling: start ? leveling : nil,
                                                      lanes: mapping, spoolId: start ? spoolId : nil,
                                                      timelapse: start ? timelapse : nil))
    }

    /// Own server (0.37.0): record every print with a camera, also prints started on the printer itself.
    func timelapseConfig() async throws -> TimelapseConfig { try await request("/api/timelapse/config") }

    func setTimelapseConfig(always: Bool) async throws -> TimelapseConfig {
        try await request("/api/timelapse/config", method: "PUT", body: TimelapseConfig(always: always))
    }

    /// Cloud: the phone sent the G-code itself on the Wi-Fi; the server follows the print from now on (0.33.0).
    /// `file` = the name on the printer.
    func markRelayed(job id: String, start: Bool, file: String) async throws {
        let _: Ack = try await request("/api/jobs/\(enc(id))/relayed", method: "POST", body: RelayedBody(start: start, file: file))
    }

    /// Cloud: statuses of printers the phone reaches on its Wi-Fi (nil = not reachable), so started jobs learn that
    /// they finished (0.33.0).
    func observe(_ statuses: [String: PrinterStatus?]) async throws {
        let _: Ack = try await request("/api/observe", method: "POST", body: ObserveBody(statuses: statuses))
    }

    /// The time-lapse video (MP4) of a job (server 0.32.0); players can't send headers, so the key goes into the URL.
    func timelapseURL(job id: String) async -> URL? {
        URL(string: "\(await base())/api/jobs/\(enc(id))/timelapse?token=\(enc(server.token))")
    }

    /// The time-lapse into a temporary file, for the share sheet.
    func downloadTimelapse(job id: String, name: String) async throws -> URL {
        try await download("/api/jobs/\(enc(id))/timelapse", folder: "timelapse-\(id)", name: name)
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

    /// Download the sliced G-code (SL-10) into a temporary file named like the model, for the share sheet - or, in the
    /// cloud, to send it to the printer. `lanes` = AFC slot per model colour; the server maps the tools in the copy.
    func downloadGcode(job id: String, name: String, lanes: [Int: Int]? = nil) async throws -> URL {
        try await download(Self.gcodePath(job: id, lanes: lanes), folder: "gcode-\(id)", name: name)
    }

    static func gcodePath(job id: String, lanes: [Int: Int]?) -> String {
        var path = "/api/jobs/\(id.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? id)/gcode"
        if let lanes, !lanes.isEmpty {
            let mapping = Dictionary(uniqueKeysWithValues: lanes.map { (String($0.key), $0.value) })
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            if let data = try? encoder.encode(mapping), let json = String(data: data, encoding: .utf8) {
                path += "?lanes=" + (json.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? json)
            }
        }
        return path
    }

    // MARK: cloud account (server 0.15.0, docs/API.md "Cloud accounts")

    func me() async throws -> Me { try await request("/api/auth/me") }

    /// OrcaSlicer printer models for the model choice (server 0.15.3, ~1000 entries).
    func machines() async throws -> [Machine] { try await request("/api/machines", timeout: 30) }

    func logout() async throws {
        let _: Ack = try await request("/api/auth/logout", method: "POST")
    }

    /// Deletes the account with all printers, profiles and jobs. Only after the user confirmed twice.
    func deleteAccount() async throws {
        let _: Ack = try await request("/api/auth/account?confirm=true", method: "DELETE")
    }

    func addPrinter(_ settings: PrinterSettings) async throws -> Printer {
        try await request("/api/printers", method: "POST", body: settings)
    }

    func updatePrinter(id: String, _ settings: PrinterSettings) async throws -> Printer {
        try await request("/api/printers/\(enc(id))", method: "PATCH", body: settings)
    }

    func deletePrinter(id: String) async throws {
        let _: Ack = try await request("/api/printers/\(enc(id))", method: "DELETE")
    }

    // MARK: send from OrcaSlicer (cloud, server 0.31.0)

    func orcaUpload(printer: String) async throws -> OrcaUpload {
        try await request("/api/printers/\(enc(printer))/orca-upload")
    }

    /// A new key (shown once); an older key of that printer stops working.
    func createOrcaUpload(printer: String) async throws -> OrcaUpload {
        try await request("/api/printers/\(enc(printer))/orca-upload", method: "POST")
    }

    func deleteOrcaUpload(printer: String) async throws {
        let _: Ack = try await request("/api/printers/\(enc(printer))/orca-upload", method: "DELETE")
    }

    // MARK: spool bookings in the account (cloud spools, server 0.29.0)

    func bookings() async throws -> ServerBookings { try await request("/api/bookings") }

    func createBooking(_ b: BookingRequest) async throws {
        let _: Ack = try await request("/api/bookings", method: "POST", body: b)
    }

    func observeBookings(_ statuses: [String: PrinterStatus?]) async throws -> ServerBookings {
        try await request("/api/bookings/observe", method: "POST", body: ObserveBody(statuses: statuses))
    }

    /// The user's decision on an open booking: `part` 0...1 of the filament (0 = nothing).
    func resolveBooking(id: String, part: Double) async throws {
        let _: Ack = try await request("/api/bookings/\(enc(id))/resolve", method: "POST", body: ResolveBody(part: part))
    }

    // MARK: bridges (cloud, server 0.24.0-0.26.0, docs/BRIDGE.md)

    func bridges() async throws -> [Bridge] { try await request("/api/bridges") }

    func pairBridge(code: String, name: String? = nil) async throws -> Bridge {
        try await request("/api/bridges/pair", method: "POST", body: PairBody(code: code, name: name))
    }

    func renameBridge(id: String, name: String) async throws -> Bridge {
        try await request("/api/bridges/\(enc(id))", method: "PATCH", body: NameBody(name: name))
    }

    func deleteBridge(id: String) async throws {
        let _: Ack = try await request("/api/bridges/\(enc(id))", method: "DELETE")
    }

    /// Printers the bridge finds on its home network.
    /// `subnet` ("192.168.86.0/24"): the phone's Wi-Fi when it is at home - a bridge in Docker's bridge network can't see
    /// the home network itself (server 0.35.1). Left out without one.
    func bridgeDiscover(id: String, subnet: String? = nil) async throws -> [FoundPrinter] {
        try await request("/api/bridges/\(enc(id))/discover", method: "POST", body: subnet.map { DiscoverBody(subnet: $0) },
                          timeout: 75)
    }

    /// A new printer behind the bridge; `sealed` = address and secrets sealed for the bridge (`Seal`).
    func bridgeAddPrinter(bridge id: String, _ printer: PrinterSettings, sealed: String) async throws -> Printer {
        try await request("/api/bridges/\(enc(id))/printers", method: "POST",
                          body: BridgePrinterBody(printer: printer, sealed: sealed), timeout: 40)
    }

    func bridgePrinterAccess(printer id: String, sealed: String) async throws {
        let _: Ack = try await request("/api/printers/\(enc(id))/bridge-access", method: "PUT", body: SealedBody(sealed: sealed))
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

/// Cloud login by e-mail code, before there is a session (`POST /api/auth/code`, `/api/auth/login`).
enum CloudAuth {
    struct CodeSent: Decodable, Sendable { var sent: Bool?; var email: String }
    struct Login: Decodable, Sendable {
        struct User: Decodable, Sendable { var id: String?; var email: String }
        var token: String
        var user: User
    }

    private struct CodeBody: Encodable { var email: String; var lang: String }
    private struct LoginBody: Encodable { var email: String; var code: String; var device: String }

    static func requestCode(email: String, l10n: L10n, base: String = Cloud.url,
                            session: URLSession = .shared) async throws -> CodeSent {
        try await post("/api/auth/code", CodeBody(email: email.trimmingCharacters(in: .whitespaces), lang: l10n.lang.rawValue),
                       l10n: l10n, base: base, session: session)
    }

    static func login(email: String, code: String, l10n: L10n, base: String = Cloud.url,
                      session: URLSession = .shared) async throws -> Login {
        try await post("/api/auth/login", LoginBody(email: email, code: code, device: "ios app"),
                       l10n: l10n, base: base, session: session)
    }

    private static func post<B: Encodable, R: Decodable>(_ path: String, _ body: B, l10n: L10n, base: String,
                                                         session: URLSession) async throws -> R {
        guard let url = URL(string: base + path) else {
            throw APIError(message: l10n(.errOffline), status: 0, detail: "bad URL")
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, res): (Data, URLResponse)
        do { (data, res) = try await session.data(for: req) } catch {
            throw APIError(message: l10n(.errOffline), status: 0, detail: "\(error)")
        }
        let status = (res as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var detail = "HTTP \(status)"
            if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let d = obj["detail"] as? String {
                detail = d
            }
            throw APIError(message: message(l10n, status: status, detail: detail), status: status, detail: detail)
        }
        do { return try JSONDecoder().decode(R.self, from: data) } catch {
            throw APIError(message: l10n(.errUnknown), status: status, detail: "\(error)")
        }
    }

    /// Same order as `cloudError` in the Expo app's api.ts.
    static func message(_ t: L10n, status: Int, detail: String) -> String {
        let d = detail.lowercased()
        if d.contains("valid e-mail") { return t(.errEmail) }
        if status == 429 { return t(.errTooManyCodes) }
        if d.contains("wrong code") { return t(.errWrongCode) }
        if d.contains("expired") { return t(.errCodeExpired) }
        if status == 502 { return t(.errMail) }
        return detail
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
