import Foundation

enum Pairing {
    /// Pairing QR code / deep link from `printshare pair`: printshare://connect?url=…&token=…&remote=…
    static func parse(_ data: String) -> Server? {
        let trimmed = data.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let m = trimmed.captures(#"^printshare:/+connect\?(.*)$"#, options: .caseInsensitive) else { return nil }
        // URLSearchParams semantics: '+' is a space, %XX is decoded, the first value of a name wins
        var params: [String: String] = [:]
        for pair in m[1].split(separator: "&", omittingEmptySubsequences: true) {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ s: Substring) -> String {
                let plain = s.replacingOccurrences(of: "+", with: " ")
                return plain.removingPercentEncoding ?? plain
            }
            let name = decode(kv[0])
            if params[name] == nil { params[name] = kv.count > 1 ? decode(kv[1]) : "" }
        }
        func value(_ name: String) -> String { params[name] ?? "" }
        let url = normalizeUrl(value("url"))
        let remote = normalizeUrl(value("remote"))
        guard !url.isEmpty else { return nil }
        return Server(url: url, token: value("token"), remoteUrl: remote.isEmpty ? nil : remote)
    }

    /// Throws APIError with a friendly message when neither address can be used.
    static func check(_ server: Server, _ l10n: L10n, session: URLSession = .shared,
                      cache: RouteCache = .shared) async throws -> Server {
        let remote = normalizeUrl(server.remoteUrl ?? "")
        let s = Server(url: normalizeUrl(server.url), token: server.token.trimmingCharacters(in: .whitespacesAndNewlines),
                       remoteUrl: remote.isEmpty ? nil : remote)
        _ = try await APIClient(server: s, l10n: l10n, session: session, cache: cache).info()
        return s
    }
}
