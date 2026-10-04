import XCTest
@testable import PrintShare

/// Server 0.29.0-0.36.0: spool bookings in the account, jobs follow their print, time-lapse, send from OrcaSlicer,
/// Bambu Lab through a bridge, own camera. Shapes from the server's `printshare/api.py` and `docs/API.md`.
final class ServerThirtySixTests: XCTestCase {
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

    private func json(_ req: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(bodyData(req))) as? [String: Any])
    }

    // MARK: models

    func testJobStatesOfAFollowedPrint() throws {
        for (raw, state) in [("finished", JobState.finished), ("cancelled", .cancelled), ("uploading", .uploading),
                             ("started", .started), ("from-the-future", .unknown)] {
            let j = try JSONDecoder().decode(Job.self, from: Data(#"{"id": "j1", "state": "\#(raw)"}"#.utf8))
            XCTAssertEqual(j.state, state, raw)
        }
        XCTAssertEqual(JobBadge.kind(.finished), .ok)
        XCTAssertEqual(JobBadge.kind(.cancelled), .warn)
        XCTAssertEqual(JobBadge.kind(.started), .accent)
        XCTAssertEqual(l.jobState("finished"), "Printed")
    }

    func testJobWithTimelapseAndPrinterFile() throws {
        let j = try JSONDecoder().decode(Job.self, from: Data(#"""
        {"id": "j1", "state": "started", "printer_file": "cone.gcode",
         "timelapse": {"state": "recording", "frames": 12}}
        """#.utf8))
        XCTAssertEqual(j.printerFile, "cone.gcode")
        XCTAssertEqual(j.timelapse, Timelapse(state: .recording, frames: 12))
        let failed = try JSONDecoder().decode(Job.self, from: Data(#"""
        {"id": "j2", "state": "finished", "timelapse": {"state": "failed", "frames": 0, "error": "no camera"}}
        """#.utf8))
        XCTAssertEqual(failed.timelapse?.error, "no camera")
        let odd = try JSONDecoder().decode(Job.self, from: Data(#"{"id": "j3", "state": "sliced", "timelapse": {"state": "x"}}"#.utf8))
        XCTAssertEqual(odd.timelapse?.state, .unknown)
        XCTAssertNil(try JSONDecoder().decode(Job.self, from: Data(#"{"id": "j4", "state": "sliced"}"#.utf8)).timelapse)
    }

    func testServerBookingsBecomeLocalBookings() throws {
        let r = try JSONDecoder().decode(ServerBookings.self, from: Data(#"""
        {"waiting": [{"id": "w1", "printer": "p1", "printer_name": "COSMOS", "file": "benchy.gcode", "job": "j1",
                      "uses": [{"spool": 3, "grams": 11.4, "label": "#3 Elegoo PLA"}], "booked_uses": [],
                      "created": 1760000000, "seen": false, "progress": null, "state": "wait", "ask_part": null}],
         "open": [{"id": "o1", "printer": "p1", "printer_name": null, "file": "cone.gcode",
                   "uses": [{"spool": 3, "grams": 10}], "booked_uses": [], "created": 1760000100, "seen": true,
                   "progress": 40, "state": "ask", "ask_part": 0.4}],
         "booked": [{"id": "b1", "printer": "p1", "file": "x.gcode", "uses": [{"spool": 3, "grams": 5, "label": "A"}],
                     "booked_uses": [{"spool": 3, "grams": 5, "label": "A"}], "created": 1, "seen": true,
                     "progress": 100, "state": "booked"}]}
        """#.utf8))
        XCTAssertEqual(r.waiting.count, 1)
        let w = r.waiting[0].booking
        XCTAssertEqual(w.printerName, "COSMOS")
        XCTAssertEqual(w.created, 1_760_000_000_000)          // seconds from the server, ms in the app
        XCTAssertNil(w.ask)
        XCTAssertEqual(w.account, true)
        let o = r.open[0].booking
        XCTAssertEqual(o.printerName, "p1")                   // no name: the id
        XCTAssertEqual(o.ask?.part, 0.4)
        XCTAssertEqual(o.uses[0].label, "#3")                 // label missing: the spool number
        XCTAssertEqual(r.booked[0].booking.uses.first?.grams, 5)
        XCTAssertTrue(r.bookedNow.isEmpty)
    }

    func testBookingsObserveAnswerHasBookedNow() throws {
        let r = try JSONDecoder().decode(ServerBookings.self, from: Data(#"""
        {"waiting": [], "open": [], "booked": [],
         "booked_now": [{"id": "b1", "printer": "p", "file": "f", "uses": [], "booked_uses": [{"spool": 1, "grams": 2}],
                         "created": 1, "seen": true, "state": "booked"}]}
        """#.utf8))
        XCTAssertEqual(r.bookedNow.map(\.id), ["b1"])
        XCTAssertEqual(r.bookedNow[0].booking.grams, 2)
    }

    func testBridgeFoundCarriesTheBambuModel() throws {
        let f = try JSONDecoder().decode(BridgeFound.self, from: Data(#"""
        {"type": "bambu_lan", "address": "192.168.86.53", "name": "01P00A", "machine": "Bambu Lab P1S 0.4 nozzle", "added": false}
        """#.utf8))
        XCTAssertEqual(f.machine, "Bambu Lab P1S 0.4 nozzle")
        XCTAssertTrue(Lan.bridgeTypes.contains(f.type))
        XCTAssertFalse(Lan.types.contains(f.type))            // the phone can't drive it itself
        XCTAssertNil(try JSONDecoder().decode(BridgeFound.self, from: Data(#"{"type": "moonraker", "address": "a"}"#.utf8)).machine)
    }

    func testOrcaUploadDecoding() throws {
        let on = try JSONDecoder().decode(OrcaUpload.self, from: Data(#"""
        {"enabled": true, "url": "https://api.pocketprint3d.com/octoprint", "created": 1760000000, "last_used": null}
        """#.utf8))
        XCTAssertTrue(on.enabled)
        XCTAssertNil(on.key)
        XCTAssertNil(on.lastUsed)
        let created = try JSONDecoder().decode(OrcaUpload.self, from: Data(#"{"enabled": true, "url": "u", "key": "pp3do_abc"}"#.utf8))
        XCTAssertEqual(created.key, "pp3do_abc")
    }

    // MARK: requests

    func testSendAsksForATimelapseOnlyWithAPrintStart() async throws {
        var seen: [URLRequest] = []
        let lock = NSLock()
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            return StubResponse(body: Data(#"{"job": "j1"}"#.utf8))
        }
        let api = cloudClient()
        try await api.send(job: "j1", start: true, timelapse: true)
        try await api.send(job: "j1", start: true)
        try await api.send(job: "j1", start: false, timelapse: true)
        XCTAssertEqual(try json(seen[0])["timelapse"] as? Bool, true)
        XCTAssertNil(try json(seen[1])["timelapse"])
        XCTAssertNil(try json(seen[2])["timelapse"])
    }

    func testRelayedAndObserveRequests() async throws {
        var seen: [URLRequest] = []
        let lock = NSLock()
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            return StubResponse(body: Data(#"{"state": "started"}"#.utf8))
        }
        let api = cloudClient()
        try await api.markRelayed(job: "j 1", start: true, file: "cone.gcode")
        try await api.observe(["p1": PrinterStatus(kind: .active, state: "printing"), "p2": nil])
        XCTAssertEqual(seen.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, ["POST /api/jobs/j%201/relayed", "POST /api/observe"])
        let relayed = try json(seen[0])
        XCTAssertEqual(relayed["start"] as? Bool, true)
        XCTAssertEqual(relayed["file"] as? String, "cone.gcode")
        let statuses = try XCTUnwrap(try json(seen[1])["statuses"] as? [String: Any])
        XCTAssertEqual((statuses["p1"] as? [String: Any])?["kind"] as? String, "active")
        XCTAssertTrue(statuses["p2"] is NSNull)               // unreachable = null, so the server knows it was asked
    }

    func testBookingRequests() async throws {
        var seen: [URLRequest] = []
        let lock = NSLock()
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            switch req.url?.path ?? "" {
            case "/api/bookings": return StubResponse(body: Data(#"{"waiting": [], "open": [], "booked": []}"#.utf8))
            case "/api/bookings/observe":
                return StubResponse(body: Data(#"{"waiting": [], "open": [], "booked": [], "booked_now": []}"#.utf8))
            default: return StubResponse(body: Data(#"{"booking": null}"#.utf8))
            }
        }
        let api = cloudClient()
        _ = try await api.bookings()
        try await api.createBooking(printer: "p1", printerName: "COSMOS", file: "cone.gcode",
                                    uses: [BookingUse(spool: 3, grams: 11.4, label: "#3")], job: "j1")
        _ = try await api.observeBookings(["p1": nil])
        try await api.resolveBooking(id: "b1", part: 0.4)
        XCTAssertEqual(seen.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, [
            "GET /api/bookings", "POST /api/bookings", "POST /api/bookings/observe", "POST /api/bookings/b1/resolve"])
        let create = try json(seen[1])
        XCTAssertEqual(create["printer_name"] as? String, "COSMOS")
        XCTAssertEqual(create["job"] as? String, "j1")
        let uses = try XCTUnwrap(create["uses"] as? [[String: Any]])
        XCTAssertEqual(uses.first?["spool"] as? Int, 3)
        XCTAssertEqual(try json(seen[3])["part"] as? Double, 0.4)
    }

    func testBookingPostsAreNeverRepeated() async {
        StubProtocol.install { _ in StubResponse(error: URLError(.timedOut)) }
        try? await cloudClient().createBooking(printer: "p", printerName: "P", file: "f", uses: [], job: nil)
        XCTAssertEqual(StubProtocol.requests.filter { $0.method == "POST" }.count, 1)
    }

    func testOrcaUploadRequests() async throws {
        var seen: [URLRequest] = []
        let lock = NSLock()
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            return StubResponse(body: Data(#"{"enabled": true, "url": "u", "key": "pp3do_k", "deleted": true}"#.utf8))
        }
        let api = cloudClient()
        _ = try await api.orcaUpload(printer: "p1")
        let made = try await api.createOrcaUpload(printer: "p1")
        try await api.deleteOrcaUpload(printer: "p1")
        XCTAssertEqual(seen.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" }, [
            "GET /api/printers/p1/orca-upload", "POST /api/printers/p1/orca-upload", "DELETE /api/printers/p1/orca-upload"])
        XCTAssertEqual(made.key, "pp3do_k")
    }

    func testDiscoverSendsThePhonesWifiAsAHint() async throws {
        var seen: [URLRequest] = []
        let lock = NSLock()
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            return StubResponse(body: Data("[]".utf8))
        }
        let api = cloudClient()
        _ = try await api.bridgeDiscover(id: "b-1", subnet: "192.168.86.0/24")
        _ = try await api.bridgeDiscover(id: "b-1")
        XCTAssertEqual(try json(seen[0])["subnet"] as? String, "192.168.86.0/24")
        XCTAssertNil(bodyData(seen[1]))
    }

    func testTimelapseRequestUsesTheHeaderNotTheURL() async throws {
        let api = cloudClient()
        let target = try await XCTUnwrap(api.timelapseRequest(job: "j1"))
        XCTAssertEqual(target.url.absoluteString, "https://cloud.test/api/jobs/j1/timelapse")
        XCTAssertEqual(target.headers["Authorization"], "Bearer pp3d_x")
    }

    // MARK: sealing and Wi-Fi

    func testOwnCameraIsSealedWithTheServersFieldName() throws {
        let data = try JSONEncoder().encode(Seal.Secrets(address: "a", cameraUrl: "rtsp://u:p@1.2.3.4/live"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(obj.keys), ["address", "camera_url"])
        // "" removes the camera on the bridge, so it must be sent and not left out
        let removal = try JSONEncoder().encode(Seal.Secrets(cameraUrl: ""))
        XCTAssertEqual(try XCTUnwrap(JSONSerialization.jsonObject(with: removal) as? [String: String])["camera_url"], "")
    }

    func testWifiSubnet() {
        XCTAssertEqual(WifiSubnet.subnet(address: "192.168.86.23", prefix: 24), "192.168.86.0/24")
        XCTAssertEqual(WifiSubnet.subnet(address: "192.168.86.130", prefix: 25), "192.168.86.128/25")
        XCTAssertEqual(WifiSubnet.subnet(address: "10.1.2.3", prefix: 16), "10.1.2.0/24")      // wider than /24: searched as /24
        XCTAssertEqual(WifiSubnet.subnet(address: "10.1.2.3", prefix: 0), "10.1.2.0/24")
        XCTAssertNil(WifiSubnet.subnet(address: "fe80::1", prefix: 64))
        XCTAssertNil(WifiSubnet.subnet(address: "300.1.2.3", prefix: 24))
        XCTAssertNil(WifiSubnet.subnet(address: "1.2.3", prefix: 24))
    }

    func testTextsOfThisSync() {
        let en = L10n(lang: .en), de = L10n(lang: .de)
        XCTAssertEqual(en(.printAgain), "Print again")
        XCTAssertEqual(de(.timelapseRecording, ["n": "12"]), "Zeitraffer läuft (Bilder: 12)")
        XCTAssertEqual(en(.timelapseFailed, ["error": "no camera"]), "No time-lapse: no camera")
        XCTAssertFalse(en.printerTypeName("bambu_lan").isEmpty)
    }
}
