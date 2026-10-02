import Foundation

// Spoolman (spec MA-07, server 0.16.0): choose the spool per colour, check what's left, book the used filament after
// the print. Port of the Expo app's `lib/spoolman.ts`. The app talks to Spoolman itself on the home Wi-Fi (like to the
// printers in cloud mode); the address stays on this phone. Printers whose Moonraker has its own [spoolman] link book
// the filament themselves (status `spoolman`). API: https://donkie.github.io/Spoolman/
// Cloud accounts without a Spoolman at home keep their spools in the PocketPrint3D cloud instead (server 0.17.0): the
// same API under `<cloud>/spoolman` with the session token; creating/editing spools is PocketPrint3D's own shape.

struct Spool: Sendable, Equatable, Identifiable, Hashable {
    var id: Int
    var name: String
    var vendor: String?
    var material: String?
    /// `#RRGGBB`
    var color: String?
    var remainingG: Double?
    var location: String?
    /// for editing cloud spools
    var filamentG: Double?
    var initialG: Double?
    var comment: String?
    var archived = false

    init(id: Int, name: String = "", vendor: String? = nil, material: String? = nil, color: String? = nil,
         remainingG: Double? = nil, location: String? = nil) {
        self.id = id; self.name = name; self.vendor = vendor; self.material = material; self.color = color
        self.remainingG = remainingG; self.location = location
    }

    /// A spool object as Spoolman (or the cloud) sends it.
    init?(json s: [String: Any]) {
        guard let id = SDCPPrinter.int(s["id"]) else { return nil }
        let f = s["filament"] as? [String: Any] ?? [:]
        let rawColor = (f["color_hex"] as? String) ?? (f["multi_color_hexes"] as? String) ?? ""
        let hex = (rawColor.split(separator: ",").first.map(String.init) ?? "").replacingOccurrences(of: "#", with: "")
        self.id = id
        name = f["name"] as? String ?? ""
        vendor = (f["vendor"] as? [String: Any])?["name"] as? String
        material = f["material"] as? String
        color = hex.matches("^[0-9A-Fa-f]{6}") ? "#" + hex.prefix(6).uppercased() : nil
        remainingG = Self.number(s["remaining_weight"])
        location = s["location"] as? String
        filamentG = Self.number(f["weight"])
        initialG = Self.number(s["initial_weight"])
        comment = s["comment"] as? String
        archived = (s["archived"] as? Bool) ?? false
    }

    private static func number(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue
    }

    /// "#3 Elegoo PLA Black"
    var label: String {
        ["#\(id)", vendor, name.isEmpty ? material : name].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// No filament left, but not archived yet: listed last.
    var isEmpty: Bool { (remainingG ?? 1) < 1 }
}

/// Create / change a spool in the PocketPrint3D cloud (not a real Spoolman: there a spool needs a filament id).
struct SpoolInput: Encodable, Sendable, Equatable {
    struct Filament: Encodable, Sendable, Equatable {
        var name: String?
        var vendor: String?
        var material: String?
        var colorHex: String?
        var weight: Double?

        enum CodingKeys: String, CodingKey {
            case name, vendor, material, weight
            case colorHex = "color_hex"
        }

        // empty fields are sent as null (cleared), like the Expo app
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(name, forKey: .name)
            try c.encode(vendor, forKey: .vendor)
            try c.encode(material, forKey: .material)
            try c.encode(colorHex, forKey: .colorHex)
            try c.encode(weight, forKey: .weight)
        }
    }

    var filament: Filament?
    /// Left out = unchanged; a value = weighed again.
    var remainingWeight: Double?
    var location: String?
    var comment: String?
    var archived: Bool?

    enum CodingKeys: String, CodingKey {
        case filament, location, comment, archived
        case remainingWeight = "remaining_weight"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(filament, forKey: .filament)
        try c.encodeIfPresent(remainingWeight, forKey: .remainingWeight)
        if filament != nil {
            try c.encode(location, forKey: .location)
            try c.encode(comment, forKey: .comment)
        }
        try c.encodeIfPresent(archived, forKey: .archived)
    }
}

struct SpoolmanError: Error, LocalizedError, Sendable, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The user's Spoolman, or the cloud account's spools (`Spoolman.cloudSetting`).
actor Spoolman {
    /// Stored instead of an address: the spools are kept in the PocketPrint3D cloud account.
    static let cloudSetting = "cloud"

    private var base: String?
    private let candidates: [String]
    private let headers: [String: String]
    private let session: URLSession

    init(address: String, headers: [String: String] = [:], session: URLSession = .shared) {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while a.hasSuffix("/") { a.removeLast() }
        a = a.replacingRegex("/api/v1$", with: "")
        let url = a.matches("^https?://", options: .caseInsensitive) ? a : "http://\(a)"
        // Spoolman listens on 7912 unless a port or a proxy path is given
        let rest = url.replacingRegex("^https?://", with: "")
        candidates = rest.matches(":\\d+(/|$)") || rest.contains("/") ? [url] : [url, "\(url):7912"]
        self.headers = headers
        self.session = session
    }

    /// The Spoolman behind a stored setting: the user's own server, or the cloud account's spools.
    static func open(server: Server, setting: String, session: URLSession = .shared) -> Spoolman {
        guard setting == cloudSetting else { return Spoolman(address: setting, session: session) }
        var url = server.url
        while url.hasSuffix("/") { url.removeLast() }
        return Spoolman(address: "\(url)/spoolman", headers: ["Authorization": "Bearer \(server.token)"], session: session)
    }

    nonisolated var addresses: [String] { candidates }

    private func request(_ method: String, _ url: String, body: Data? = nil, timeout: TimeInterval) throws -> URLRequest {
        guard let u = URL(string: url) else { throw SpoolmanError("Spoolman not reachable") }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData)
        req.httpMethod = method
        req.timeoutInterval = timeout
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    private func resolve() async throws -> String {
        if let base { return base }
        for candidate in candidates {
            guard let req = try? request("GET", "\(candidate)/api/v1/info", timeout: 5),
                  let answer = try? await session.data(for: req),
                  (answer.1 as? HTTPURLResponse)?.statusCode == 200,
                  let obj = (try? JSONSerialization.jsonObject(with: answer.0)) as? [String: Any], obj["version"] != nil
            else { continue }  // try the next one
            base = candidate
            return candidate
        }
        throw SpoolmanError("Spoolman not reachable")
    }

    private func call(_ method: String, _ path: String, body: (any Encodable)? = nil,
                      timeout: TimeInterval = 8) async throws -> (Data, Int) {
        let data = try body.map { try JSONEncoder().encode(AnySpoolBody($0)) }
        let root = try await resolve()
        let req = try request(method, "\(root)/api/v1\(path)", body: data, timeout: timeout)
        do {
            let (out, res) = try await session.data(for: req)
            return (out, (res as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw SpoolmanError("Spoolman not reachable")
        }
    }

    private func json(_ data: Data) -> Any? { try? JSONSerialization.jsonObject(with: data) }

    func info() async throws -> (version: String, base: String) {
        let (data, status) = try await call("GET", "/info")
        guard (200..<300).contains(status) else { throw SpoolmanError("Spoolman answered HTTP \(status)") }
        let v = (json(data) as? [String: Any])?["version"]
        return (v.map { "\($0)" } ?? "", base ?? "")
    }

    /// Spools that are not archived, recently used first; empty ones (0 g left, not archived yet) at the end.
    func spools(archived: Bool = false) async throws -> [Spool] {
        let (data, status) = try await call("GET", "/spool?allow_archived=\(archived)&sort=last_used:desc,id:asc")
        guard (200..<300).contains(status) else { throw SpoolmanError("Spoolman answered HTTP \(status)") }
        let list = (json(data) as? [[String: Any]] ?? []).compactMap(Spool.init(json:)).filter { archived || !$0.archived }
        return list.filter { !$0.isEmpty } + list.filter(\.isEmpty)
    }

    /// Book used filament (grams) on a spool.
    func use(spool id: Int, grams: Double) async throws {
        let (_, status) = try await call("PUT", "/spool/\(id)/use", body: ["use_weight": (grams * 10).rounded() / 10])
        if status == 404 { throw SpoolmanError("spool #\(id) no longer exists") }
        guard (200..<300).contains(status) else { throw SpoolmanError("Spoolman answered HTTP \(status)") }
    }

    // MARK: PocketPrint3D cloud spools only

    private func send(_ method: String, _ path: String, body: (any Encodable)? = nil) async throws -> [String: Any] {
        let (data, status) = try await call(method, path, body: body)
        guard (200..<300).contains(status) else {
            let detail = (json(data) as? [String: Any])?["detail"] as? String
            throw SpoolmanError(detail?.isEmpty == false ? detail! : "HTTP \(status)")
        }
        return json(data) as? [String: Any] ?? [:]
    }

    func create(_ spool: SpoolInput) async throws -> Spool? { Spool(json: try await send("POST", "/spool", body: spool)) }
    func update(_ id: Int, _ spool: SpoolInput) async throws -> Spool? {
        Spool(json: try await send("PATCH", "/spool/\(id)", body: spool))
    }
    func remove(_ id: Int) async throws { _ = try await send("DELETE", "/spool/\(id)") }
}

private struct AnySpoolBody: Encodable {
    private let encodeFn: (Encoder) throws -> Void
    init(_ value: any Encodable) { encodeFn = { try value.encode(to: $0) } }
    func encode(to encoder: Encoder) throws { try encodeFn(encoder) }
}
