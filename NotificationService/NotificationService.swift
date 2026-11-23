import UserNotifications

/// Decrypts the notification text the server encrypted with this phone's key (server 0.51.0). The push relay only
/// passes the blob on; without the key iOS shows the fallback text "push.fallback".
final class NotificationService: UNNotificationServiceExtension {
    override func didReceive(_ request: UNNotificationRequest,
                             withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        let content = (request.content.mutableCopy() as? UNMutableNotificationContent) ?? UNMutableNotificationContent()
        if let blob = request.content.userInfo["pp3d"] as? String, let key = PushShared.key(),
           let msg = PushPayload.open(blob, key: key) {
            content.title = msg.title
            content.body = msg.body
            content.userInfo = msg.userInfo
            if let printer = msg.printer { content.threadIdentifier = printer }
            let urls = msg.imageURLs(bases: msg.device.map(PushShared.serverURLs(device:)) ?? [])
            if !urls.isEmpty {
                // a camera picture (first layer, halfway, finished; server 0.54.0): try home, then away address
                let handler = Handler(contentHandler, content)
                self.handler = handler
                Self.download(urls[...]) { handler.deliver($0) }
                return
            }
        }
        contentHandler(content)
    }

    private var handler: Handler?

    /// Delivers the content once - with the picture after the download, or without it when time runs out.
    private final class Handler: @unchecked Sendable {
        private let lock = NSLock()
        private var done: ((UNNotificationContent) -> Void)?
        private let content: UNMutableNotificationContent

        init(_ done: @escaping (UNNotificationContent) -> Void, _ content: UNMutableNotificationContent) {
            self.done = done
            self.content = content
        }

        func deliver(_ picture: URL?) {
            lock.lock()
            let d = done
            done = nil
            lock.unlock()
            guard let d else { return }
            if let picture, let a = try? UNNotificationAttachment(identifier: "camera", url: picture) {
                content.attachments = [a]
            }
            d(content)
        }
    }

    /// The picture as a local .jpg file (attachments need a file); the addresses one after the other. Completion
    /// handlers instead of a Task: nothing non-Sendable crosses into it.
    private static func download(_ urls: ArraySlice<URL>, done: @escaping @Sendable (URL?) -> Void) {
        guard let url = urls.first else { return done(nil) }
        let rest = urls.dropFirst()
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        req.httpMethod = "GET"
        URLSession.shared.dataTask(with: req) { data, res, _ in
            if let data, !data.isEmpty, (res as? HTTPURLResponse)?.statusCode == 200 {
                let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                if (try? data.write(to: file)) != nil { return done(file) }
            }
            download(rest, done: done)
        }.resume()
    }

    override func serviceExtensionTimeWillExpire() {
        handler?.deliver(nil)
    }
}
