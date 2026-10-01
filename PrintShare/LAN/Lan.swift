import Foundation

// Printers the app reaches itself on the home Wi-Fi (cloud mode, server 0.15.0, docs/CLOUD.md step 1).
// Port of the Expo app's `lib/lan/`: the cloud slices, the phone sends the G-code to the printer.

enum SendStep: String, Sendable { case download, upload, start }

struct SendProgress: Sendable {
    var step: SendStep
    /// 0...1 of the upload.
    var part: Double
}

struct SendOptions: Sendable {
    var start: Bool
    /// Bed leveling before the print (SDCP only); nil = printer default.
    var leveling: Bool?
    var onStep: (@Sendable (SendStep) -> Void)?
    /// 0...1 of the upload.
    var onProgress: (@Sendable (Double) -> Void)?
}

/// What the app needs from a printer it talks to directly.
protocol LanPrinter: Sendable {
    func status() async throws -> PrinterStatus
    /// Upload `file` under `name`; with `options.start` the print starts (the caller asked for confirmation).
    func send(file: URL, name: String, options: SendOptions) async throws
    func control(_ action: String) async throws
    func close() async
}

struct LanError: Error, LocalizedError, Sendable, Equatable {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The printer has no Wi-Fi address on this phone yet.
struct NoLanAddress: Error, Sendable {}

/// How the app reaches one printer: address, plus the PrusaLink password or an API key (PrusaLink, OctoPrint,
/// Moonraker). Stored only on this phone, never sent to the cloud.
struct LanAccess: Codable, Sendable, Equatable {
    var address: String
    var password: String?
    var apiKey: String?

    enum CodingKeys: String, CodingKey { case address, password, apiKey }

    init(address: String, password: String? = nil, apiKey: String? = nil) {
        self.address = address; self.password = password; self.apiKey = apiKey
    }

    /// Builds 0.6.0 before server 0.15.3 stored the bare address string.
    init(from decoder: Decoder) throws {
        if let plain = try? decoder.singleValueContainer().decode(String.self) {
            self.init(address: plain)
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(address: c.lenient(String.self, .address) ?? "", password: c.lenient(String.self, .password),
                  apiKey: c.lenient(String.self, .apiKey))
    }

    /// Trimmed, empty fields dropped; nil when there is no address.
    var cleaned: LanAccess? {
        let a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty else { return nil }
        let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return LanAccess(address: a, password: (password ?? "").isEmpty ? nil : password, apiKey: key.isEmpty ? nil : key)
    }
}

enum Lan {
    /// Printer types the app can talk to directly (server 0.15.3).
    static let types = ["elegoo_sdcp", "moonraker", "prusalink", "octoprint"]

    static func canRelay(_ type: String) -> Bool { types.contains(type) }

    /// Host of an address the user typed: scheme and path dropped (`http://192.168.1.5/x` -> `192.168.1.5`).
    static func host(_ address: String) -> String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingRegex("^https?://", with: "")
            .replacingRegex("/.*$", with: "")
    }

    static func printer(type: String, access: LanAccess, session: URLSession = .shared) throws -> any LanPrinter {
        let address = access.address
        switch type {
        case "elegoo_sdcp": return SDCPPrinter(host: host(address).replacingRegex(":\\d+$", with: ""), session: session)
        case "moonraker": return MoonrakerPrinter(address: address, apiKey: access.apiKey, session: session)
        case "prusalink":
            return try PrusaLinkPrinter(address: address, password: access.password, apiKey: access.apiKey, session: session)
        case "octoprint": return try OctoPrintPrinter(address: address, apiKey: access.apiKey ?? "", session: session)
        default: throw LanError("printer type \(type) can't be reached from the app yet")
        }
    }

    /// `http://` + address without trailing slashes (PrusaLink, OctoPrint).
    static func baseURL(_ address: String) -> String {
        var a = address.trimmingCharacters(in: .whitespacesAndNewlines)
        while a.hasSuffix("/") { a.removeLast() }
        return a.matches("^https?://", options: .caseInsensitive) ? a : "http://\(a)"
    }

    /// Same buckets as the server's `api.printer_kind`, so the screens work alike at home and in the cloud.
    static func kind(_ state: String?) -> PrinterKind {
        let s = (state ?? "").lowercased()
        if s.isEmpty { return .unknown }
        if ["paused", "unloading_paused", "attention"].contains(s) { return .paused }
        if ["idle", "standby", "ready"].contains(s) { return .idle }
        if ["completed", "complete"].contains(s) { return .done }
        if ["stopped", "cancelled"].contains(s) { return .stopped }
        if ["error", "offline"].contains(s) { return .error }
        return .active
    }

    /// File name on the printer: model name + .gcode, plain characters (the Centauri's file list is picky).
    static func fileName(source: String?, job: String) -> String {
        var stem = ((source ?? "") as NSString).deletingPathExtension
        stem = stem.replacingRegex("[^A-Za-z0-9_.-]+", with: "_").replacingRegex("^_+|_+$", with: "")
        stem = String(stem.prefix(60))
        return "\(stem.isEmpty ? "print_\(job)" : stem).gcode"
    }

    static func randomHex(_ bytes: Int = 16) -> String {
        (0..<bytes).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }
}

/// multipart/form-data bodies for the printers' upload endpoints.
enum Multipart {
    static func boundary() -> String { "----PocketPrint3D\(Lan.randomHex(12))" }

    static func head(boundary: String, fields: [(String, String)], fileField: String, fileName: String) -> Data {
        var out = ""
        for (k, v) in fields {
            out += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n"
        }
        let safe = fileName.replacingOccurrences(of: "\"", with: "_")
        out += "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(safe)\"\r\n"
        out += "Content-Type: application/octet-stream\r\n\r\n"
        return Data(out.utf8)
    }

    static func tail(boundary: String) -> Data { Data("\r\n--\(boundary)--\r\n".utf8) }

    /// The whole body in memory (SDCP chunks are 1 MB at most).
    static func body(boundary: String, fields: [(String, String)], fileField: String, fileName: String, data: Data) -> Data {
        var out = head(boundary: boundary, fields: fields, fileField: fileField, fileName: fileName)
        out.append(data)
        out.append(tail(boundary: boundary))
        return out
    }

    /// The body as a temporary file, so a large G-code is streamed from disk.
    static func file(boundary: String, fields: [(String, String)], fileField: String, fileName: String,
                     source: URL) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("multipart-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let out = try FileHandle(forWritingTo: url)
        defer { try? out.close() }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        try out.write(contentsOf: head(boundary: boundary, fields: fields, fileField: fileField, fileName: fileName))
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try out.write(contentsOf: chunk) }
        try out.write(contentsOf: tail(boundary: boundary))
        return url
    }
}

/// Reports how much of an upload body was sent.
final class UploadProgress: NSObject, URLSessionTaskDelegate, Sendable {
    private let report: @Sendable (Int64, Int64) -> Void

    init(_ report: @escaping @Sendable (Int64, Int64) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        report(totalBytesSent, totalBytesExpectedToSend)
    }
}
