import Foundation

/// What an incoming `printshare://` URL asks for.
enum DeepLink: Equatable {
    /// `printshare://connect?url=…&token=…&remote=…`
    case connect(Server)
    /// `printshare://share` - the share extension left something in the shared inbox.
    case share
    case other

    static func parse(_ url: URL) -> DeepLink {
        if let server = Pairing.parse(url.absoluteString) { return .connect(server) }
        if url.scheme?.lowercased() == "printshare", url.host?.lowercased() == "share" { return .share }
        return .other
    }
}
