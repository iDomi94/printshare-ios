import XCTest
@testable import PrintShare

/// Server 0.42.0 (Orca Cloud account) and 0.43.0 / 0.44.0 (moving by hand, load / unload). Shapes from the server's
/// `docs/API.md`; the Motion JSON follows `printshare/motion.py` as the Android app reads it.
final class ServerFortyFourTests: XCTestCase {
    private func client() -> APIClient {
        APIClient(server: Server(url: "http://home.test:8484", token: "tok"), l10n: L10n(lang: .en),
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

    func testMotionDecodesCentauriAndBambu() throws {
        let cc = try JSONDecoder().decode(Motion.self, from: Data(#"""
        {"supported": true, "home": ["XYZ", "X", "Y", "Z"], "jog": {"axes": ["X", "Y", "Z"], "steps": [0.1, 1, 10, 100]},
         "extrude": false, "load": true, "unload": true, "motors_off": false, "macros": [],
         "filament_temp": true, "materials": [{"name": "PLA", "load_temp": 220}, {"name": "PETG", "load_temp": 250}],
         "filament_as_job": true}
        """#.utf8))
        XCTAssertTrue(cc.supported)
        XCTAssertEqual(cc.jog?.steps, [0.1, 1, 10, 100])
        XCTAssertEqual(cc.materials.map(\.loadTemp), [220, 250])
        XCTAssertTrue(cc.filamentAsJob)
        XCTAssertNil(cc.loadSlots)
        XCTAssertFalse(cc.isEmpty)

        let bambu = try JSONDecoder().decode(Motion.self, from: Data(#"""
        {"supported": true, "home": ["XYZ"], "jog": {"axes": ["X", "Y", "Z"], "steps": [1, 10, 50]}, "extrude": true,
         "load": true, "unload": true, "motors_off": true, "macros": [], "filament_temp": true,
         "materials": [{"name": "PLA", "load_temp": 220}],
         "load_slots": [{"tool": 0, "id": "A1", "name": "Generic PLA", "material": "PLA", "color": "#FF0000"},
                        {"tool": 254, "id": "Ext", "name": null, "material": null}]}
        """#.utf8))
        XCTAssertEqual(bambu.loadSlots?.map(\.tool), [0, 254])
        XCTAssertEqual(bambu.loadSlots?.first?.slotId, "A1")
        XCTAssertTrue(bambu.motorsOff)

        // a printer without any of it, or an older server's bare answer, is "nothing to show"
        let none = try JSONDecoder().decode(Motion.self, from: Data(#"{"supported": false}"#.utf8))
        XCTAssertFalse(none.supported)
        XCTAssertTrue(none.isEmpty)
    }

    func testMotionRequestShapes() async throws {
        let lock = NSLock()
        var seen: [URLRequest] = []
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            return StubResponse(body: Data(#"{"ok": true}"#.utf8))
        }
        let api = client()
        try await api.motion(printer: "cc", .jog("X", -10))
        try await api.motion(printer: "cc", .home("XYZ"))
        try await api.motion(printer: "cc", MotionAction(action: "load", material: "PETG", slot: 3, confirm: true))
        try await api.motion(printer: "cc", MotionAction(action: "macro", macro: "CLEAN_NOZZLE", confirm: true))

        lock.lock(); let r = seen; lock.unlock()
        XCTAssertEqual(r[0].httpMethod, "POST")
        XCTAssertEqual(r[0].url?.path, "/api/printers/cc/motion")
        XCTAssertEqual(body(r[0])?["action"] as? String, "jog")
        XCTAssertEqual(body(r[0])?["axis"] as? String, "X")
        XCTAssertEqual(body(r[0])?["distance"] as? Double, -10)
        XCTAssertNil(body(r[0])?["confirm"])                 // only load / unload / macros ask for it
        XCTAssertEqual(body(r[1])?["axis"] as? String, "XYZ")
        XCTAssertNil(body(r[1])?["distance"])
        XCTAssertEqual(body(r[2])?["material"] as? String, "PETG")
        XCTAssertEqual(body(r[2])?["slot"] as? Int, 3)
        XCTAssertEqual(body(r[2])?["confirm"] as? Bool, true)
        XCTAssertEqual(body(r[3])?["macro"] as? String, "CLEAN_NOZZLE")
    }

    func testOrcaAccountDecodesAndRequests() async throws {
        let pairing = try JSONDecoder().decode(OrcaAccount.self, from: Data(#"""
        {"client_id": "oc_app_x", "client_id_from": "user", "connected": false, "connected_at": null, "last_sync": null,
         "count": 0, "skipped": [], "last_error": null,
         "pending": {"user_code": "ABCD-EFGH", "verification_uri": "https://cloud.orcaslicer.com/pair",
                     "verification_uri_complete": "https://cloud.orcaslicer.com/pair?code=ABCD-EFGH",
                     "expires_in": 600, "error": null}}
        """#.utf8))
        XCTAssertEqual(pairing.pending?.userCode, "ABCD-EFGH")
        XCTAssertNil(pairing.pending?.error)
        XCTAssertEqual(pairing.clientIdFrom, "user")

        let synced = try JSONDecoder().decode(OrcaAccount.self, from: Data(#"""
        {"client_id": "oc_a…", "client_id_from": "server", "connected": true, "last_sync": 1700000000.5, "count": 12,
         "skipped": [{"name": "Odd preset", "error": "unusable"}], "pending": null, "removed": []}
        """#.utf8))
        XCTAssertTrue(synced.connected)
        XCTAssertEqual(synced.count, 12)
        XCTAssertEqual(synced.skipped.first?.name, "Odd preset")
        XCTAssertNil(synced.pending)

        let lock = NSLock()
        var seen: [URLRequest] = []
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            return StubResponse(body: Data(#"{"connected": false, "count": 0, "skipped": []}"#.utf8))
        }
        let api = client()
        _ = try await api.setOrcaClientId("oc_app_x")
        _ = try await api.setOrcaClientId(nil)
        _ = try await api.connectOrca()
        _ = try await api.syncOrca()
        _ = try await api.disconnectOrca(removePresets: true)

        lock.lock(); let r = seen; lock.unlock()
        XCTAssertEqual(r[0].httpMethod, "PUT")
        XCTAssertEqual(body(r[0])?["client_id"] as? String, "oc_app_x")
        XCTAssertTrue(body(r[1])?["client_id"] is NSNull)    // null removes the entered ID
        XCTAssertEqual(r[2].url?.path, "/api/orca-cloud/connect")
        XCTAssertEqual(r[2].httpMethod, "POST")
        XCTAssertEqual(r[3].url?.path, "/api/orca-cloud/sync")
        XCTAssertEqual(r[4].httpMethod, "DELETE")
        XCTAssertEqual(r[4].url?.query, "remove_presets=true")
    }
}
