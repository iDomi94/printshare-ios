import XCTest
@testable import PrintShare

/// Server 0.35.0-0.36.0: Bambu Lab through a bridge, the phone's Wi-Fi as a search hint, own camera per printer.
/// Shapes from the server's `printshare/api.py` / `printers/bambu.py` and the Expo app (upstream a738200).
final class ServerThirtySixTests: XCTestCase {
    private func client() -> APIClient {
        APIClient(server: Server(url: "https://cloud.test", token: "tok", cloud: true, email: "a@b.de"), l10n: L10n(lang: .en),
                  session: StubProtocol.session(), cache: RouteCache())
    }

    private func body(_ req: URLRequest) -> [String: Any]? {
        var data = req.httpBody
        if data == nil, let stream = req.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            var out = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                out.append(buf, count: n)
            }
            data = out
        }
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    }

    func testBambuWorksThroughABridgeAndFromThePhone() throws {
        XCTAssertTrue(Lan.bridgeTypes.contains("bambu_lan"))
        XCTAssertTrue(Lan.types.contains("bambu_lan"))                  // the phone does MQTT + FTPS itself since 0.9.2
        let f = try JSONDecoder().decode(FoundPrinter.self, from: Data(#"""
        {"type": "bambu_lan", "address": "192.168.86.53", "name": "01P00A", "machine": "Bambu Lab P1S 0.4 nozzle", "added": false}
        """#.utf8))
        XCTAssertEqual(f.machine, "Bambu Lab P1S 0.4 nozzle")
        XCTAssertNil(try JSONDecoder().decode(FoundPrinter.self, from: Data(#"{"type": "moonraker", "address": "a"}"#.utf8)).machine)
        XCTAssertFalse(L10n(lang: .en).printerTypeName("bambu_lan").isEmpty)
    }

    func testOwnCameraIsSealedWithTheServersFieldName() throws {
        let data = try JSONEncoder().encode(Seal.Secrets(address: "a", cameraUrl: "rtsp://u:p@1.2.3.4/live"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["address", "camera_url"])
        // "" removes the camera on the bridge, so it is a real value and not "nothing to seal"
        let removal = Seal.Secrets(cameraUrl: "")
        XCTAssertFalse(removal.isEmpty)
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(removal)) as? [String: String])["camera_url"], "")
        XCTAssertTrue(Seal.Secrets().isEmpty)
    }

    func testCameraIsPartOfTheSealedSecretsOfTheForm() {
        let a = LanAccess(address: "192.168.1.5", password: "code", apiKey: nil)
        let s = CloudPrinterView.secrets(a, camera: " rtsp://u:p@1.2.3.4/live ")
        XCTAssertEqual(s.cameraUrl, "rtsp://u:p@1.2.3.4/live")
        XCTAssertNil(CloudPrinterView.secrets(a, camera: "  ").cameraUrl)
        XCTAssertNil(CloudPrinterView.secrets(a).cameraUrl)
    }

    func testDiscoverSendsThePhonesWifiAsAHint() async throws {
        let lock = NSLock()
        var seen: [URLRequest] = []
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            return StubResponse(body: Data("[]".utf8))
        }
        let api = client()
        _ = try await api.bridgeDiscover(id: "b-1", subnet: "192.168.86.0/24")
        _ = try await api.bridgeDiscover(id: "b-1")
        XCTAssertEqual(seen[0].url?.path, "/api/bridges/b-1/discover")
        XCTAssertEqual(body(seen[0])?["subnet"] as? String, "192.168.86.0/24")
        XCTAssertNil(body(seen[1]))
    }

    func testWifiSubnet() {
        XCTAssertEqual(Discovery.subnet(address: "192.168.86.23", prefix: 24), "192.168.86.0/24")
        XCTAssertEqual(Discovery.subnet(address: "192.168.86.130", prefix: 25), "192.168.86.128/25")
        XCTAssertEqual(Discovery.subnet(address: "10.1.2.3", prefix: 16), "10.1.2.0/24")     // wider than /24: searched as /24
        XCTAssertEqual(Discovery.subnet(address: "10.1.2.3", prefix: 0), "10.1.2.0/24")
        XCTAssertNil(Discovery.subnet(address: "fe80::1", prefix: 64))
        XCTAssertNil(Discovery.subnet(address: "300.1.2.3", prefix: 24))
    }
}
