import CryptoKit
import XCTest
@testable import PrintShare

/// Server 0.24.0-0.27.0: bridges at home (print from anywhere). Shapes from the server's `docs/API.md` section "Bridges"
/// and `printshare/bridge/seal.py` (upstream 80fe375).
final class BridgeTests: XCTestCase {
    private let l = L10n(lang: .en)

    private func cloudClient() -> APIClient {
        APIClient(server: Server(url: "https://cloud.test", token: "pp3d_x", cloud: true, email: "a@b.de"), l10n: l,
                  session: StubProtocol.session(), cache: RouteCache())
    }

    private func bodyData(_ req: URLRequest) -> Data? {
        if let d = req.httpBody { return d }
        guard let stream = req.httpBodyStream else { return nil }
        stream.open(); defer { stream.close() }
        var buf = [UInt8](repeating: 0, count: 4096)
        var out = Data()
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            out.append(buf, count: n)
        }
        return out
    }

    // MARK: sealing

    // Produced by the server's own `printshare.bridge.seal.seal` for the bridge key below, so Swift must open what Python sealed.
    private let bridgePrivate = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA="
    private let bridgePublic = "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw="
    private let pythonBlob = "iAwP/FtJ1DXkT3SPoHHq5luBnz9LTeOklIcqtMezqQd6FO/5hmXIoZ4ucjfd2ebt14Y0pe6ob6NDmuYKaFkkBCZYYnQ0NCQbUm7DYZTA2mDM1EW8Hm0qjKSlrin2OPW5BqRENInxAQD+OwJww7cJH67Q"

    private func key() throws -> Curve25519.KeyAgreement.PrivateKey {
        try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: XCTUnwrap(Data(base64Encoded: bridgePrivate)))
    }

    func testBridgeKeyMatchesItsPublicKey() throws {
        XCTAssertEqual(try key().publicKey.rawRepresentation.base64EncodedString(), bridgePublic)
    }

    func testSwiftOpensWhatTheServerSealed() throws {
        let s = try Seal.unseal(privateKey: key(), blob: pythonBlob)
        XCTAssertEqual(s, Seal.Secrets(address: "192.168.1.50", password: "geheim", apiKey: "k1"))
    }

    func testSealRoundTripAndFreshKeyEveryTime() throws {
        let secrets = Seal.Secrets(address: "octopi.local", password: nil, apiKey: "abc")
        let a = try Seal.seal(publicKey: bridgePublic, secrets: secrets)
        let b = try Seal.seal(publicKey: bridgePublic, secrets: secrets)
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(try Seal.unseal(privateKey: key(), blob: a), secrets)
        // 32 bytes ephemeral key + JSON + 16 bytes tag
        XCTAssertGreaterThan(Data(base64Encoded: a)?.count ?? 0, 48)
    }

    func testSealedBlobIsTiedToTheBridgeKey() throws {
        let blob = try Seal.seal(publicKey: bridgePublic, secrets: Seal.Secrets(address: "1.2.3.4"))
        let other = Curve25519.KeyAgreement.PrivateKey()
        XCTAssertThrowsError(try Seal.unseal(privateKey: other, blob: blob))
    }

    func testSealRefusesAMissingOrBrokenKey() {
        XCTAssertThrowsError(try Seal.seal(publicKey: "", secrets: Seal.Secrets(address: "x")))
        XCTAssertThrowsError(try Seal.seal(publicKey: "AAAA", secrets: Seal.Secrets(address: "x")))
    }

    func testSecretsUseTheServersFieldNames() throws {
        let data = try JSONEncoder().encode(Seal.Secrets(address: "a", password: "p", apiKey: "k"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["address", "password", "api_key"])
    }

    // MARK: models

    func testPrinterBehindABridge() throws {
        let p = try JSONDecoder().decode(Printer.self, from: Data(#"""
        {"id": "voron-3f2a", "name": "Voron", "type": "moonraker", "machine": "", "bridge": "b-1"}
        """#.utf8))
        XCTAssertEqual(p.bridge, "b-1")
        XCTAssertTrue(p.viaServer(cloud: true))
        let plain = try JSONDecoder().decode(Printer.self, from: Data(#"{"id": "p1", "name": "CC", "bridge": null}"#.utf8))
        XCTAssertNil(plain.bridge)
        XCTAssertFalse(plain.viaServer(cloud: true))     // the phone talks to it on the Wi-Fi
        XCTAssertTrue(plain.viaServer(cloud: false))     // own server: always through the server
        let old = try JSONDecoder().decode(Printer.self, from: Data(#"{"id": "p1", "name": "CC"}"#.utf8))
        XCTAssertNil(old.bridge)
    }

    func testBridgeList() throws {
        let list = try JSONDecoder().decode([Bridge].self, from: Data(#"""
        [{"id": "b-1", "name": "Tower", "version": "0.27.0", "public_key": "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=",
          "created": 1790000000, "last_seen": 1790000500.5, "online": true, "connected": 1790000400,
          "printers": [{"id": "cc", "name": "Centauri", "type": "elegoo_sdcp", "machine": "x", "capabilities": {}}]},
         {"id": "b-2", "name": "Pi", "version": null, "public_key": null, "last_seen": null, "online": false, "printers": []}]
        """#.utf8))
        XCTAssertEqual(list.count, 2)
        XCTAssertTrue(list[0].online)
        XCTAssertEqual(list[0].publicKey, bridgePublic)
        XCTAssertEqual(list[0].printers.map(\.id), ["cc"])
        XCTAssertEqual(list[0].printers.first?.type, "elegoo_sdcp")
        XCTAssertNil(list[1].publicKey)
        XCTAssertNil(list[1].lastSeen)
        XCTAssertFalse(list[1].online)
    }

    func testFoundPrinters() throws {
        let list = try JSONDecoder().decode([BridgeFound].self, from: Data(#"""
        [{"type": "moonraker", "address": "192.168.1.20", "name": "COSMOS", "cosmos": true, "detail": "Elegoo", "added": false},
         {"type": "elegoo_sdcp", "address": "192.168.1.21", "name": "CC", "added": true}]
        """#.utf8))
        XCTAssertTrue(list[0].cosmos)
        XCTAssertFalse(list[1].cosmos)
        XCTAssertTrue(list[1].added)
        XCTAssertNotEqual(list[0].id, list[1].id)
    }

    // MARK: requests

    func testPairingCodeTypingFormat() {
        XCTAssertEqual(BridgeCode.format("k7q4m2zx"), "K7Q4-M2ZX")
        XCTAssertEqual(BridgeCode.format("K7Q4 M2ZX"), "K7Q4-M2ZX")
        XCTAssertEqual(BridgeCode.format("k7q"), "K7Q")
        XCTAssertEqual(BridgeCode.format("k7q4m2zx99"), "K7Q4-M2ZX")
        XCTAssertEqual(BridgeCode.format(""), "")
    }

    func testBridgeRequestShapes() async throws {
        var seen: [URLRequest] = []
        let lock = NSLock()
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            switch req.url?.path ?? "" {
            case "/api/bridges": return StubResponse(body: Data("[]".utf8))
            case "/api/bridges/pair", "/api/bridges/b-1/printers":
                return StubResponse(body: Data(#"{"id": "b-1", "name": "Tower", "type": "moonraker"}"#.utf8))
            case "/api/bridges/b-1/discover": return StubResponse(body: Data("[]".utf8))
            default: return StubResponse(body: Data(#"{"ok": true}"#.utf8))
            }
        }
        let api = cloudClient()
        _ = try await api.bridges()
        _ = try await api.pairBridge(code: "K7Q4-M2ZX")
        _ = try await api.bridgeDiscover(id: "b-1")
        _ = try await api.bridgeAddPrinter(bridge: "b-1", PrinterSettings(name: "Voron", type: "moonraker", cosmos: false),
                                           sealed: "BLOB")
        try await api.bridgePrinterAccess(printer: "voron-3f2a", sealed: "BLOB2")
        try await api.deleteBridge(id: "b-1")
        XCTAssertEqual(seen.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, [
            "GET /api/bridges", "POST /api/bridges/pair", "POST /api/bridges/b-1/discover",
            "POST /api/bridges/b-1/printers", "PUT /api/printers/voron-3f2a/bridge-access", "DELETE /api/bridges/b-1"])
        let pair = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(bodyData(seen[1]))) as? [String: Any])
        XCTAssertEqual(pair["code"] as? String, "K7Q4-M2ZX")
        let add = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(bodyData(seen[3]))) as? [String: Any])
        XCTAssertEqual(add["sealed"] as? String, "BLOB")
        let printer = try XCTUnwrap(add["printer"] as? [String: Any])
        XCTAssertEqual(printer["name"] as? String, "Voron")
        XCTAssertEqual(printer["type"] as? String, "moonraker")
        XCTAssertNil(printer["address"])                     // address and secrets only ever travel sealed
        XCTAssertNil(add["address"])
        let access = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(bodyData(seen[4]))) as? [String: Any])
        XCTAssertEqual(access["sealed"] as? String, "BLOB2")
    }

    func testBridgePostsAreNeverRepeated() async {
        StubProtocol.install { _ in StubResponse(error: URLError(.timedOut)) }
        do { _ = try await cloudClient().pairBridge(code: "K7Q4-M2ZX"); XCTFail("expected a timeout") } catch {}
        XCTAssertEqual(StubProtocol.requests.filter { $0.method == "POST" }.count, 1)
    }

    // MARK: error texts

    func testBridgeErrorTexts() {
        func check(_ status: Int, _ detail: String, _ key: L10nKey) {
            XCTAssertEqual(friendlyError(l, status: status, detail: detail), l(key), detail)
        }
        check(503, "the bridge is offline - is it running at home?", .errBridgeOffline)
        check(503, "the bridge went offline", .errBridgeOffline)
        check(503, "the bridge was removed", .errBridgeOffline)
        check(503, "the bridge connection broke (ConnectionClosed)", .errBridgeOffline)
        check(504, "the bridge didn't answer in time", .errBridgeTimeout)
        check(404, "unknown or expired code - the bridge shows a new one after 10 minutes", .errBridgeCode)
        check(400, "this printer is set up on the server at home itself - remove it there", .errBridgeServerPrinter)
    }
}
