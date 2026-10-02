import CryptoKit
import Foundation

/// Printer secrets sealed for one bridge, scheme "pp3d-seal-v1" (upstream docs/BRIDGE.md section 7, server side
/// `printshare/bridge/seal.py`, Expo app `lib/seal.ts`). The cloud passes the blob on without being able to read it:
///
///     ephemeral X25519 key e → shared = X25519(e, bridge public key)
///     key  = HKDF-SHA256(shared, salt = e.public ‖ bridge public key, info = "pp3d-seal-v1", 32 bytes)
///     blob = base64(e.public ‖ ChaCha20-Poly1305(key, nonce = 12 zero bytes, JSON) ‖ 16-byte tag)
///
/// The key is new for every message, so the fixed nonce is safe.
enum Seal {
    struct Failure: Error, LocalizedError, Equatable {
        var message: String
        var errorDescription: String? { message }
    }

    /// What the bridge needs to reach a printer. Only the fields the printer type uses are sent.
    struct Secrets: Codable, Sendable, Equatable {
        var address: String?
        var password: String?
        var apiKey: String?

        enum CodingKeys: String, CodingKey { case address, password, apiKey = "api_key" }
    }

    private static let info = Data("pp3d-seal-v1".utf8)

    /// `ephemeral` is only passed by tests (fixed key); the app always uses a fresh random key.
    static func seal(publicKey base64: String, secrets: Secrets,
                     ephemeral: Curve25519.KeyAgreement.PrivateKey = .init()) throws -> String {
        guard let raw = Data(base64Encoded: base64), raw.count == 32,
              let bridgeKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw) else {
            throw Failure(message: "the bridge has no valid key - update it")
        }
        let epk = ephemeral.publicKey.rawRepresentation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: bridgeKey)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: epk + raw, sharedInfo: info, outputByteCount: 32)
        let nonce = try ChaChaPoly.Nonce(data: Data(count: 12))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let box = try ChaChaPoly.seal(try encoder.encode(secrets), using: key, nonce: nonce)
        return (epk + box.ciphertext + box.tag).base64EncodedString()
    }

    /// The bridge's side - only used by the tests to prove both directions agree with the server's implementation.
    static func unseal(privateKey: Curve25519.KeyAgreement.PrivateKey, blob: String) throws -> Secrets {
        guard let raw = Data(base64Encoded: blob), raw.count > 32 + 16 else { throw Failure(message: "sealed data has the wrong size") }
        let epk = raw.prefix(32), rest = raw.dropFirst(32)
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: epk)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer)
        let key = shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(epk) + privateKey.publicKey.rawRepresentation,
                                                 sharedInfo: info, outputByteCount: 32)
        let box = try ChaChaPoly.SealedBox(nonce: ChaChaPoly.Nonce(data: Data(count: 12)),
                                           ciphertext: rest.dropLast(16), tag: rest.suffix(16))
        return try JSONDecoder().decode(Secrets.self, from: ChaChaPoly.open(box, using: key))
    }
}
