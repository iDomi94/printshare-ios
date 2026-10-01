import CryptoKit
import XCTest
@testable import PrintShare

/// Server 0.15.0/0.15.1: PocketPrint3D cloud (e-mail login, account, printers reached by the app on the Wi-Fi).
/// Shapes from the server's `docs/API.md` and the Expo app's `lib/api.ts`, `lib/lan/*.ts` (upstream bfee81d).
final class CloudTests: XCTestCase {
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

    // MARK: models

    func testServerStoredBeforeCloudStillDecodes() throws {
        let old = try JSONDecoder().decode(Server.self, from: Data(#"{"url":"http://h:8484","token":"t"}"#.utf8))
        XCTAssertFalse(old.isCloud)
        XCTAssertNil(old.email)
        let cloud = Server(url: Cloud.url, token: "pp3d_1", cloud: true, email: "a@b.de")
        let back = try JSONDecoder().decode(Server.self, from: JSONEncoder().encode(cloud))
        XCTAssertEqual(back, cloud)
        XCTAssertTrue(back.isCloud)
    }

    func testMeAndCosmosPrinter() throws {
        let me = try JSONDecoder().decode(Me.self, from: Data(#"""
        {"id": "u1", "email": "a@b.de", "printers": 2,
         "limits": {"slices_per_day": 30, "slices_today": 4, "upload_mb": 100}}
        """#.utf8))
        XCTAssertEqual(me.limits, Me.Limits(slicesPerDay: 30, slicesToday: 4, uploadMb: 100))
        XCTAssertEqual(l(.slicesToday, ["used": "4", "limit": "30"]), "4 of 30 slices today")
        let p = try JSONDecoder().decode(Printer.self, from: Data(#"""
        {"id": "p1", "name": "COSMOS", "type": "moonraker", "machine": "Elegoo Centauri Carbon 0.4 nozzle",
         "cosmos": true}
        """#.utf8))
        XCTAssertTrue(p.cosmos)
    }

    // MARK: login

    func testLoginErrorsInExpoOrder() {
        XCTAssertEqual(CloudAuth.message(l, status: 400, detail: "Please give a valid e-mail address"), l(.errEmail))
        XCTAssertEqual(CloudAuth.message(l, status: 429, detail: "too many codes"), l(.errTooManyCodes))
        XCTAssertEqual(CloudAuth.message(l, status: 401, detail: "Wrong code"), l(.errWrongCode))
        XCTAssertEqual(CloudAuth.message(l, status: 401, detail: "The code has expired"), l(.errCodeExpired))
        XCTAssertEqual(CloudAuth.message(l, status: 502, detail: "smtp down"), l(.errMail))
        XCTAssertEqual(CloudAuth.message(l, status: 500, detail: "boom"), "boom")
    }

    func testCodeAndLoginRequests() async throws {
        var seen: [(String, [String: String])] = []
        let lock = NSLock()
        StubProtocol.install { req in
            let body = (try? JSONSerialization.jsonObject(with: self.bodyData(req) ?? Data())) as? [String: String] ?? [:]
            lock.lock(); seen.append((req.url?.path ?? "", body)); lock.unlock()
            if req.url?.path == "/api/auth/code" {
                return StubResponse(body: Data(#"{"sent": true, "email": "a@b.de"}"#.utf8))
            }
            return StubResponse(body: Data(#"{"token": "pp3d_abc", "user": {"id": "u1", "email": "a@b.de"}}"#.utf8))
        }
        let session = StubProtocol.session()
        let sent = try await CloudAuth.requestCode(email: " a@b.de ", l10n: l, base: "https://cloud.test", session: session)
        XCTAssertEqual(sent.email, "a@b.de")
        let login = try await CloudAuth.login(email: "a@b.de", code: "123456", l10n: l, base: "https://cloud.test",
                                              session: session)
        XCTAssertEqual(login.token, "pp3d_abc")
        XCTAssertEqual(seen.map(\.0), ["/api/auth/code", "/api/auth/login"])
        XCTAssertEqual(seen[0].1, ["email": "a@b.de", "lang": "en"])
        XCTAssertEqual(seen[1].1, ["email": "a@b.de", "code": "123456", "device": "ios app"])
    }

    func testWrongCodeMessage() async {
        StubProtocol.install { _ in StubResponse(status: 401, body: Data(#"{"detail": "Wrong code"}"#.utf8)) }
        do {
            _ = try await CloudAuth.login(email: "a@b.de", code: "000000", l10n: l, base: "https://cloud.test",
                                          session: StubProtocol.session())
            XCTFail("expected 401")
        } catch let e as APIError {
            XCTAssertEqual(e.message, l(.errWrongCode))
        } catch {
            XCTFail("\(error)")
        }
    }

    // MARK: account API

    func testExpiredSessionMessage() async {
        StubProtocol.install { _ in StubResponse(status: 401, body: Data(#"{"detail": "invalid token"}"#.utf8)) }
        do {
            _ = try await cloudClient().me()
            XCTFail("expected 401")
        } catch let e as APIError {
            XCTAssertEqual(e.message, l(.errSession))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testPrinterSettingsBodyAndNoRepeat() async throws {
        var seen: [URLRequest] = []
        let lock = NSLock()
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            if req.httpMethod == "DELETE" { return StubResponse(status: 500) }
            return StubResponse(body: Data(#"{"id": "p9", "name": "CC", "type": "elegoo_sdcp", "machine": ""}"#.utf8))
        }
        let api = cloudClient()
        let p = try await api.addPrinter(PrinterSettings(name: "CC", type: "elegoo_sdcp", cosmos: false))
        XCTAssertEqual(p.id, "p9")
        _ = try await api.updatePrinter(id: "p9", PrinterSettings(name: "CC", type: "moonraker", cosmos: true))
        do { try await api.deletePrinter(id: "p9"); XCTFail("expected 500") } catch {}
        XCTAssertEqual(seen.map { $0.httpMethod ?? "" }, ["POST", "PATCH", "DELETE"])
        XCTAssertEqual(seen.map { $0.url?.path ?? "" }, ["/api/printers", "/api/printers/p9", "/api/printers/p9"])
        let body = try XCTUnwrap(bodyData(seen[1]))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["type"] as? String, "moonraker")
        XCTAssertEqual(obj["cosmos"] as? Bool, true)
        XCTAssertNil(obj["address"])                         // the Wi-Fi address never leaves the phone
    }

    func testGcodePathWithLanes() {
        XCTAssertEqual(APIClient.gcodePath(job: "ab12", lanes: nil), "/api/jobs/ab12/gcode")
        XCTAssertEqual(APIClient.gcodePath(job: "ab12", lanes: [:]), "/api/jobs/ab12/gcode")
        XCTAssertEqual(APIClient.gcodePath(job: "ab12", lanes: [2: 0, 1: 3]),
                       "/api/jobs/ab12/gcode?lanes=%7B%221%22%3A3%2C%222%22%3A0%7D")
    }

    // MARK: LAN helpers

    func testKindBucketsLikeTheServer() {
        XCTAssertEqual(Lan.kind(nil), .unknown)
        XCTAssertEqual(Lan.kind("printing"), .active)
        XCTAssertEqual(Lan.kind("file_checking"), .active)
        XCTAssertEqual(Lan.kind("PAUSED"), .paused)
        XCTAssertEqual(Lan.kind("standby"), .idle)
        XCTAssertEqual(Lan.kind("completed"), .done)
        XCTAssertEqual(Lan.kind("cancelled"), .stopped)
        XCTAssertEqual(Lan.kind("error"), .error)
    }

    func testFileNameAndHost() {
        XCTAssertEqual(Lan.fileName(source: "3D Benchy (v2).3mf", job: "j1"), "3D_Benchy_v2.gcode")
        XCTAssertEqual(Lan.fileName(source: "Ünïcode.stl", job: "j1"), "n_code.gcode")
        XCTAssertEqual(Lan.fileName(source: nil, job: "j1"), "print_j1.gcode")
        XCTAssertEqual(Lan.fileName(source: String(repeating: "a", count: 80) + ".stl", job: "j").count, 60 + 6)
        XCTAssertEqual(Lan.host(" http://192.168.1.5:7125/x "), "192.168.1.5:7125")
        XCTAssertTrue(Lan.canRelay("moonraker"))
        XCTAssertTrue(Lan.canRelay("prusalink"))
        XCTAssertTrue(Lan.canRelay("octoprint"))
        XCTAssertFalse(Lan.canRelay("bambu"))
        XCTAssertThrowsError(try Lan.printer(type: "bambu", access: LanAccess(address: "1.2.3.4")))
        // PrusaLink needs a password or API key, OctoPrint an API key
        XCTAssertThrowsError(try Lan.printer(type: "prusalink", access: LanAccess(address: "1.2.3.4")))
        XCTAssertThrowsError(try Lan.printer(type: "octoprint", access: LanAccess(address: "1.2.3.4", apiKey: "")))
        XCTAssertNoThrow(try Lan.printer(type: "prusalink", access: LanAccess(address: "1.2.3.4", password: "pw")))
    }

    func testSDCPStatusMapping() {
        let st: [String: Any] = [
            "PrintInfo": ["Status": 13, "Filename": "benchy.gcode", "Progress": 42, "CurrentLayer": 80, "TotalLayer": 240,
                          "CurrentTicks": 600, "TotalTicks": 2000, "PrintSpeedPct": 100],
            "TempOfNozzle": 209.6, "TempTargetNozzle": 210, "TempOfHotbed": 60, "TempTargetHotbed": 60,
            "TempOfBox": 31, "TempTargetBox": 0,
            "CurrentFanSpeed": ["ModelFan": 100, "AuxiliaryFan": 0, "BoxFan": 30],
            "LightStatus": ["SecondLight": 1],
        ]
        let s = SDCPPrinter.status(from: st, host: "192.168.1.5")
        XCTAssertEqual(s.state, "printing")
        XCTAssertEqual(s.kind, .active)
        XCTAssertEqual(s.file, "benchy.gcode")
        XCTAssertEqual(s.progress, 42)
        XCTAssertEqual(s.layer, 80)
        XCTAssertEqual(s.layers, 240)
        XCTAssertEqual(s.timeRemainingS, 1400)
        XCTAssertEqual(s.nozzle, 209.6)
        XCTAssertEqual(s.heaters["chamber"], HeaterState(actual: 31, target: 0))
        XCTAssertEqual(s.fans, ["part": 100, "aux": 0, "chamber": 30])
        XCTAssertEqual(s.lights, ["light": true])
        XCTAssertEqual(s.camera, "http://192.168.1.5:3031/video")
        XCTAssertEqual(SDCPPrinter.status(from: ["PrintInfo": ["Status": 9]], host: "h").kind, .done)
        XCTAssertEqual(SDCPPrinter.status(from: [:], host: "h").kind, .idle)
        XCTAssertEqual(SDCPPrinter.status(from: ["PrintInfo": ["Status": 99]], host: "h").state, "status_99")
    }

    func testMoonrakerStatusAndLanes() {
        let st: [String: Any] = [
            "print_stats": ["state": "printing", "filename": "benchy.gcode", "print_duration": 300,
                            "info": ["current_layer": 10, "total_layer": 240]],
            "display_status": ["progress": 0.1234], "extruder": ["temperature": 210.2, "target": 210],
            "heater_bed": ["temperature": 60, "target": 60], "gcode_move": ["speed_factor": 1.5],
        ]
        let s = MoonrakerPrinter.status(from: st, base: "http://192.168.1.60")
        XCTAssertEqual(s.kind, .active)
        XCTAssertEqual(s.progress, 12.3)
        XCTAssertEqual(s.layer, 10)
        XCTAssertEqual(s.speed, 150)
        XCTAssertEqual(s.camera, "http://192.168.1.60/webcam/?action=stream")

        // Dominique's COSMOS: tools not in lane order, empty lane without material
        let lanes = MoonrakerPrinter.lanes(objects: ["AFC_lane CANVAS_1", "AFC_lane CANVAS_2", "AFC_lane CANVAS_4"], status: [
            "AFC_lane CANVAS_1": ["map": "T3", "material": "PLA", "color": "#ff0000", "prep": true, "load": true],
            "AFC_lane CANVAS_2": ["map": "T1", "material": NSNull(), "color": "", "prep": false, "load": false],
            "AFC_lane CANVAS_4": ["map": "T0", "material": "PETG", "color": "00ff00aa", "prep": true, "tool_loaded": true,
                                  "weight": 812.5, "status": "Tooled"],
        ], currentLoad: nil)
        XCTAssertEqual(lanes.map(\.id), ["CANVAS_4", "CANVAS_2", "CANVAS_1"])
        XCTAssertEqual(lanes.map(\.tool), [0, 1, 3])
        XCTAssertEqual(lanes[0].color, "#00FF00")
        XCTAssertTrue(lanes[0].inToolhead)
        XCTAssertEqual(lanes[0].weightG, 812.5)
        XCTAssertNil(lanes[1].material)
        XCTAssertFalse(lanes[1].loaded)
        XCTAssertEqual(lanes[2].color, "#FF0000")
    }

    func testMoonrakerTriesPort7125AndReportsNoStart() async throws {
        StubProtocol.install { req in
            switch (req.url?.port, req.url?.path) {
            case (nil, _): return StubResponse(error: URLError(.cannotConnectToHost))
            case (7125, "/server/info"): return StubResponse(body: Data(#"{"result": {"klippy_state": "ready"}}"#.utf8))
            case (7125, "/server/files/upload"):
                return StubResponse(status: 201, body: Data(#"{"result": {"print_started": false}}"#.utf8))
            default: return StubResponse(status: 404)
            }
        }
        XCTAssertEqual(MoonrakerPrinter(address: "192.168.1.60:80").candidates, ["http://192.168.1.60:80"])
        let printer = MoonrakerPrinter(address: "printer.test/", session: StubProtocol.session())
        XCTAssertEqual(printer.candidates, ["http://printer.test", "http://printer.test:7125"])
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("m-\(UUID().uuidString).gcode")
        try Data("G28\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await printer.send(file: file, name: "benchy.gcode", options: SendOptions(start: false))
        do {
            try await printer.send(file: file, name: "benchy.gcode", options: SendOptions(start: true))
            XCTFail("expected an error: the printer did not start")
        } catch let e as LanError {
            XCTAssertEqual(e.message, "the printer stored the file but did not start it")
        }
        XCTAssertEqual(StubProtocol.requests.filter { $0.path == "/server/files/upload" }.count, 2)
    }

    func testSDCPUploadInChunks() async throws {
        let progress = Box()
        StubProtocol.install { req in
            req.url?.path == "/uploadFile/upload" ? StubResponse(body: Data(#"{"code": "000000"}"#.utf8))
                                                  : StubResponse(status: 404)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("s-\(UUID().uuidString).gcode")
        let data = Data((0..<(SDCPPrinter.chunkSize * 2 + 1000)).map { UInt8($0 % 251) })
        try data.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertEqual(try SDCPPrinter.md5(of: file), Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined())
        let printer = SDCPPrinter(host: "printer.test", session: StubProtocol.session())
        try await printer.send(file: file, name: "benchy.gcode", options: SendOptions(start: false, onProgress: { part in
            progress.set(part)
        }))
        XCTAssertEqual(StubProtocol.requests, Array(repeating: LoggedRequest(method: "POST", host: "printer.test",
                                                                            path: "/uploadFile/upload"), count: 3))
        XCTAssertEqual(progress.value, 1)

        StubProtocol.install { _ in StubResponse(body: Data(#"{"code": "111111"}"#.utf8)) }
        do {
            try await printer.send(file: file, name: "benchy.gcode", options: SendOptions(start: false))
            XCTFail("expected a refused upload")
        } catch let e as LanError {
            XCTAssertEqual(e.message, "the printer refused the upload (HTTP 200)")
        }
        XCTAssertEqual(StubProtocol.requests.count, 1)        // stops at the first refused chunk
    }

    func testMultipartBody() {
        let body = Multipart.body(boundary: "B", fields: [("Check", "1")], fileField: "File", fileName: "a\"b.gcode",
                                  data: Data("G1".utf8))
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       "--B\r\nContent-Disposition: form-data; name=\"Check\"\r\n\r\n1\r\n"
                       + "--B\r\nContent-Disposition: form-data; name=\"File\"; filename=\"a_b.gcode\"\r\n"
                       + "Content-Type: application/octet-stream\r\n\r\nG1\r\n--B--\r\n")
    }

    // MARK: server 0.15.3 - PrusaLink and OctoPrint in the cloud

    func testAccessStoredAsPlainAddressStillLoads() throws {
        let old = try JSONDecoder().decode([String: LanAccess].self, from: Data(#"{"p1": "192.168.1.50"}"#.utf8))
        XCTAssertEqual(old["p1"], LanAccess(address: "192.168.1.50"))
        let full = LanAccess(address: " 10.0.0.2 ", password: "", apiKey: " key ").cleaned
        XCTAssertEqual(full, LanAccess(address: "10.0.0.2", apiKey: "key"))
        XCTAssertNil(LanAccess(address: "  ").cleaned)
        let back = try JSONDecoder().decode(LanAccess.self, from: JSONEncoder().encode(LanAccess(address: "a", password: "p")))
        XCTAssertEqual(back.password, "p")
    }

    func testDigestMatchesRFC2617Example() {
        var d = DigestAuth(user: "Mufasa", password: "Circle Of Life")
        XCTAssertTrue(d.learn(#"Digest realm="testrealm@host.com", qop="auth,auth-int", nonce="dcd98b7102dd2f0e8b11d0f600bfb0c093", opaque="5ccc069c403ebaf9f0171e9517f40e41""#))
        let h = d.header(method: "GET", uri: "/dir/index.html", cnonce: "0a4f113b")
        XCTAssertTrue(h.contains(#"response="6629fae49393a05397450978507c4ef1""#), h)
        XCTAssertTrue(h.contains("nc=00000001"))
        XCTAssertTrue(d.header(method: "GET", uri: "/", cnonce: "x").contains("nc=00000002"))
        var none = DigestAuth(user: "maker", password: "pw")
        XCTAssertFalse(none.learn("Basic realm=x"))
    }

    func testPrusaLinkStatusAndFileName() {
        let s = PrusaLinkPrinter.status(status: [
            "printer": ["state": "PRINTING", "temp_nozzle": 215.1, "target_nozzle": 215, "temp_bed": 60, "target_bed": 60,
                        "speed": 100],
            "job": ["id": 7, "progress": 42.04, "time_printing": 600, "time_remaining": 1200],
        ], job: ["file": ["display_name": "Benchy.gcode", "name": "BENCHY~1.GCO"]])
        XCTAssertEqual(s.state, "printing")
        XCTAssertEqual(s.kind, .active)
        XCTAssertEqual(s.file, "Benchy.gcode")
        XCTAssertEqual(s.progress, 42)
        XCTAssertEqual(s.timeRemainingS, 1200)
        XCTAssertEqual(s.speed, 100)
        XCTAssertEqual(PrusaLinkPrinter.status(status: ["printer": ["state": "FINISHED"]], job: [:]).kind, .done)
        XCTAssertEqual(PrusaLinkPrinter.status(status: ["printer": ["state": "IDLE"]], job: [:]).kind, .idle)
        XCTAssertEqual(PrusaLinkPrinter.remoteName("3D Benchy (v2).GCODE"), "3D_Benchy_v2.gcode")
        XCTAssertEqual(PrusaLinkPrinter.remoteName("..."), "print.gcode")
    }

    func testPrusaLinkDigestHandshakeAndUpload() async throws {
        var seen: [URLRequest] = []
        let lock = NSLock()
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            guard req.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Digest ") == true else {
                return StubResponse(status: 401, headers: ["WWW-Authenticate": #"Digest realm="Printer API", nonce="abc", qop="auth""#])
            }
            if req.url?.path == "/api/v1/storage" {
                return StubResponse(body: Data(#"{"storage_list": [{"path": "/usb/", "available": true, "read_only": false}]}"#.utf8))
            }
            return StubResponse(status: 201)
        }
        let printer = try PrusaLinkPrinter(address: "printer.test", password: "pw", apiKey: nil, session: StubProtocol.session())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString).gcode")
        try Data("G28\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        try await printer.send(file: file, name: "benchy.gcode", options: SendOptions(start: false))
        // first contact: 401 with the challenge, the same GET once more with the digest, then the upload
        XCTAssertEqual(seen.map { $0.url?.path ?? "" }, ["/api/v1/storage", "/api/v1/storage", "/api/v1/files/usb/benchy.gcode"])
        XCTAssertEqual(seen[2].httpMethod, "PUT")
        XCTAssertEqual(seen[2].value(forHTTPHeaderField: "Print-After-Upload"), "?0")
        XCTAssertTrue(seen[2].value(forHTTPHeaderField: "Authorization")?.contains("nc=00000002") == true)
        XCTAssertTrue(seen[2].value(forHTTPHeaderField: "Authorization")?.contains(#"uri="/api/v1/files/usb/benchy.gcode""#) == true)
    }

    func testOctoPrintStateAndNoStart() async throws {
        XCTAssertEqual(OctoPrintPrinter.state(printer: nil, job: [:]), "offline")
        XCTAssertEqual(OctoPrintPrinter.state(printer: ["state": ["flags": ["printing": true]]], job: [:]), "printing")
        XCTAssertEqual(OctoPrintPrinter.state(printer: ["state": ["flags": ["paused": true]]], job: [:]), "paused")
        XCTAssertEqual(OctoPrintPrinter.state(printer: ["state": ["flags": [:]]], job: ["progress": ["completion": 100]]),
                       "complete")
        let s = OctoPrintPrinter.status(printer: ["temperature": ["tool0": ["actual": 200.5, "target": 200], "bed": ["actual": 55]]],
                                        job: ["job": ["file": ["display": "cube.gcode"]], "progress": ["completion": 12.34]])
        XCTAssertEqual(s.nozzle, 200.5)
        XCTAssertEqual(s.bed, 55)
        XCTAssertEqual(s.file, "cube.gcode")
        XCTAssertEqual(s.progress, 12.3)

        var keys: [String?] = []
        let lock = NSLock()
        StubProtocol.install { req in
            lock.lock(); keys.append(req.value(forHTTPHeaderField: "X-Api-Key")); lock.unlock()
            return StubResponse(status: 201, body: Data(#"{"done": true, "effectivePrint": false}"#.utf8))
        }
        let printer = try OctoPrintPrinter(address: "octopi.test/", apiKey: "k1", session: StubProtocol.session())
        XCTAssertEqual(printer.base, "http://octopi.test")
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("o-\(UUID().uuidString).gcode")
        try Data("G28\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try await printer.send(file: file, name: "cube.gcode", options: SendOptions(start: true))
            XCTFail("expected: OctoPrint did not start it")
        } catch let e as LanError {
            XCTAssertTrue(e.message.contains("did not start"))
        }
        XCTAssertEqual(keys, ["k1"])
        XCTAssertEqual(StubProtocol.requests, [LoggedRequest(method: "POST", host: "octopi.test", path: "/api/files/local")])
    }

    func testPrinterSettingsSendMachineOnlyWhenSet() throws {
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            PrinterSettings(name: "CC", type: "elegoo_sdcp", cosmos: false))) as? [String: Any]
        XCTAssertNil(plain?["machine"])
        let prusa = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            PrinterSettings(name: "MK4S", type: "prusalink", cosmos: false, machine: "Prusa MK4S 0.4 nozzle"))) as? [String: Any]
        XCTAssertEqual(prusa?["machine"] as? String, "Prusa MK4S 0.4 nozzle")
        let list = try JSONDecoder().decode([Machine].self, from: Data(#"[{"name": "Prusa MK4S 0.4 nozzle", "vendor": "Prusa"}]"#.utf8))
        XCTAssertEqual(list.first?.vendor, "Prusa")
    }
}

private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0.0
    var value: Double { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ v: Double) { lock.lock(); stored = v; lock.unlock() }
}
