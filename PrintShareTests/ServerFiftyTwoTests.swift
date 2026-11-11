import XCTest
@testable import PrintShare

/// Server 0.53.0: the smart plug is set up in the apps (before only on the classic web page). Shapes from the server's
/// `docs/API.md` (`/api/printers/<id>/power/config|test|entities`, unchanged since 0.12.0 / 0.46.0).
final class ServerFiftyTwoTests: XCTestCase {
    private func client() -> APIClient {
        APIClient(server: Server(url: "http://home.test:8484", token: "tok"), l10n: L10n(lang: .en),
                  session: StubProtocol.session(), cache: RouteCache())
    }

    func testPowerConfigDecodes() throws {
        let set = try JSONDecoder().decode(PowerConfig.self, from: Data(#"""
        {"configured": true, "addon": false, "type": "homeassistant", "url": "http://ha:8123", "entity": "switch.drucker",
         "token_set": true, "supervisor": false, "auto_on": true}
        """#.utf8))
        XCTAssertEqual(set, PowerConfig(configured: true, url: "http://ha:8123", entity: "switch.drucker", tokenSet: true,
                                        autoOn: true))
        // nothing set up yet: the server sends the empty defaults (older servers without auto_on too)
        let none = try JSONDecoder().decode(PowerConfig.self, from: Data(#"""
        {"configured": false, "addon": true, "type": "homeassistant", "url": "", "entity": "", "token_set": false,
         "supervisor": true}
        """#.utf8))
        XCTAssertFalse(none.configured)
        XCTAssertTrue(none.addon)
        XCTAssertFalse(none.autoOn)
        let list = try JSONDecoder().decode([PowerEntity].self, from: Data(#"""
        [{"entity": "switch.drucker", "name": "Drucker-Steckdose", "state": "off"},
         {"entity": "light.werkstatt", "name": "Werkstatt", "state": null}]
        """#.utf8))
        XCTAssertEqual(list.map(\.id), ["switch.drucker", "light.werkstatt"])
        let bad = try JSONDecoder().decode(PowerTest.self, from: Data(#"{"ok": false, "error": "401 Unauthorized"}"#.utf8))
        XCTAssertFalse(bad.ok)
        XCTAssertEqual(bad.error, "401 Unauthorized")
    }

    func testPowerSettingsRequests() async throws {
        let lock = NSLock()
        var seen: [URLRequest] = []
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            switch req.url?.path {
            case "/api/printers/cos/power/entities": return StubResponse(body: Data("[]".utf8))
            case "/api/printers/cos/power/test": return StubResponse(body: Data(#"{"ok": true, "state": "on", "name": "P"}"#.utf8))
            default: return StubResponse(body: Data(#"{"configured": true, "url": "", "entity": "switch.p", "token_set": true}"#.utf8))
            }
        }
        let api = client()
        // empty token = keep the stored one: left out of the body
        let keep = PowerSettingsBody(url: "http://ha:8123", entity: "switch.p", token: nil, autoOn: true)
        _ = try await api.setPowerConfig(printer: "cos", keep)
        _ = try await api.testPower(printer: "cos", PowerSettingsBody(url: "", entity: "switch.p", token: "new", autoOn: false))
        _ = try await api.powerEntities(printer: "cos", keep)
        _ = try await api.deletePowerConfig(printer: "cos")
        let r = lock.withLock { seen }
        XCTAssertEqual(r.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, [
            "PUT /api/printers/cos/power/config", "POST /api/printers/cos/power/test",
            "POST /api/printers/cos/power/entities", "DELETE /api/printers/cos/power/config"])
        let put = try XCTUnwrap(body(r[0]))
        XCTAssertNil(put["token"])
        XCTAssertEqual(put["auto_on"] as? Bool, true)
        XCTAssertEqual(put["entity"] as? String, "switch.p")
        let test = try XCTUnwrap(body(r[1]))
        XCTAssertEqual(test["token"] as? String, "new")
        XCTAssertEqual(test["auto_on"] as? Bool, false)
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
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
