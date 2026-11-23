import Foundation

/// What an incoming `printshare://` URL asks for.
enum DeepLink: Equatable {
    /// `printshare://connect?url=…&token=…&remote=…`
    case connect(Server)
    /// `printshare://share` - the share extension left something in the shared inbox.
    case share
    /// `printshare://job?id=…` - a notification or the Live Activity (server 0.51.0).
    case job(String)
    /// `printshare://camera?printer=…` - the picture in the Live Activity (0.9.20).
    case camera(String)
    case other

    static func parse(_ url: URL) -> DeepLink {
        if let server = Pairing.parse(url.absoluteString) { return .connect(server) }
        if url.scheme?.lowercased() == "printshare", url.host?.lowercased() == "share" { return .share }
        if url.scheme?.lowercased() == "printshare", url.host?.lowercased() == "job",
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
           id.range(of: "^[A-Za-z0-9_-]{1,40}$", options: .regularExpression) != nil {
            return .job(id)
        }
        if url.scheme?.lowercased() == "printshare", url.host?.lowercased() == "camera",
           let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "printer" })?.value,
           id.range(of: "^[A-Za-z0-9_.:-]{1,64}$", options: .regularExpression) != nil {
            return .camera(id)
        }
        return .other
    }
}
