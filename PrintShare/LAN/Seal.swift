import CryptoKit
import Foundation

/// Printer secrets sealed for one bridge, scheme "pp3d-seal-v1" (server 0.24: docs/BRIDGE.md section 7,
/// `printshare/bridge/seal.py`; Expo app `lib/seal.ts`). The cloud passes the blob on without being able to read it:
///   ephemeral X25519 key e → shared = X25519(e, bridge public key)
///   key = HKDF-SHA256(shared, salt = e.public ‖ bridge public key, info = "pp3d-seal-v1", 32 bytes)
///   blob = base64(e.public ‖ ChaCha20-Poly1305(key, nonce = 12 zero bytes, JSON))
/// A zero nonce is safe here because every key is used exactly once (fresh ephemeral key per blob).
enum Seal {
    static let info = Data("pp3d-seal-v1".utf8)

    struct Secrets: Codable, Sendable, Equatable {
        var address: String?
        var password: String?
        var apiKey: String?
        /// Own camera of the printer (RTSP / HTTP, server 0.36.0); "" removes it. Carries a password, so it is sealed too.
        var cameraUrl: String?

        enum CodingKeys: String, CodingKey { case address, password, apiKey = "api_key", cameraUrl = "camera_url" }

        var isEmpty: Bool { address == nil && password == nil && apiKey == nil && cameraUrl == nil }
    }

    struct NoKey: Error, Sendable {}

    static func key(shared: SharedSecret, ephemeral: Data, bridge: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral + bridge, sharedInfo: info, outputByteCount: 32)
    }

    /// Seal `secrets` for the bridge with this public key (base64, 32 bytes).
    static func seal(publicKey: String, _ secrets: Secrets) throws -> String {
        guard let pk = Data(base64Encoded: publicKey), pk.count == 32 else { throw NoKey() }
        let bridge = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: pk)
        let e = Curve25519.KeyAgreement.PrivateKey()
        let epk = e.publicKey.rawRepresentation
        let shared = try e.sharedSecretFromKeyAgreement(with: bridge)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let box = try ChaChaPoly.seal(try enc.encode(secrets), using: key(shared: shared, ephemeral: epk, bridge: pk),
                                      nonce: ChaChaPoly.Nonce(data: Data(count: 12)))
        return (epk + box.ciphertext + box.tag).base64EncodedString()
    }

    /// The bridge's side (tests): open a blob with the bridge's private key.
    static func open(_ blob: String, privateKey: Curve25519.KeyAgreement.PrivateKey) throws -> Secrets {
        guard let raw = Data(base64Encoded: blob), raw.count >= 32 + 16 else { throw NoKey() }
        let epk = raw.prefix(32)
        let body = raw.dropFirst(32)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: epk))
        let k = key(shared: shared, ephemeral: Data(epk), bridge: privateKey.publicKey.rawRepresentation)
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: Data(count: 12)),
                                           ciphertext: body.dropLast(16), tag: body.suffix(16))
        return try JSONDecoder().decode(Secrets.self, from: try ChaChaPoly.open(box, using: k))
    }
}
