import XCTest
@testable import PrintShare

/// Server 0.7-0.10: lanes (#6), camera through the server (#3), printer control (#5), own profiles (#2).
/// `status_cosmos.json`, `status_controls.json`, `controls.json` and `temperatures.json` are real output of the
/// server's Moonraker adapter (Dominique's recorded COSMOS + AFC, and the fake Moonraker of the server tests).
final class ServerTenTests: XCTestCase {
    private let l = L10n(lang: .en)

    // MARK: decoding

    func testLanesFromDominiquesCosmos() throws {
        let s = try Fixture.decode(PrinterStatus.self, "status_cosmos")
        XCTAssertEqual(s.lanes.map(\.id), ["CANVAS_4", "CANVAS_2", "CANVAS_3", "CANVAS_1"])
        XCTAssertEqual(s.lanes.map(\.tool), [0, 1, 2, 3])
        XCTAssertEqual(s.lanes.map(\.loaded), [true, true, false, true])
        XCTAssertEqual(s.lanes[0].color, "#A18787")
        XCTAssertEqual(s.lanes[0].material, "PLA")
        XCTAssertNil(s.lanes[2].material)
        XCTAssertNil(s.lanes[2].color)
        XCTAssertEqual(s.lanes[0].unit, "CANVAS_1")
        XCTAssertFalse(s.lanes.contains(where: \.inToolhead))
        // fans without a value (printer idle) are left out instead of breaking the status
        XCTAssertTrue(s.fans.isEmpty)
        XCTAssertEqual(s.lights, ["case": false, "hotend": false])
        XCTAssertEqual(Set(s.heaters.keys), ["nozzle", "bed", "chamber"])
    }

    func testControlsAndStatus() throws {
        let c = try Fixture.decode(Controls.self, "controls")
        XCTAssertEqual(c.heaters, [.init(id: "nozzle", max: 320), .init(id: "bed", max: 110)])
        XCTAssertEqual(c.fans.map(\.id), ["part", "aux_fan"])
        XCTAssertEqual(c.lights.map(\.id), ["case"])
        XCTAssertEqual(c.speedValues, [50, 75, 100, 125, 150])
        XCTAssertTrue(c.history)

        let s = try Fixture.decode(PrinterStatus.self, "status_controls")
        XCTAssertEqual(s.kind, .active)
        XCTAssertEqual(s.heaters["nozzle"], HeaterState(actual: 210.1, target: 210))
        XCTAssertEqual(s.heaters["chamber"], HeaterState(actual: 31.5, target: nil))
        XCTAssertEqual(s.fans, ["part": 50, "aux_fan": 0])
        XCTAssertEqual(s.lights, ["case": true])
        XCTAssertEqual(s.speed, 100)
    }

    func testCentauriSpeedModes() throws {
        let json = #"{"heaters":[{"id":"nozzle","max":320}],"fans":[],"lights":[{"id":"light"}],"speed":{"modes":[50,100,130,160]},"history":false}"#
        let c = try JSONDecoder().decode(Controls.self, from: Data(json.utf8))
        XCTAssertEqual(c.speedValues, [50, 100, 130, 160])
        XCTAssertEqual(L10n(lang: .de).speedMode(160), "Ludicrous")
        XCTAssertEqual(L10n(lang: .en).speedMode(50), "Silent")
        XCTAssertEqual(L10n(lang: .en).speedMode(120), "120 %")
    }

    func testNoControls() throws {
        let json = #"{"heaters":[],"fans":[],"lights":[],"speed":null,"history":false}"#
        let c = try JSONDecoder().decode(Controls.self, from: Data(json.utf8))
        XCTAssertEqual(c.speedValues, [])
    }

    func testTemperatureHistory() throws {
        let h = try Fixture.decode(TempHistory.self, "temperatures")
        XCTAssertEqual(h.source, "printer")
        XCTAssertEqual(h.series["nozzle"]?.count, 5)
        XCTAssertEqual(h.series["nozzle"]?.first, TempHistory.Point(t: -40, actual: 193.8, target: 200))
        XCTAssertEqual(h.series["chamber"]?.first?.target, nil)
        let scale = TempChart.scale(h.series)
        XCTAssertEqual(scale.names, ["bed", "chamber", "nozzle"])
        XCTAssertEqual(scale.minMinutes, -1)          // at least one minute is shown
        XCTAssertEqual(scale.maxValue, 250)           // 200 + 5 rounded up to 50
        XCTAssertEqual(TempChart.scale([:]).names, [])
    }

    func testCameraAndProfiles() throws {
        let cam = try Fixture.decode(CameraInfo.self, "camera")
        XCTAssertTrue(cam.available && cam.stream && cam.snapshot)
        let none = try JSONDecoder().decode(CameraInfo.self, from: Data(#"{"available":false,"stream":false,"snapshot":false,"name":null}"#.utf8))
        XCTAssertFalse(none.available)

        let profiles = try Fixture.decode([UserProfile].self, "profiles")
        XCTAssertEqual(profiles.map(\.kind), ["machine", "filament", "unknown"])
        XCTAssertTrue(profiles[0].printStart)
        XCTAssertEqual(profiles[0].inherits, "Elegoo Centauri Carbon 0.4 nozzle")
        XCTAssertEqual(profiles[2].error, "not an OrcaSlicer preset")
        let current = try Fixture.decode(PrinterProfile.self, "printer_profile")
        XCTAssertNil(current.machineFile)
        XCTAssertEqual(current.machinePreset, "cosmos")
    }

    // MARK: lane choice

    private let cosmosLanes = [
        Lane(id: "CANVAS_4", tool: 0, material: "PLA", color: "#A18787"),
        Lane(id: "CANVAS_2", tool: 1, material: "PLA", color: "#000000"),
        Lane(id: "CANVAS_3", tool: 2, loaded: false),
        Lane(id: "CANVAS_1", tool: 3, material: "PLA", color: "#FFFFFF"),
    ]

    func testMaterialOf() {
        XCTAssertEqual(LanePlan.materialOf("Elegoo PETG @ECC"), "PETG")
        XCTAssertEqual(LanePlan.materialOf("Elegoo PLA @ECC"), "PLA")
        XCTAssertEqual(LanePlan.materialOf("Generic PET-CF"), "PET")
        XCTAssertNil(LanePlan.materialOf("Mystery filament"))
        XCTAssertNil(LanePlan.materialOf(nil))
    }

    func testDefaultLanePicksTheClosestColourOfTheSameMaterial() {
        let colours = [LanePlan.Colour(index: 1, color: "#FFFFF0", preset: "Elegoo PLA @ECC"),
                       LanePlan.Colour(index: 2, color: "#101010", preset: "Elegoo PLA @ECC")]
        let tools = LanePlan.tools(colours: colours, lanes: cosmosLanes, choice: [:])
        XCTAssertEqual(tools, [1: 3, 2: 1])   // white -> CANVAS_1 (T3), black -> CANVAS_2 (T1)
        XCTAssertTrue(LanePlan.warnings(l, colours: colours, lanes: cosmosLanes, tools: tools).isEmpty)
    }

    func testSingleColourWithoutMatchingMaterialTakesTheLaneForT0() {
        let colours = [LanePlan.Colour(index: 1, color: nil, preset: "Elegoo PETG @ECC")]
        let tools = LanePlan.tools(colours: colours, lanes: cosmosLanes, choice: [:])
        XCTAssertEqual(tools, [1: 0])
        let w = LanePlan.warnings(l, colours: colours, lanes: cosmosLanes, tools: tools)
        XCTAssertEqual(w, [.init(text: "Slot: the profile is PETG, Slot 4 holds PLA.", blocking: false)])
    }

    func testChosenEmptyLaneBlocksPrinting() {
        let colours = [LanePlan.Colour(index: 1, color: nil, preset: "Elegoo PLA @ECC"),
                       LanePlan.Colour(index: 2, color: nil, preset: "Elegoo PLA @ECC")]
        let tools = LanePlan.tools(colours: colours, lanes: cosmosLanes, choice: [2: 2])
        XCTAssertEqual(tools[2], 2)
        let w = LanePlan.warnings(l, colours: colours, lanes: cosmosLanes, tools: tools)
        XCTAssertEqual(w.filter(\.blocking).map(\.text), ["Colour 2: Slot 3 is empty – load filament or choose another slot."])
        XCTAssertEqual(LanePlan.label(l, lane: cosmosLanes[2], lanes: cosmosLanes), "Slot 3 · empty")
        XCTAssertEqual(LanePlan.label(l, lane: cosmosLanes[0], lanes: cosmosLanes), "Slot 4 · PLA")
    }

    func testSlotsAreThePhysicalLaneNumbers() {
        // Dominique's CANVAS: Slot 1 is CANVAS_1 although it maps to T3
        let choices = LanePlan.choices(l, lanes: cosmosLanes)
        XCTAssertEqual(choices.map(\.label), ["Slot 1", "Slot 2", "Slot 3", "Slot 4"])
        XCTAssertEqual(choices.map(\.value), ["3", "1", "2", "0"])
        XCTAssertEqual(choices[0].sub, "PLA · T3")
        XCTAssertEqual(choices[2].sub, "empty · T2")
        // two units with the same numbers: fall back to the lane ids
        let twoUnits = [Lane(id: "BOX_1", tool: 0), Lane(id: "CANVAS_1", tool: 1)]
        XCTAssertEqual(LanePlan.choices(l, lanes: twoUnits).map(\.label), ["BOX_1", "CANVAS_1"])
        XCTAssertEqual(LanePlan.choices(l, lanes: [Lane(id: "left", tool: 0)]).map(\.label), ["left"])
    }

    func testSlotMaterialPicksTheSlicingPreset() {
        let materials = ["Elegoo PLA @ECC", "Elegoo PLA Matte @ECC", "Elegoo PETG @ECC", "Generic PETG @ECC"]
        let petg = Lane(id: "CANVAS_2", tool: 1, material: "PETG")
        XCTAssertEqual(LanePlan.preset(for: petg, materials: materials, preferred: "Elegoo PLA @ECC",
                                       fallback: "Elegoo PLA @ECC"), "Elegoo PETG @ECC")
        XCTAssertEqual(LanePlan.preset(for: petg, materials: materials, preferred: "Generic PETG @ECC",
                                       fallback: "Elegoo PLA @ECC"), "Generic PETG @ECC")
        let named = Lane(id: "CANVAS_1", tool: 3, material: "PLA", filament: "Elegoo PLA Matte")
        XCTAssertEqual(LanePlan.preset(for: named, materials: materials, preferred: "Elegoo PLA @ECC",
                                       fallback: nil), "Elegoo PLA Matte @ECC")
        XCTAssertEqual(LanePlan.preset(for: cosmosLanes[3], materials: materials, preferred: "Elegoo PETG @ECC",
                                       fallback: "Elegoo PLA @ECC"), "Elegoo PLA @ECC")
        XCTAssertNil(LanePlan.preset(for: cosmosLanes[2], materials: materials, preferred: nil, fallback: nil))  // empty
        XCTAssertNil(LanePlan.preset(for: Lane(id: "x", tool: 0, material: "Unobtainium"), materials: materials,
                                     preferred: nil, fallback: nil))
        XCTAssertNil(LanePlan.preset(for: nil, materials: materials, preferred: nil, fallback: nil))
    }

    func testLanesOnlyFromAReachablePrinter() {
        XCTAssertTrue(LanePlan.usable(nil).isEmpty)
        XCTAssertTrue(LanePlan.usable(PrinterStatus(kind: .offline, lanes: cosmosLanes)).isEmpty)
        let withUnmapped = cosmosLanes + [Lane(id: "spare", tool: nil)]
        XCTAssertEqual(LanePlan.usable(PrinterStatus(kind: .idle, lanes: withUnmapped)).count, 4)
    }

    func testColoursOfAJob() throws {
        let multi = try Fixture.decode(Job.self, "job_multicolor")
        XCTAssertEqual(LanePlan.colours(multi.result).count, multi.result?.filaments.count)
        let single = JobResult(printer: "cc", profiles: ["filament": "Elegoo PLA @ECC"])
        XCTAssertEqual(LanePlan.colours(single), [.init(index: 1, color: nil, preset: "Elegoo PLA @ECC")])
        XCTAssertEqual(LanePlan.colours(nil), [])
    }

    // MARK: printer control rules

    func testWhatNeedsAConfirmation() {
        typealias C = ControlView.Change
        XCTAssertTrue(ControlView.isRisky(C(kind: .heater, id: "bed", value: .number(0))))
        XCTAssertTrue(ControlView.isRisky(C(kind: .fan, id: "part", value: .number(0))))
        XCTAssertFalse(ControlView.isRisky(C(kind: .fan, id: "part", value: .number(50))))
        XCTAssertFalse(ControlView.isRisky(C(kind: .light, id: "case", value: .flag(false))))
        XCTAssertTrue(ControlView.isHigh(C(kind: .heater, id: "nozzle", value: .number(260))))
        XCTAssertFalse(ControlView.isHigh(C(kind: .heater, id: "nozzle", value: .number(255))))
        XCTAssertTrue(ControlView.isHigh(C(kind: .heater, id: "bed", value: .number(100))))
        XCTAssertFalse(ControlView.isHigh(C(kind: .heater, id: "unknown", value: .number(400))))
    }

    func testControlNames() {
        let de = L10n(lang: .de), en = L10n(lang: .en)
        XCTAssertEqual(de.heaterName("nozzle"), "Düse")
        XCTAssertEqual(en.fanName("aux_fan"), "Auxiliary fan")
        XCTAssertEqual(de.lightName("case"), "Innenraumlicht")
        XCTAssertEqual(en.heaterName("extruder1"), "extruder1")
    }

    // MARK: request shapes

    private func client() -> APIClient {
        APIClient(server: Server(url: "http://home.test:8484", token: "tok"), l10n: l, session: StubProtocol.session(),
                  cache: RouteCache())
    }

    func testSendWithLanesAdjustAndProfileBodies() async throws {
        var seen: [URLRequest] = []
        let lock = NSLock()
        let cur = try Fixture.data("printer_profile")
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            return StubResponse(body: req.url?.path.hasSuffix("/profile") == true ? cur : Data("{\"ok\":true}".utf8))
        }
        let api = client()
        try await api.send(job: "j1", start: true, leveling: nil, lanes: [1: 3, 2: 1])
        try await api.send(job: "j1", start: false, lanes: [:])
        try await api.adjust(printer: "cc", kind: .heater, id: "nozzle", value: .number(210))
        try await api.adjust(printer: "cc", kind: .light, id: "case", value: .flag(true), confirm: true)
        _ = try await api.setPrinterProfile(printer: "cc", machineFile: nil)
        _ = try await api.setPrinterProfile(printer: "cc", machineFile: "machine-AFC COSMOS.json")

        let r = lock.withLock { seen }
        let send = try XCTUnwrap(json(r[0]))
        XCTAssertEqual(send["lanes"] as? [String: Int], ["1": 3, "2": 1])
        XCTAssertNil(try XCTUnwrap(json(r[1]))["lanes"])      // no lanes -> field left out
        XCTAssertEqual(r[2].url?.path, "/api/printers/cc/adjust")
        let heat = try XCTUnwrap(json(r[2]))
        XCTAssertEqual(heat["kind"] as? String, "heater")
        XCTAssertEqual(heat["id"] as? String, "nozzle")
        XCTAssertEqual(heat["value"] as? Double, 210)
        XCTAssertEqual(heat["confirm"] as? Bool, false)
        let light = try XCTUnwrap(json(r[3]))
        XCTAssertEqual(light["value"] as? Bool, true)
        XCTAssertEqual(light["confirm"] as? Bool, true)
        XCTAssertEqual(r[4].httpMethod, "PUT")
        let std = try XCTUnwrap(json(r[4]))
        XCTAssertTrue(std.keys.contains("machine_file"))       // null = back to the standard profile, sent explicitly
        XCTAssertTrue(std["machine_file"] is NSNull)
        XCTAssertEqual(try XCTUnwrap(json(r[5]))["machine_file"] as? String, "machine-AFC COSMOS.json")
    }

    func testAdjustConflictIsNotRepeated() async {
        StubProtocol.install { _ in
            StubResponse(status: 409, body: Data(#"{"detail":"a print is running - confirm this change (confirm=true)"}"#.utf8))
        }
        do {
            try await client().adjust(printer: "cc", kind: .fan, id: "part", value: .number(0))
            XCTFail("expected 409")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 409)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    func testCameraURLsCarryTheToken() async throws {
        let api = client()
        let streamReq = await api.cameraRequest(printer: "centauri carbon", kind: .stream)
        let stream = try XCTUnwrap(streamReq)
        XCTAssertEqual(stream.url?.absoluteString, "http://home.test:8484/api/printers/centauri%20carbon/camera/stream")
        XCTAssertEqual(stream.value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        let snapReq = await api.cameraRequest(printer: "cc", kind: .snapshot, width: 640)
        let snap = try XCTUnwrap(snapReq)
        let q = URLComponents(url: try XCTUnwrap(snap.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(q.first { $0.name == "w" }?.value, "640")
        XCTAssertNotNil(q.first { $0.name == "t" })           // fresh image every time
        XCTAssertNil(q.first { $0.name == "token" })          // native requests send the header instead

        StubProtocol.install { _ in StubResponse(body: Data([0xFF, 0xD8, 0xFF, 0xD9])) }
        let jpeg = try await api.cameraSnapshot(printer: "cc", width: 320)
        XCTAssertEqual(jpeg, Data([0xFF, 0xD8, 0xFF, 0xD9]))
        XCTAssertEqual(StubProtocol.requests.last?.path, "/api/printers/cc/camera/snapshot")
    }

    func testProfileUploadIsRawBody() async throws {
        let list = try Fixture.data("profiles")
        StubProtocol.install { _ in StubResponse(body: list) }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString).json")
        try Data("{}".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let stored = try await client().uploadProfile(fileURL: file, name: "AFC COSMOS.json")
        XCTAssertEqual(stored.count, 3)
        XCTAssertEqual(StubProtocol.requests.last, LoggedRequest(method: "POST", host: "home.test", path: "/api/profiles"))
    }

    private func json(_ req: URLRequest) -> [String: Any]? {
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
        return data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
}
