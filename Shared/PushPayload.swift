import CryptoKit
import Foundation

/// The decrypted notification (server printshare/push/notify.py): ChaCha20-Poly1305, nonce + ciphertext + tag, base64.
struct PushPayload: Codable, Sendable, Equatable {
    var event: String
    var title: String
    var body: String
    var job: String?
    var printer: String?
    /// The phone's device id on the server (0.54.0).
    var device: String?
    /// Server-relative address of a camera picture (`/api/push/image/<token>.jpg`, server 0.54.0).
    var image: String?

    /// Full addresses of the picture on the server's home / away address; only the server's own image path.
    func imageURLs(bases: [String]) -> [URL] {
        guard let image, image.range(of: "^/api/push/image/[A-Za-z0-9_-]{16,64}\\.jpg$", options: .regularExpression) != nil
        else { return [] }
        return bases.compactMap { base in
            URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + image)
        }.filter { $0.scheme == "http" || $0.scheme == "https" }
    }

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
