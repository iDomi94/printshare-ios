import XCTest
@testable import PrintShare

/// Server 0.11-0.13: printer power through Home Assistant (#9) and own quality/material presets (#7).
/// Shapes from the server's `docs/API.md` and `printshare/api.py` (upstream 509c409).
final class ServerThirteenTests: XCTestCase {
    private let l = L10n(lang: .en)

    private func client() -> APIClient {
        APIClient(server: Server(url: "http://home.test:8484", token: "tok"), l10n: l, session: StubProtocol.session(),
                  cache: RouteCache())
    }

    func testPrinterPowerFlag() throws {
        let json = #"""
        [{"id": "centauri", "name": "Centauri Carbon", "type": "elegoo_sdcp",
          "machine": "Elegoo Centauri Carbon 0.4 nozzle", "leveling": true, "power": true},
         {"id": "cosmos", "name": "COSMOS", "type": "moonraker", "machine": "Elegoo Centauri Carbon 0.4 nozzle",
          "leveling": null}]
        """#
        let list = try JSONDecoder().decode([Printer].self, from: Data(json.utf8))
        XCTAssertEqual(list.map(\.power), [true, false])     // older servers send no flag
    }

    func testPowerInfo() throws {
        let none = try JSONDecoder().decode(PowerInfo.self, from: Data(#"{"available": false, "state": null}"#.utf8))
        XCTAssertEqual(none, PowerInfo(available: false))
        let on = try JSONDecoder().decode(PowerInfo.self,
                                          from: Data(#"{"available": true, "state": "on", "error": null}"#.utf8))
        XCTAssertEqual(on.state, "on")
        XCTAssertEqual(l.powerState("unavailable"), "unreachable")
        XCTAssertEqual(l.powerState("weird"), "weird")
    }

    func testOwnPresetsInOptions() throws {
        var dict = try XCTUnwrap(JSONSerialization.jsonObject(with: Fixture.data("options")) as? [String: Any])
        XCTAssertNil(try JSONDecoder().decode(Options.self, from: JSONSerialization.data(withJSONObject: dict)).own)
        dict["own"] = ["materials": ["My PLA"], "processes": []]
        let opts = try JSONDecoder().decode(Options.self, from: JSONSerialization.data(withJSONObject: dict))
        XCTAssertEqual(opts.own, OwnPresets(materials: ["My PLA"], processes: []))
        XCTAssertEqual(l.profileKind("filament"), "Material")
    }

    func testPowerSwitchBodyAndNoRepeat() async throws {
        var seen: [URLRequest] = []
        let lock = NSLock()
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            if req.httpMethod == "POST" {
                return StubResponse(status: 409, body: Data(#"{"detail":"a print is running"}"#.utf8))
            }
            return StubResponse(body: Data(#"{"available": true, "state": "off", "error": null}"#.utf8))
        }
        let api = client()
        let info = try await api.power(printer: "cc")
        XCTAssertEqual(info.state, "off")
        do {
            try await api.setPower(printer: "cc", on: false)
            XCTFail("expected 409")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 409)
        }
        XCTAssertEqual(seen.count, 2)                          // the refused POST is not sent again
        XCTAssertEqual(seen[1].url?.path, "/api/printers/cc/power")
        let body = try XCTUnwrap(bodyData(seen[1]))
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: Bool], ["on": false])
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
}
