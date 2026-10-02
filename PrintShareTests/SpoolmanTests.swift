import XCTest
@testable import PrintShare

/// Server 0.16.0-0.17.1: Spoolman (spool per colour, booking after the print), cloud spools, MakerWorld links.
/// Rules from the Expo app's `lib/spoolman.ts` and `job/[id].tsx` (upstream be72d42).
final class SpoolmanTests: XCTestCase {
    private let l = L10n(lang: .en)

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

    // MARK: Spoolman client

    func testSpoolFromSpoolmanJSON() throws {
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(#"""
        {"id": 3, "remaining_weight": 640.5, "initial_weight": 1000, "location": "Shelf", "archived": false,
         "filament": {"name": "Rapid PLA+", "material": "PLA", "color_hex": "1a2b3c", "weight": 1000,
                      "vendor": {"name": "Elegoo"}}}
        """#.utf8)) as? [String: Any])
        let s = try XCTUnwrap(Spool(json: raw))
        XCTAssertEqual(s.id, 3)
        XCTAssertEqual(s.color, "#1A2B3C")
        XCTAssertEqual(s.remainingG, 640.5)
        XCTAssertEqual(s.filamentG, 1000)
        XCTAssertEqual(s.label, "#3 Elegoo Rapid PLA+")
        XCTAssertFalse(s.isEmpty)
        // multi colour: first one; no name -> material
        let multi = try XCTUnwrap(Spool(json: ["id": 4, "remaining_weight": 0,
                                               "filament": ["material": "PETG", "multi_color_hexes": "FF0000,00FF00"]]))
        XCTAssertEqual(multi.color, "#FF0000")
        XCTAssertEqual(multi.label, "#4 PETG")
        XCTAssertTrue(multi.isEmpty)
        XCTAssertNil(Spool(json: ["filament": [String: Any]()]))
    }

    func testAddressCandidates() {
        XCTAssertEqual(Spoolman(address: "192.168.1.20").addresses, ["http://192.168.1.20", "http://192.168.1.20:7912"])
        XCTAssertEqual(Spoolman(address: "http://pi.local:7912/api/v1/").addresses, ["http://pi.local:7912"])
        XCTAssertEqual(Spoolman(address: "https://ha.local/spoolman").addresses, ["https://ha.local/spoolman"])
        let cloud = Spoolman.open(server: Server(url: "https://cloud.test/", token: "pp3d_x", cloud: true, email: "a@b.de"),
                                  setting: Spoolman.cloudSetting)
        XCTAssertEqual(cloud.addresses, ["https://cloud.test/spoolman"])
    }

    func testProbeListAndBook() async throws {
        var seen: [URLRequest] = []
        let lock = NSLock()
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            let path = req.url?.path ?? ""
            if req.url?.port != 7912 { return StubResponse(status: 404) }   // only the default port answers
            if path == "/api/v1/info" { return StubResponse(body: Data(#"{"version": "0.22.1"}"#.utf8)) }
            if path == "/api/v1/spool" {
                return StubResponse(body: Data(#"""
                [{"id": 1, "remaining_weight": 0, "filament": {"material": "PLA"}},
                 {"id": 2, "remaining_weight": 500, "filament": {"material": "PETG"}},
                 {"id": 5, "archived": true, "remaining_weight": 800, "filament": {"material": "ABS"}}]
                """#.utf8))
            }
            if path == "/api/v1/spool/9/use" { return StubResponse(status: 404) }
            return StubResponse(body: Data("{}".utf8))
        }
        let sm = Spoolman(address: "spool.test", session: StubProtocol.session())
        let info = try await sm.info()
        XCTAssertEqual(info.version, "0.22.1")
        XCTAssertEqual(info.base, "http://spool.test:7912")
        let list = try await sm.spools()
        XCTAssertEqual(list.map(\.id), [2, 1])          // empty last, archived dropped
        try await sm.use(spool: 2, grams: 11.36)
        do {
            try await sm.use(spool: 9, grams: 1)
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("#9"))
        }
        let r = lock.withLock { seen }
        let use = try XCTUnwrap(r.first { $0.url?.path == "/api/v1/spool/2/use" })
        XCTAssertEqual(use.httpMethod, "PUT")
        XCTAssertEqual(body(use)?["use_weight"] as? Double, 11.4)
        let listed = try XCTUnwrap(r.first { $0.url?.path == "/api/v1/spool" })
        XCTAssertTrue(listed.url?.query?.contains("allow_archived=false") == true)
    }

    func testCloudSpoolsSendTokenAndInput() async throws {
        var seen: [URLRequest] = []
        let lock = NSLock()
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            if req.url?.path == "/spoolman/api/v1/info" { return StubResponse(body: Data(#"{"version": "0.17.1"}"#.utf8)) }
            return StubResponse(body: Data(#"{"id": 7, "filament": {"material": "PLA"}}"#.utf8))
        }
        let server = Server(url: "https://cloud.test", token: "pp3d_x", cloud: true, email: "a@b.de")
        let sm = Spoolman.open(server: server, setting: Spoolman.cloudSetting, session: StubProtocol.session())
        let input = SpoolInput(filament: .init(name: nil, vendor: "Elegoo", material: "PLA", colorHex: "#000000", weight: 1000),
                               remainingWeight: nil, location: "Shelf", comment: nil, archived: nil)
        let made = try await sm.create(input)
        XCTAssertEqual(made?.id, 7)
        try await sm.remove(7)
        let r = lock.withLock { seen }
        XCTAssertTrue(r.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer pp3d_x" })
        let post = try XCTUnwrap(r.first { $0.httpMethod == "POST" })
        let b = try XCTUnwrap(body(post))
        let f = try XCTUnwrap(b["filament"] as? [String: Any])
        XCTAssertTrue(f["name"] is NSNull)               // cleared field sent as null
        XCTAssertEqual(f["color_hex"] as? String, "#000000")
        XCTAssertEqual(b["location"] as? String, "Shelf")
        XCTAssertTrue(b["comment"] is NSNull)
        XCTAssertNil(b["remaining_weight"])               // left out = unchanged
        XCTAssertNil(b["archived"])
        XCTAssertEqual(r.last?.httpMethod, "DELETE")
        XCTAssertEqual(r.last?.url?.path, "/spoolman/api/v1/spool/7")
    }

    func testArchiveOnlyBody() throws {
        let data = try JSONEncoder().encode(SpoolInput(filament: nil, remainingWeight: nil, location: nil, comment: nil,
                                                       archived: true))
        let b = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(b.keys.sorted(), ["archived"])
    }

    func testFormNumbersAndColours() {
        XCTAssertEqual(SpoolFormView.number("12,5"), 12.5)
        XCTAssertNil(SpoolFormView.number(""))
        XCTAssertNil(SpoolFormView.number("-3"))
        XCTAssertEqual(SpoolFormView.hex("a1b2c3"), "#A1B2C3")
        XCTAssertNil(SpoolFormView.hex("#12345"))
    }

    // MARK: server and printer shapes

    func testStatusSpoolmanAndLaneSpool() throws {
        let st = try JSONDecoder().decode(PrinterStatus.self, from: Data(#"""
        {"kind": "idle", "spoolman": {"connected": true, "spool_id": 3},
         "lanes": [{"id": "lane1", "tool": 0, "loaded": true, "spool_id": 12}, {"id": "lane2", "tool": 1}]}
        """#.utf8))
        XCTAssertEqual(st.spoolman, SpoolmanLink(connected: true, spoolId: 3))
        XCTAssertEqual(st.lanes.map(\.spoolId), [12, nil])
        let none = try JSONDecoder().decode(PrinterStatus.self, from: Data(#"{"kind": "idle"}"#.utf8))
        XCTAssertNil(none.spoolman)
    }

    func testMoonrakerSpoolmanStatus() {
        XCTAssertEqual(MoonrakerPrinter.spoolman(["spoolman_connected": true, "spool_id": 4]),
                       SpoolmanLink(connected: true, spoolId: 4))
        XCTAssertEqual(MoonrakerPrinter.spoolman(["spoolman_connected": false, "spool_id": NSNull()]),
                       SpoolmanLink(connected: false, spoolId: nil))
        XCTAssertNil(MoonrakerPrinter.wholeNumber(2.5))
    }

    func testSendSpoolOnlyWithAStart() async throws {
        var seen: [URLRequest] = []
        let lock = NSLock()
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            return StubResponse(body: Data(#"{"ok": true}"#.utf8))
        }
        let api = APIClient(server: Server(url: "http://home.test:8484", token: "tok"), l10n: l,
                            session: StubProtocol.session(), cache: RouteCache())
        try await api.send(job: "j1", start: true, spoolId: 3)
        try await api.send(job: "j1", start: false, spoolId: 3)
        let r = lock.withLock { seen }
        XCTAssertEqual(body(r[0])?["spool_id"] as? Int, 3)
        XCTAssertNil(body(r[1])?["spool_id"])
    }

    func testModelDetailMakerWorld() throws {
        let m = try JSONDecoder().decode(ModelDetail.self, from: Data(#"""
        {"source": "makerworld", "id": "123", "name": "Clip", "url": "https://makerworld.com/en/models/123",
         "download": "external",
         "variants": [{"id": 9, "title": "0.2 mm PLA", "default": true, "weight_g": 42, "print_hours": 2.5,
                       "materials": ["PLA"], "colors": ["#FF0000"], "needs_ams": true}]}
        """#.utf8))
        XCTAssertTrue(m.external)
        XCTAssertEqual(m.variants.first?.isDefault, true)
        XCTAssertEqual(ModelDetailView.variantLine(l, m.variants[0]), "PLA · 42 g · 2 h 30 min · \(l(.needsAms))")
        let old = try Fixture.decode(ModelDetail.self, "model")
        XCTAssertFalse(old.external)
        XCTAssertTrue(old.variants.isEmpty)
    }

    func testMakerWorldLinks() {
        XCTAssertEqual(Format.makerWorldId("https://makerworld.com/en/models/1234567-clip#profileId-1"), "1234567")
        XCTAssertEqual(Format.makerWorldId("look: https://makerworld.com/models/42"), "42")
        XCTAssertEqual(Format.makerWorldId("https://makerworld.com.cn/zh-cn/models/7"), "7")
        XCTAssertEqual(Format.printablesId("https://www.printables.com/model/3161-3d-benchy"), "3161")
        XCTAssertEqual(Format.printablesId("https://www.printables.com/de/model/42-clip/files"), "42")
        XCTAssertNil(Format.printablesId("https://www.printables.com/@user/collections/123"))
        XCTAssertNil(Format.printablesId(nil))
        XCTAssertNil(Format.makerWorldId("https://www.printables.com/model/3161-3d-benchy"))
    }

    // MARK: spool per colour

    private let pla = Spool(id: 3, name: "Black", vendor: "Elegoo", material: "PLA", remainingG: 8)
    private let petg = Spool(id: 4, name: "", material: "PETG", remainingG: 900)

    func testSpoolChoiceOrder() {
        let cols = [SpoolPlan.Colour(index: 1, preset: "Elegoo PLA @ECC", grams: 10)]
        let lanes = [Lane(id: "lane1", tool: 0)]
        var withSpool = lanes
        withSpool[0].spoolId = 4
        let known = [pla, petg]
        let tracker = SpoolmanLink(connected: true, spoolId: 3)
        // last used
        XCTAssertEqual(SpoolPlan.spools(colours: cols, lanes: [], tools: [:], afc: false, choice: [:], tracker: nil,
                                        last: ["1": 4], known: known), [1: 4])
        // Moonraker's active spool before the last one
        XCTAssertEqual(SpoolPlan.spools(colours: cols, lanes: [], tools: [:], afc: false, choice: [:], tracker: tracker,
                                        last: ["1": 4], known: known), [1: 3])
        // lane spool first, the user's choice wins, "none" clears
        XCTAssertEqual(SpoolPlan.spools(colours: cols, lanes: withSpool, tools: [1: 0], afc: false, choice: [:],
                                        tracker: tracker, last: [:], known: known), [1: 4])
        XCTAssertEqual(SpoolPlan.spools(colours: cols, lanes: withSpool, tools: [1: 0], afc: false, choice: [1: 3],
                                        tracker: tracker, last: [:], known: known), [1: 3])
        XCTAssertEqual(SpoolPlan.spools(colours: cols, lanes: withSpool, tools: [1: 0], afc: false,
                                        choice: [1: SpoolPlan.none], tracker: tracker, last: [:], known: known), [:])
        // AFC: only the slot's spool
        XCTAssertEqual(SpoolPlan.spools(colours: cols, lanes: lanes, tools: [1: 0], afc: true, choice: [1: 3],
                                        tracker: tracker, last: [:], known: known), [:])
        // spools that no longer exist are dropped
        XCTAssertEqual(SpoolPlan.spools(colours: cols, lanes: [], tools: [:], afc: false, choice: [:], tracker: nil,
                                        last: ["1": 99], known: known), [:])
    }

    func testWarningsAndUses() {
        let cols = [SpoolPlan.Colour(index: 1, preset: "Elegoo PLA @ECC", grams: 10),
                    SpoolPlan.Colour(index: 2, preset: "Elegoo PLA @ECC", grams: 2)]
        let w = SpoolPlan.warnings(l, colours: cols, spoolFor: [1: 3, 2: 4], known: [pla, petg])
        XCTAssertEqual(w.count, 2)
        XCTAssertTrue(w[0].contains("8 g") && w[0].contains("10.0"))
        XCTAssertTrue(w[1].contains("PETG"))
        let uses = SpoolPlan.uses(colours: cols, spoolFor: [1: 3], known: [pla, petg])
        XCTAssertEqual(uses, [BookingUse(spool: 3, grams: 10, label: "#3 Elegoo Black")])
    }

    // MARK: bookings

    private func booking(created: Double = 0, seen: Bool? = nil, progress: Double? = nil) -> Booking {
        Booking(id: "b1", printer: "p", printerName: "COSMOS", file: "3DBenchy.gcode",
                uses: [BookingUse(spool: 3, grams: 10, label: "#3")], created: created, seen: seen, progress: progress)
    }

    private func status(_ kind: PrinterKind, file: String?, progress: Double? = nil) -> PrinterStatus {
        var s = PrinterStatus(kind: kind)
        s.file = file
        s.progress = progress
        return s
    }

    func testSameFile() {
        XCTAssertTrue(Bookings.sameFile("/usb/3DBENC~1.gcode", "3DBENC~1.bco"))
        XCTAssertTrue(Bookings.sameFile("gcodes/3d_benchy.gcode", "3D Benchy.gcode"))
        XCTAssertFalse(Bookings.sameFile(nil, "a.gcode"))
        XCTAssertFalse(Bookings.sameFile("x.gcode", "y.gcode"))
    }

    func testJudge() {
        let b = booking()
        let printing = Bookings.judge(b, status(.active, file: "3DBenchy.gcode", progress: 40), now: 1000)
        XCTAssertEqual(printing.seen, true)
        XCTAssertEqual(printing.progress, 40)
        XCTAssertEqual(Bookings.judge(printing, status(.done, file: "3DBenchy.gcode"), now: 2000).ready, true)
        XCTAssertEqual(Bookings.judge(printing, status(.stopped, file: "3DBenchy.gcode"), now: 2000).ask?.part, 0.4)
        // vanished after being seen almost done -> book; earlier -> ask
        XCTAssertEqual(Bookings.judge(booking(seen: true, progress: 99.5), status(.idle, file: nil), now: 1).ready, true)
        XCTAssertEqual(Bookings.judge(booking(seen: true, progress: 50), status(.idle, file: "other.gcode"), now: 1).ask?.part, 0.5)
        // never seen: wait 20 min, then ask for all
        XCTAssertNil(Bookings.judge(b, status(.idle, file: nil), now: Bookings.waitStart - 1).ask)
        XCTAssertEqual(Bookings.judge(b, status(.idle, file: nil), now: Bookings.waitStart + 1).ask?.part, 1)
        // offline: give up after 3 days
        XCTAssertNil(Bookings.judge(b, nil, now: 1000).ask)
        XCTAssertEqual(Bookings.judge(b, nil, now: Bookings.giveUp + 1).ask?.part, 1)
    }

    func testAddingReplacesUnstartedBookingOfThePrinter() {
        var started = booking(seen: true)
        started.id = "started"
        var waiting = booking()
        waiting.id = "waiting"
        var other = booking()
        other.id = "other"
        other.printer = "q"
        var new = booking()
        new.id = "new"
        XCTAssertEqual(Bookings.adding(new, to: [started, waiting, other]).map(\.id), ["started", "other", "new"])
        var empty = new
        empty.uses = []
        XCTAssertEqual(Bookings.adding(empty, to: [waiting]).map(\.id), ["waiting"])
        let many = (0..<25).map { i -> Booking in var x = booking(seen: true); x.id = "\(i)"; return x }
        XCTAssertEqual(Bookings.adding(new, to: many).count, Bookings.maxCount)
    }

    func testBookingJSONMatchesExpo() throws {
        let b = try JSONDecoder().decode(Booking.self, from: Data(#"""
        {"id": "a1", "printer": "p", "printerName": "CC", "file": "x.gcode", "created": 1759390000000,
         "uses": [{"spool": 3, "grams": 11.4, "label": "#3 PLA"}], "seen": true, "progress": 12, "ask": {"part": 0.12}}
        """#.utf8))
        XCTAssertEqual(b.grams, 11.4)
        XCTAssertEqual(b.ask?.part, 0.12)
        XCTAssertEqual(BookingCard.bookedText(l, b), l(.booked, ["g": "11.4", "spool": "#3 PLA"]))
    }
}
