import CryptoKit
import XCTest
@testable import PrintShare

/// Server 0.24.0-0.34.0: bridges with sealed printer secrets, Wi-Fi discovery, jobs the server follows (finished /
/// cancelled, relayed, observe), time-lapse, cloud bookings, OrcaSlicer upload. Shapes from the server's
/// `docs/API.md` / `docs/BRIDGE.md` and the Expo app's `lib/api.ts` (upstream ae96cbd).
final class ServerThirtyFourTests: XCTestCase {
    private let l = L10n(lang: .en)

    private func client() -> APIClient {
        APIClient(server: Server(url: "http://home.test:8484", token: "tok"), l10n: l, session: StubProtocol.session(),
                  cache: RouteCache())
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

    // MARK: seal

    /// Made by the server's own `printshare/bridge/seal.py` for the bridge key 01 02 … 20 (hex).
    private let bridgePrivate = Data(1 ... 32)
    private let bridgePublic = "B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw="
    private let pythonBlob = "mDHDWqgVIrTwuPdIYfeSCeXrQHOQSEpbcByQhDN+u13V/vDVyz8Ste3AVcZqN2fpGcNHRBpUR7HizUR8l06zGAhySOmzgmD1Lf6FLuxLLni3fqoMhT6bq7hzJjTyPx36AwYrCzRoSK3eWQ=="

    func testSealMatchesTheServer() throws {
        let key = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bridgePrivate)
        XCTAssertEqual(key.publicKey.rawRepresentation.base64EncodedString(), bridgePublic)
        // the server's blob opens with the same scheme ...
        XCTAssertEqual(try Seal.open(pythonBlob, privateKey: key),
                       Seal.Secrets(address: "cc.local", password: "pw", apiKey: "k1"))
        // ... and ours round-trips; only filled fields are sent, `api_key` in snake case
        let secrets = Seal.Secrets(address: "cc.local", password: nil, apiKey: "k2")
        let blob = try Seal.seal(publicKey: bridgePublic, secrets)
        XCTAssertEqual(try Seal.open(blob, privateKey: key), secrets)
        XCTAssertEqual(Data(base64Encoded: blob)?.count, 32 + #"{"address":"cc.local","api_key":"k2"}"#.utf8.count + 16)
        XCTAssertNotEqual(try Seal.seal(publicKey: bridgePublic, secrets), blob)   // fresh key each time
        XCTAssertThrowsError(try Seal.seal(publicKey: "", secrets))
        XCTAssertThrowsError(try Seal.seal(publicKey: "AAAA", secrets))
    }

    func testSecretsLeaveOutEmptyFields() {
        XCTAssertEqual(CloudPrinterView.secrets(LanAccess(address: " cc.local ", password: "", apiKey: " ")),
                       Seal.Secrets(address: "cc.local"))
        XCTAssertTrue(CloudPrinterView.secrets(LanAccess(address: "")).isEmpty)
        XCTAssertEqual(CloudPrinterView.secrets(LanAccess(address: "x", password: "p w", apiKey: "k")),
                       Seal.Secrets(address: "x", password: "p w", apiKey: "k"))
    }

    // MARK: discovery

    func testSubnetHosts() {
        let hosts = Discovery.subnetHosts("192.168.0.20", prefix: 24)
        XCTAssertEqual(hosts.count, 253)
        XCTAssertEqual(hosts.first, "192.168.0.1")
        XCTAssertEqual(hosts.last, "192.168.0.254")
        XCTAssertFalse(hosts.contains("192.168.0.20"))
        // bigger networks: only the /24 around the phone
        XCTAssertEqual(Discovery.subnetHosts("10.1.2.3", prefix: 16).count, 253)
        XCTAssertEqual(Discovery.subnetHosts("10.1.2.3", prefix: 30), ["10.1.2.1", "10.1.2.2"])
        XCTAssertEqual(Discovery.subnetHosts("nope", prefix: 24), [])
        XCTAssertEqual(Discovery.ip2n("1.2.3.4"), 0x0102_0304)
        XCTAssertNil(Discovery.ip2n("1.2.3.256"))
        XCTAssertEqual(Discovery.n2ip(0xC0A8_0001), "192.168.0.1")
    }

    func testSdcpAnswer() {
        let answer = Data(#"""
        {"Id": "x", "Data": {"Name": "CC Werkstatt", "MachineName": "Centauri Carbon", "BrandName": "ELEGOO",
         "MainboardIP": "10.0.0.7", "MainboardID": "abc", "FirmwareVersion": "V1.1.29"}}
        """#.utf8)
        let p = Discovery.parseSdcp(address: "10.0.0.9", data: answer)
        XCTAssertEqual(p, FoundPrinter(type: "elegoo_sdcp", address: "10.0.0.7", name: "CC Werkstatt",
                                       detail: "ELEGOO Centauri Carbon · V1.1.29"))
        XCTAssertEqual(Discovery.parseSdcp(address: "10.0.0.9", data: Data(#"{"MachineName": "CC"}"#.utf8))?.address, "10.0.0.9")
        XCTAssertNil(Discovery.parseSdcp(address: "10.0.0.9", data: Data(#"{"other": 1}"#.utf8)))
        XCTAssertNil(Discovery.parseSdcp(address: "10.0.0.9", data: Data("M99999".utf8)))
    }

    func testIdentifyMoonrakerPrusaLinkOctoPrint() async {
        StubProtocol.install { req in
            let host = req.url?.host ?? "", port = req.url?.port, path = req.url?.path ?? ""
            switch (host, port, path) {
            case ("cosmos.test", nil, "/server/info"):
                return StubResponse(body: Data(#"{"result": {"klippy_state": "ready"}}"#.utf8))
            case ("cosmos.test", nil, "/printer/objects/list"):
                return StubResponse(body: Data(#"{"result": {"objects": ["extruder", "gcode_macro _COSMOS_SETTINGS"]}}"#.utf8))
            case ("voron.test", 7125, "/server/info"):
                return StubResponse(body: Data(#"{"result": {"moonraker_version": "v0.9"}}"#.utf8))
            case ("voron.test", 7125, "/printer/info"):
                return StubResponse(body: Data(#"{"result": {"hostname": "voron"}}"#.utf8))
            case ("prusa.test", nil, "/api/v1/info"):
                return StubResponse(status: 401, headers: ["WWW-Authenticate": #"Digest realm="Printer API", nonce="1""#])
            case ("octo.test", nil, "/"):
                return StubResponse(body: Data("<html><title>OctoPrint</title></html>".utf8))
            case (_, nil, _):
                return StubResponse(status: 404, body: Data("not here".utf8))
            default:
                return StubResponse(error: URLError(.cannotConnectToHost))
            }
        }
        let s = StubProtocol.session()
        let cosmos = await Discovery.identify("cosmos.test", session: s)
        XCTAssertEqual(cosmos?.type, "moonraker")
        XCTAssertEqual(cosmos?.address, "cosmos.test")
        XCTAssertEqual(cosmos?.cosmos, true)
        XCTAssertEqual(cosmos?.name, "Centauri Carbon (COSMOS)")
        let voron = await Discovery.identify("voron.test", session: s)
        XCTAssertEqual(voron?.address, "voron.test")                 // MoonrakerPrinter tries :7125 itself
        XCTAssertEqual(voron?.name, "voron")
        XCTAssertEqual(voron?.cosmos, false)
        let prusa = await Discovery.identify("prusa.test", session: s)
        XCTAssertEqual(prusa?.type, "prusalink")
        let octo = await Discovery.identify("octo.test", session: s)
        XCTAssertEqual(octo?.type, "octoprint")
        let none = await Discovery.identify("nas.test", session: s)
        XCTAssertNil(none)
    }

    func testBridgeHelloAndLocalCode() async throws {
        StubProtocol.install { req in
            switch (req.url?.host ?? "", req.url?.path ?? "") {
            case ("pi.test", "/api/bridge/hello"):
                return StubResponse(body: Data(#"""
                {"pocketprint3d": "bridge", "name": "Werkstatt-Pi", "version": "0.34.0", "bridge_id": null,
                 "paired": false, "account": null, "pairable": true, "bridge_only": true}
                """#.utf8))
            case ("pi.test", "/api/bridge/local-code"): return StubResponse(body: Data(#"{"code": "K7Q4-M2ZX"}"#.utf8))
            case ("server.test", "/api/bridge/hello"):
                return StubResponse(body: Data(#"{"pocketprint3d": "server", "name": "x"}"#.utf8))
            case ("server.test", "/api/bridge/local-code"):
                return StubResponse(status: 403, body: Data(#"{"detail": "only on the home network"}"#.utf8))
            default: return StubResponse(status: 404)
            }
        }
        let s = StubProtocol.session()
        let b = await Discovery.bridgeHello("http://pi.test", session: s)
        XCTAssertEqual(b?.name, "Werkstatt-Pi")
        XCTAssertEqual(b?.pairable, true)
        XCTAssertEqual(b?.bridgeOnly, true)
        XCTAssertNil(b?.bridgeId)
        XCTAssertEqual(b?.id, "http://pi.test")
        let server = await Discovery.bridgeHello("http://server.test", session: s)
        XCTAssertNil(server)                                           // not a bridge
        let code = try await Discovery.bridgeLocalCode("http://pi.test", session: s)
        XCTAssertEqual(code, "K7Q4-M2ZX")
        do {
            _ = try await Discovery.bridgeLocalCode("http://server.test", session: s)
            XCTFail("no code expected")
        } catch {
            XCTAssertEqual(error.localizedDescription, "only on the home network")
        }
    }

    func testCodeFormat() {
        XCTAssertEqual(BridgesView.formatCode("k7q4m2zx"), "K7Q4-M2ZX")
        XCTAssertEqual(BridgesView.formatCode("K7Q4 M2ZX"), "K7Q4-M2ZX")
        XCTAssertEqual(BridgesView.formatCode("k7q"), "K7Q")
        XCTAssertEqual(BridgesView.formatCode("K7Q4-M2ZX9"), "K7Q4-M2ZX")
        XCTAssertEqual(BridgesView.formatCode("ä!k"), "K")
    }

    // MARK: decoding

    func testBridgeAndPrinterDecoding() throws {
        let b = try JSONDecoder().decode([Bridge].self, from: Data(#"""
        [{"id": "b1", "name": "Tower", "version": "0.34.0", "public_key": "B6N8", "created": 1759400000,
          "last_seen": 1759400100.5, "online": true,
          "printers": [{"id": "cc", "name": "Centauri", "type": "elegoo_sdcp", "machine": null}]}]
        """#.utf8))
        XCTAssertEqual(b[0].publicKey, "B6N8")
        XCTAssertEqual(b[0].lastSeen, 1759400100.5)
        XCTAssertTrue(b[0].online)
        XCTAssertEqual(b[0].printers.map(\.type), ["elegoo_sdcp"])
        let p = try JSONDecoder().decode([Printer].self, from: Data(#"""
        [{"id": "cc", "name": "CC", "type": "elegoo_sdcp", "bridge": "b1"},
         {"id": "k", "name": "K", "type": "moonraker", "bridge": ""},
         {"id": "o", "name": "O", "type": "octoprint"}]
        """#.utf8))
        XCTAssertEqual(p.map(\.bridge), ["b1", nil, nil])
        let found = try JSONDecoder().decode([FoundPrinter].self, from: Data(#"""
        [{"type": "moonraker", "address": "cosmos.local", "name": "COSMOS", "cosmos": true, "added": true}]
        """#.utf8))
        XCTAssertTrue(found[0].added)
        XCTAssertTrue(found[0].cosmos)
        let o = try JSONDecoder().decode(OrcaUpload.self, from: Data(#"""
        {"enabled": true, "url": "https://api.pocketprint3d.com/orca/cc", "created": 1759400000, "last_used": null}
        """#.utf8))
        XCTAssertTrue(o.enabled)
        XCTAssertNil(o.lastUsed)
        XCTAssertNil(o.key)
    }

    func testJobFollowsThePrint() throws {
        let j = try JSONDecoder().decode(Job.self, from: Data(#"""
        {"id": "j1", "kind": "prepare", "state": "finished", "log": [], "created": 1, "request": {"link": "upload:a"},
         "printer_file": "benchy.gcode", "timelapse": {"state": "ready", "frames": 240, "error": null}}
        """#.utf8))
        XCTAssertEqual(j.state, .finished)
        XCTAssertTrue(j.state.isOver)
        XCTAssertEqual(j.printerFile, "benchy.gcode")
        XCTAssertEqual(j.timelapse, Timelapse(state: .ready, frames: 240))
        let k = try JSONDecoder().decode(Job.self, from: Data(#"""
        {"id": "j2", "state": "uploading", "printer_file": "", "timelapse": {"state": "melting"}}
        """#.utf8))
        XCTAssertEqual(k.state, .uploading)
        XCTAssertFalse(k.state.isOver)
        XCTAssertNil(k.printerFile)
        XCTAssertEqual(k.timelapse?.state, .failed)
        XCTAssertTrue(JobState.cancelled.isOver)
    }

    func testBadges() {
        XCTAssertEqual(JobBadge.kind(.finished), .ok)
        XCTAssertEqual(JobBadge.kind(.cancelled), .warn)
        XCTAssertEqual(JobBadge.kind(.started), .accent)
        XCTAssertEqual(JobBadge.kind(.uploading), .neutral)
        XCTAssertEqual(JobBadge.kind(.done, home: true), .neutral)
        XCTAssertEqual(JobBadge.kind(.error), .error)
    }

    func testServerBookings() throws {
        let r = try JSONDecoder().decode(ServerBookings.self, from: Data(#"""
        {"waiting": [{"id": "w", "printer": "cc", "printer_name": "Centauri", "file": "a.gcode", "job": "j1",
                      "uses": [{"spool": 3, "grams": 11.4, "label": "#3 PLA"}], "booked_uses": [], "created": 1759400000,
                      "seen": true, "progress": 40, "state": "wait", "ask_part": null}],
         "open": [{"id": "o", "printer": "cc", "file": "b.gcode", "uses": [{"spool": 4, "grams": 5}],
                   "created": 1759400000, "state": "ask", "ask_part": 0.3}],
         "booked": [], "booked_now": [{"id": "d", "printer": "cc", "file": "c.gcode", "uses": [],
                   "booked_uses": [{"spool": 3, "grams": 2.5}], "created": 1, "state": "booked"}]}
        """#.utf8))
        let w = Booking(server: r.waiting[0])
        XCTAssertEqual(w.printerName, "Centauri")
        XCTAssertEqual(w.created, 1_759_400_000_000)
        XCTAssertNil(w.ask)
        XCTAssertEqual(w.account, true)
        let o = Booking(server: r.open[0])
        XCTAssertEqual(o.ask?.part, 0.3)
        XCTAssertEqual(o.printerName, "cc")
        XCTAssertEqual(o.uses.first?.label, "#4")
        let d = Booking(server: r.bookedNow[0])
        XCTAssertEqual(d.grams, 2.5)                                    // booked: what was really booked
    }

    // MARK: requests

    func testRequestBodies() async throws {
        let seen = Seen()
        StubProtocol.install { req in
            seen.add(req)
            switch req.url?.path ?? "" {
            case "/api/bridges/pair": return StubResponse(body: Data(#"{"id": "b1", "name": "Tower"}"#.utf8))
            case "/api/bridges/b1/printers": return StubResponse(body: Data(#"{"id": "cc", "name": "CC", "type": "elegoo_sdcp", "bridge": "b1"}"#.utf8))
            case "/api/bridges/b1/discover": return StubResponse(body: Data(#"[{"type": "elegoo_sdcp", "address": "cc.local", "name": "CC"}]"#.utf8))
            case "/api/bookings/observe": return StubResponse(body: Data(#"{"waiting": [], "open": [], "booked": [], "booked_now": []}"#.utf8))
            case "/api/printers/cc/orca-upload": return StubResponse(body: Data(#"{"enabled": true, "url": "u", "key": "secret"}"#.utf8))
            default: return StubResponse(body: Data("{}".utf8))
            }
        }
        let api = client()
        try await api.send(job: "j1", start: true, timelapse: true)                       // 0
        try await api.send(job: "j1", start: false)                                       // 1
        try await api.markRelayed(job: "j1", start: true, file: "a.gcode")               // 2
        try await api.observe(["cc": PrinterStatus(kind: .active), "off": nil])          // 3
        _ = try await api.pairBridge(code: "K7Q4-M2ZX")                                    // 4
        let added = try await api.bridgeAddPrinter(bridge: "b1", PrinterSettings(name: "CC", type: "elegoo_sdcp", cosmos: false),
                                                   sealed: "blob")                         // 5
        try await api.bridgePrinterAccess(printer: "cc", sealed: "blob2")                 // 6
        let found = try await api.bridgeDiscover(id: "b1")                                // 7
        try await api.createBooking(BookingRequest(printer: "cc", file: "a.gcode",
                                                   uses: [.init(spool: 3, grams: 11.4, label: "#3")],
                                                   printerName: "CC", job: "j1"))       // 8
        _ = try await api.observeBookings(["cc": nil])                                     // 9
        try await api.resolveBooking(id: "o", part: 0.3)                                   // 10
        let orca = try await api.createOrcaUpload(printer: "cc")                           // 11
        try await api.deleteBridge(id: "b1")                                               // 12
        let video = await api.timelapseURL(job: "j1")

        let r = seen.all
        XCTAssertEqual(body(r[0])?["timelapse"] as? Bool, true)
        XCTAssertNil(body(r[1])?["timelapse"])
        let relayed = try XCTUnwrap(body(r[2]))
        XCTAssertEqual(r[2].url?.path, "/api/jobs/j1/relayed")
        XCTAssertEqual(relayed["file"] as? String, "a.gcode")
        XCTAssertEqual(relayed["start"] as? Bool, true)
        let statuses = try XCTUnwrap(body(r[3])?["statuses"] as? [String: Any])
        XCTAssertEqual((statuses["cc"] as? [String: Any])?["kind"] as? String, "active")
        XCTAssertTrue(statuses["off"] is NSNull)
        XCTAssertEqual(body(r[4])?["code"] as? String, "K7Q4-M2ZX")
        let add = try XCTUnwrap(body(r[5]))
        XCTAssertEqual(add["sealed"] as? String, "blob")
        XCTAssertEqual((add["printer"] as? [String: Any])?["name"] as? String, "CC")
        XCTAssertEqual(added.bridge, "b1")
        XCTAssertEqual(r[6].httpMethod, "PUT")
        XCTAssertEqual(r[6].url?.path, "/api/printers/cc/bridge-access")
        XCTAssertEqual(body(r[6])?["sealed"] as? String, "blob2")
        XCTAssertEqual(found.map(\.address), ["cc.local"])
        let booking = try XCTUnwrap(body(r[8]))
        XCTAssertEqual(booking["printer_name"] as? String, "CC")
        XCTAssertEqual(booking["job"] as? String, "j1")
        XCTAssertEqual(((booking["uses"] as? [[String: Any]])?.first)?["grams"] as? Double, 11.4)
        XCTAssertTrue((body(r[9])?["statuses"] as? [String: Any])?["cc"] is NSNull)
        XCTAssertEqual(r[10].url?.path, "/api/bookings/o/resolve")
        XCTAssertEqual(body(r[10])?["part"] as? Double, 0.3)
        XCTAssertEqual(r[11].httpMethod, "POST")
        XCTAssertEqual(orca.key, "secret")
        XCTAssertEqual(r[12].httpMethod, "DELETE")
        XCTAssertEqual(video?.absoluteString, "http://home.test:8484/api/jobs/j1/timelapse?token=tok")
    }

    func testNewErrorRules() {
        func check(_ detail: String, _ key: L10nKey, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertEqual(friendlyError(l, status: 400, detail: detail), l(key), detail, file: file, line: line)
        }
        check("PrusaLink rejected the password", .errLanAuth)
        check("Enter the OctoPrint API key", .errLanAuth)
        check("printer not connected in OctoPrint", .errLanOcto)
        check("printer stored the file but did not start", .errNotStarted)
        check("The printer is not reachable on the Wi-Fi", .errLanOffline)
        check("PrusaLink answered HTTP 500", .errLanOffline)
        check("the bridge is offline", .errBridgeOffline)
        check("the bridge didn't answer in time", .errBridgeTimeout)
        check("unknown or expired code", .errBridgeCode)
        check("this printer is set up on the server at home itself", .errBridgeServerPrinter)
        check("bundle not found or private", .errOrcaPrivate)
        // the app's own messages come before the 401 rule: a printer's "rejected the API key" is not the server key
        XCTAssertEqual(friendlyError(l, status: 401, detail: "OctoPrint rejected the API key"), l(.errLanAuth))
        XCTAssertEqual(errorText(l, LanError("the bridge went offline")), l(.errBridgeOffline))
        XCTAssertEqual(errorText(l, APIError(message: "as is", status: 500, detail: "bridge is offline")), "as is")
    }
}

/// Requests seen by the stub, readable from async tests (NSLock can't be used there directly).
private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [URLRequest] = []
    func add(_ r: URLRequest) { lock.lock(); list.append(r); lock.unlock() }
    var all: [URLRequest] { lock.lock(); defer { lock.unlock() }; return list }
}
