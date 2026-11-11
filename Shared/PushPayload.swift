import CryptoKit
import Foundation

/// The decrypted notification (server printshare/push/notify.py): ChaCha20-Poly1305, nonce + ciphertext + tag, base64.
struct PushPayload: Codable, Sendable, Equatable {
    var event: String
    var title: String
    var body: String
    var job: String?
    var printer: String?

    static func open(_ blob: String, key: String) -> PushPayload? {
        guard let raw = Data(base64Encoded: blob), let keyData = Data(base64Encoded: key), keyData.count == 32,
              let box = try? ChaChaPoly.SealedBox(combined: raw),
              let plain = try? ChaChaPoly.open(box, using: SymmetricKey(data: keyData)) else { return nil }
        return try? JSONDecoder().decode(PushPayload.self, from: plain)
    }

    /// What the app needs when the notification is tapped (userInfo only takes plist types).
    var userInfo: [String: String] {
        var out = ["event": event]
        if let job, !job.isEmpty { out["job"] = job }
        if let printer, !printer.isEmpty { out["printer"] = printer }
        return out
    }
}
