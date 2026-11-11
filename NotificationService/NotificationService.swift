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
        }
        contentHandler(content)
    }

    override func serviceExtensionTimeWillExpire() {}
}
