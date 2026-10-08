import XCTest
@testable import PrintShare

/// Server 0.37.0 (filament per slot), 0.38.0 (spools by NFC chip and per slot, NFC readers) and 0.39.0 (spool source,
/// import from Spoolman). Shapes from the server's `docs/API.md`; the OpenPrintTag image follows specs.openprinttag.org
/// like the Expo app's `make_openprinttag_tags.py`.
final class ServerThirtyNineTests: XCTestCase {
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

    // MARK: filament per slot (0.37.0)

    func testFilamentInfoDecodesBambu() throws {
        let info = try JSONDecoder().decode(FilamentInfo.self, from: Data(#"""
        {"supported": true, "load": true, "unload": true, "set": true, "external": true, "busy": false,
         "slots": [{"id": "A1", "tool": 0, "unit": "AMS 1", "material": "PLA", "color": "#FF0000", "filament": "Generic PLA",
                    "loaded": true, "in_toolhead": true},
                   {"id": "A2", "tool": 1, "material": null, "color": "", "loaded": false, "in_toolhead": false},
                   {"id": "Ext", "tool": 254, "material": "PETG", "color": "#00FF00", "loaded": true, "in_toolhead": false}],
         "materials": [{"name": "PLA", "type": "PLA", "temp_min": 190, "temp_max": 230, "load_temp": 220},
                       {"name": "PLA Silk", "type": "PLA", "temp_min": 200, "temp_max": 230, "load_temp": 225},
                       {"name": "PETG", "type": "PETG", "temp_min": 220, "temp_max": 260, "load_temp": 250}]}
        """#.utf8))
        XCTAssertTrue(info.supported && info.load && info.unload && info.set && info.external)
        XCTAssertEqual(info.slots.map(\.tool), [0, 1, 254])
        XCTAssertTrue(info.slots[0].inToolhead)
        XCTAssertNil(info.slots[1].material)
        XCTAssertEqual(info.loadTemp(info.slots[2]), 250)
        XCTAssertEqual(info.loadTemp(info.slots[1]), 220)       // unknown material: the first one's
        XCTAssertEqual(info.material(forSpool: "petg")?.name, "PETG")
        XCTAssertEqual(info.material(forSpool: "PLA Silk")?.name, "PLA Silk")
        XCTAssertNil(info.material(forSpool: nil))

        let none = try JSONDecoder().decode(FilamentInfo.self, from: Data(
            #"{"supported": false, "slots": [], "materials": [], "load": false, "unload": false, "set": false}"#.utf8))
        XCTAssertFalse(none.supported)
        XCTAssertEqual(FilamentInfo(supported: false).loadTemp(nil), 220)
    }

    func testFilamentRequestShapes() async throws {
        let lock = NSLock()
        var seen: [URLRequest] = []
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            return StubResponse(body: Data(#"{"ok": true}"#.utf8))
        }
        let api = client()
        try await api.filament(printer: "p1s", .load(2))
        try await api.filament(printer: "p1s", .unload)
        try await api.filament(printer: "p1s", .set(254, material: "PETG", color: "#00FF00"))

        let r = lock.withLock { seen }
        XCTAssertEqual(r[0].httpMethod, "POST")
        XCTAssertEqual(r[0].url?.path, "/api/printers/p1s/filament")
        XCTAssertEqual(body(r[0])?["action"] as? String, "load")
        XCTAssertEqual(body(r[0])?["slot"] as? Int, 2)
        XCTAssertEqual(body(r[0])?["confirm"] as? Bool, true)     // loading heats the nozzle: confirmed before
        XCTAssertEqual(body(r[1])?["action"] as? String, "unload")
        XCTAssertNil(body(r[1])?["slot"])
        XCTAssertEqual(body(r[1])?["confirm"] as? Bool, true)
        XCTAssertEqual(body(r[2])?["material"] as? String, "PETG")
        XCTAssertEqual(body(r[2])?["color"] as? String, "#00FF00")
        XCTAssertNil(body(r[2])?["confirm"])
    }

    // MARK: spools by NFC chip and per slot (0.38.0)

    func testSlotSpoolsDecodeAndRequests() async throws {
        let s = try JSONDecoder().decode(SlotSpools.self, from: Data(#"""
        {"slots": {"0": {"spool": 12, "source": "app", "updated": 1760000000.5}, "3": {"spool": 4, "source": "reader"}},
         "scans": {"1": {"uid": "04A1B2C3D4E5F6", "spool": null, "at": 1760000001}}}
        """#.utf8))
        XCTAssertEqual(s.spools, [0: 12, 3: 4])
        XCTAssertEqual(s.scans["1"]?.uid, "04A1B2C3D4E5F6")
        XCTAssertNil(s.scans["1"]?.spool)

        let lock = NSLock()
        var seen: [URLRequest] = []
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            if req.url?.path.contains("slot-spools/") == true {
                return StubResponse(body: Data(#"{"slots": {"2": {"spool": 7, "source": "app"}}, "printer_set": true}"#.utf8))
            }
            if req.url?.path.hasSuffix("reader-key") == true {
                return StubResponse(body: Data(#"{"enabled": true, "url": "https://api.test/api/reader/scan", "key": "pp3dr_x"}"#.utf8))
            }
            if req.url?.path == "/api/spool-source" {
                return StubResponse(body: Data(#"{"source": "spoolman", "spoolman_url": "http://sm:7912", "server_reaches_spoolman": true, "bridges_set": 2}"#.utf8))
            }
            return StubResponse(body: Data(#"{"uid": "04A1", "spool": 7}"#.utf8))
        }
        let api = client()
        let set = try await api.setSlotSpool(printer: "p1s", tool: 2, spool: 7)
        XCTAssertTrue(set.printerSet)
        XCTAssertEqual(set.slots["2"]?.spool, 7)
        _ = try await api.setSlotSpool(printer: "p1s", tool: 2, spool: nil)
        try await api.linkSpoolTag(uid: "04A1", spool: 7)
        let key = try await api.createReaderKey(printer: "p1s")
        XCTAssertEqual(key.key, "pp3dr_x")
        let src = try await api.setSpoolSource("spoolman", spoolmanUrl: "http://sm:7912")
        XCTAssertEqual(src.bridgesSet, 2)
        _ = try await api.setSpoolSource("cloud")

        let r = lock.withLock { seen }
        XCTAssertEqual(r[0].httpMethod, "PUT")
        XCTAssertEqual(r[0].url?.path, "/api/printers/p1s/slot-spools/2")
        XCTAssertEqual(body(r[0])?["spool"] as? Int, 7)
        XCTAssertTrue(body(r[1])?["spool"] is NSNull)              // null takes the spool out of the slot
        XCTAssertEqual(r[2].httpMethod, "PUT")
        XCTAssertEqual(r[2].url?.path, "/api/spool-tags/04A1")
        XCTAssertEqual(body(r[2])?["spool"] as? Int, 7)
        XCTAssertEqual(r[3].httpMethod, "POST")
        XCTAssertEqual(r[3].url?.path, "/api/printers/p1s/reader-key")
        XCTAssertEqual(body(r[4])?["source"] as? String, "spoolman")
        XCTAssertEqual(body(r[4])?["spoolman_url"] as? String, "http://sm:7912")
        XCTAssertNil(body(r[5])?["spoolman_url"])
    }

    func testSlotSpoolIsTheDefaultForItsSlot() {
        let cols = [SpoolPlan.Colour(index: 1, preset: "Generic PLA", grams: 10)]
        let lanes = [Lane(id: "A1", tool: 0, material: "PLA"), Lane(id: "A2", tool: 1, material: "PLA")]
        // the spool put into the chosen slot wins over the last spool used
        XCTAssertEqual(SpoolPlan.spools(colours: cols, lanes: lanes, tools: [1: 1], afc: false, choice: [:], tracker: nil,
                                        last: ["1": 5], known: nil, slots: [1: 9]), [1: 9])
        // another slot's spool doesn't count
        XCTAssertEqual(SpoolPlan.spools(colours: cols, lanes: lanes, tools: [1: 0], afc: false, choice: [:], tracker: nil,
                                        last: ["1": 5], known: nil, slots: [1: 9]), [1: 5])
        // the user's own choice still wins
        XCTAssertEqual(SpoolPlan.spools(colours: cols, lanes: lanes, tools: [1: 1], afc: false, choice: [1: 3], tracker: nil,
                                        last: [:], known: nil, slots: [1: 9]), [1: 3])
    }

    // MARK: OpenPrintTag + chip numbers

    /// meta {0: 6, 2: 70}, main (Prusament PLA Galaxy Black, 1012 g, empty spool 193 g, #3D3E3F, 1.24 g/cm³),
    /// aux as an indefinite map {0: 112 g consumed, 4: "Shelf A"}.
    static let tag: [UInt8] = [
        0xE1, 0x40, 0x28, 0x01, 0x03, 0x73, 0xD2, 0x1C, 0x54, 0x61, 0x70, 0x70, 0x6C, 0x69, 0x63, 0x61, 0x74, 0x69, 0x6F,
        0x6E, 0x2F, 0x76, 0x6E, 0x64, 0x2E, 0x6F, 0x70, 0x65, 0x6E, 0x70, 0x72, 0x69, 0x6E, 0x74, 0x74, 0x61, 0x67, 0xA2,
        0x00, 0x06, 0x02, 0x18, 0x46, 0xAA, 0x08, 0x00, 0x09, 0x00, 0x0A, 0x70, 0x50, 0x4C, 0x41, 0x20, 0x47, 0x61, 0x6C,
        0x61, 0x78, 0x79, 0x20, 0x42, 0x6C, 0x61, 0x63, 0x6B, 0x0B, 0x69, 0x50, 0x72, 0x75, 0x73, 0x61, 0x6D, 0x65, 0x6E,
        0x74, 0x10, 0x19, 0x03, 0xE8, 0x11, 0x19, 0x03, 0xF4, 0x12, 0x18, 0xC1, 0x13, 0x43, 0x3D, 0x3E, 0x3F, 0x18, 0x1D,
        0xFA, 0x3F, 0x9E, 0xB8, 0x52, 0x18, 0x1E, 0xFA, 0x3F, 0xE0, 0x00, 0x00, 0xBF, 0x00, 0x18, 0x70, 0x04, 0x67, 0x53,
        0x68, 0x65, 0x6C, 0x66, 0x20, 0x41, 0xFF, 0xFE,
    ]

    func testOpenPrintTagParses() throws {
        // tags are read block by block: the rest of the memory is zeros
        let t = try OpenPrintTag.parse(Self.tag + [UInt8](repeating: 0, count: 198), uid: "E004")
        XCTAssertEqual(t.brand, "Prusament")
        XCTAssertEqual(t.name, "PLA Galaxy Black")
        XCTAssertEqual(t.materialType, "PLA")
        XCTAssertEqual(t.color, "#3D3E3F")
        XCTAssertEqual(t.fullWeight, 1012)
        XCTAssertEqual(t.consumedWeight, 112)
        XCTAssertEqual(t.remainingWeight, 900)
        XCTAssertEqual(t.emptySpoolWeight, 193)
        XCTAssertEqual(t.density ?? 0, 1.24, accuracy: 0.001)
        XCTAssertEqual(t.location, "Shelf A")
        XCTAssertEqual(t.label, "Prusament PLA Galaxy Black")
    }

    func testOpenPrintTagRejectsOtherData() {
        XCTAssertThrowsError(try OpenPrintTag.parse([0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]))
        // an NDEF text record instead of the OpenPrintTag MIME record
        let text: [UInt8] = [0xE1, 0x40, 0x28, 0x01, 0x03, 0x08, 0xD1, 0x01, 0x04, 0x54, 0x02, 0x65, 0x6E, 0x41, 0xFE]
        XCTAssertThrowsError(try OpenPrintTag.parse(text))
        // cut off in the middle of the payload
        XCTAssertThrowsError(try OpenPrintTag.parse(Array(Self.tag.prefix(60))))
    }

    func testCBORHalfFloatAndIndefiniteText() throws {
        XCTAssertEqual(try CBOR.decode([0xF9, 0x3C, 0x00], at: 0).value, .float(1))
        XCTAssertEqual(try CBOR.decode([0x7F, 0x62, 0x50, 0x4C, 0x61, 0x41, 0xFF], at: 0).value, .text("PLA"))
        XCTAssertEqual(try CBOR.decode([0x38, 0x18], at: 0).value, .int(-25))
    }

    func testChipNumberUsesAndroidByteOrder() {
        // ISO 15693: iOS reports E0 first, Android (and the server's links) the order received over the air
        XCTAssertEqual(NFC.uid(Data([0xE0, 0x04, 0x01, 0x50, 0x12, 0x34, 0x56, 0x78]), iso15693: true), "78563412500104E0")
        XCTAssertEqual(NFC.uid(Data([0x04, 0xA1, 0xB2, 0xC3, 0xD4, 0xE5, 0xF6]), iso15693: false), "04A1B2C3D4E5F6")
    }

    func testMatchSpoolByTag() throws {
        let t = try OpenPrintTag.parse(Self.tag)
        let spools = [
            Spool(id: 1, name: "Galaxy Black", vendor: "Prusament", material: "PETG", color: "#3D3E3F", remainingG: 900),
            Spool(id: 2, name: "PLA Galaxy Black", vendor: "Prusament", material: "PLA", color: "#3D3E3F", remainingG: 400),
            Spool(id: 3, name: "PLA Galaxy Black", vendor: "Prusament", material: "PLA", color: "#3D3E3F", remainingG: 880),
            Spool(id: 4, name: "Basic", vendor: "Elegoo", material: "PLA", color: "#FFFFFF", remainingG: 900),
        ]
        XCTAssertEqual(NFC.matchSpool(t, spools)?.id, 3)            // same material, brand, name, closest weight
        XCTAssertNil(NFC.matchSpool(t, [spools[0]]))                // another material never
        XCTAssertNil(NFC.matchSpool(t, [spools[3]]))                // only the material: not enough
    }

    // MARK: import from Spoolman (0.39.0)

    func testCloudInputFromSpoolman() throws {
        let raw: [String: Any] = [
            "id": 12, "remaining_weight": 640.5, "initial_weight": 1000, "spool_weight": 180, "location": "Shelf",
            "comment": "opened",
            "filament": ["name": "Rapid PLA+", "material": "PLA", "color_hex": "1a2b3c", "weight": 1000, "density": 1.24,
                         "vendor": ["name": "Elegoo"]],
        ]
        let input = Spoolman.cloudInput(raw)
        XCTAssertEqual(input.filament?.vendor, "Elegoo")
        XCTAssertEqual(input.filament?.colorHex, "1A2B3C")
        XCTAssertEqual(input.remainingWeight, 640.5)
        XCTAssertEqual(input.initialWeight, 1000)
        XCTAssertEqual(input.spoolWeight, 180)
        XCTAssertEqual(input.comment, "opened · Spoolman #12")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        XCTAssertEqual(json["initial_weight"] as? Double, 1000)
        XCTAssertEqual(json["remaining_weight"] as? Double, 640.5)
    }
}
