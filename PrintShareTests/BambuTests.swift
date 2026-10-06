import CryptoKit
import Network
import XCTest
@testable import PrintShare

/// Bambu Lab without a bridge (Expo app upstream 0e0e8a7): report → status / AMS lanes from a real P1S report, the
/// wrapped 3MF, MQTT framing, and the whole flow against a fake printer (plain MQTT + FTP on localhost; the TLS parts
/// need a real printer).
final class BambuTests: XCTestCase {
    private func report() throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: Fixture.data("bambu_p1s_report")) as? [String: Any]
        return try XCTUnwrap(obj?["print"] as? [String: Any])
    }

    // MARK: report

    func testStatusAndLanesFromARealP1SReport() throws {
        let r = try report()
        let st = BambuState.status(r)
        XCTAssertEqual(st.state, "standby")
        XCTAssertEqual(st.kind, .idle)
        XCTAssertEqual(st.speed, 100)
        XCTAssertEqual(st.lights, ["light": false])
        XCTAssertEqual(st.heaters["bed"]?.actual, BambuState.double(r["bed_temper"]))
        XCTAssertEqual(st.lanes.map(\.id), ["A1", "A2", "A3", "A4"])
        let a1 = st.lanes[0], a2 = st.lanes[1], a3 = st.lanes[2]
        XCTAssertEqual(a1.material, "PETG")
        XCTAssertEqual(a1.color, "#898989")
        XCTAssertTrue(a1.loaded)
        XCTAssertFalse(a1.inToolhead)
        XCTAssertTrue(a2.inToolhead)                       // tray_now "1"
        XCTAssertEqual(a2.tool, 1)
        XCTAssertFalse(a3.loaded)                          // tray_exist_bits "b" = trays 0, 1, 3
        XCTAssertNil(a3.material)
        XCTAssertEqual(a1.unit, "AMS 1")
    }

    func testStatesAndMerge() throws {
        let run = BambuState.status(["gcode_state": "RUNNING", "mc_percent": 42, "mc_remaining_time": 7, "subtask_name": "cube"])
        XCTAssertEqual(run.state, "printing")
        XCTAssertEqual(run.kind, .active)
        XCTAssertEqual(run.progress, 42)
        XCTAssertEqual(run.timeRemainingS, 420)
        XCTAssertEqual(run.file, "cube")
        XCTAssertEqual(BambuState.status(["gcode_state": "FAILED", "print_error": 50348044]).state, "cancelled")
        XCTAssertEqual(BambuState.status(["gcode_state": "FAILED", "print_error": 83935249]).state, "error")
        XCTAssertEqual(BambuState.status(["gcode_state": "FINISH"]).state, "complete")
        // the P1 sends only what changed: trays are merged by id
        var state = try report()
        BambuState.merge(&state, ["ams": ["tray_now": "0", "ams": [["id": "0", "tray": [["id": "2", "tray_type": "PLA",
                                                                                          "tray_color": "FF0000FF"]]]]],
                                  "nozzle_temper": 210])
        XCTAssertEqual(BambuState.double(state["nozzle_temper"]), 210)
        XCTAssertEqual(BambuState.double(state["bed_temper"]), BambuState.double(try report()["bed_temper"]))
        let trays = try XCTUnwrap(((state["ams"] as? [String: Any])?["ams"] as? [[String: Any]])?.first?["tray"] as? [[String: Any]])
        XCTAssertEqual(trays.count, 4)
        XCTAssertEqual(trays[2]["tray_type"] as? String, "PLA")
        XCTAssertEqual(trays[0]["tray_type"] as? String, "PETG")
        XCTAssertEqual(BambuState.lanes(state).first { $0.id == "A1" }?.inToolhead, true)
    }

    func testMappingNamesAndModels() throws {
        let r = try report()
        XCTAssertEqual(BambuState.amsMapping(filaments: 2, tools: nil, report: r), [0, 1])
        XCTAssertEqual(BambuState.amsMapping(filaments: 2, tools: [0: 3, 1: 0], report: r), [3, 0])
        XCTAssertEqual(BambuState.amsMapping(filaments: 1, tools: nil, report: r), [1])   // the tray in the toolhead
        XCTAssertTrue(BambuState.hasAms(r))
        XCTAssertEqual(BambuState.taskName("Ring – v2 (1).gcode"), "Ring_v2_1")
        XCTAssertEqual(BambuState.taskName("...gcode"), "print")
        XCTAssertEqual(BambuState.machine(serial: "01P00C0000000"), "Bambu Lab P1S 0.4 nozzle")
        XCTAssertNil(BambuState.machine(serial: "ZZZ"))
        let found = Discovery.bambu("192.168.1.53", serial: "01P00C0000000")
        XCTAssertEqual(found.type, "bambu_lan")
        XCTAssertEqual(found.name, "Bambu Lab P1S")
        XCTAssertEqual(found.machine, "Bambu Lab P1S 0.4 nozzle")
        let cmd = try XCTUnwrap(BambuState.startCommand(task: "cube", remote: "cube.gcode.3mf", mapping: [2], ams: true,
                                                        leveling: false)["print"] as? [String: Any])
        XCTAssertEqual(cmd["command"] as? String, "project_file")
        XCTAssertEqual(cmd["url"] as? String, "file:///sdcard/cube.gcode.3mf")
        XCTAssertEqual(cmd["ams_mapping"] as? [Int], [2])
        XCTAssertEqual(cmd["bed_leveling"] as? Bool, false)
        let noAms = try XCTUnwrap(BambuState.startCommand(task: "c", remote: "c.gcode.3mf", mapping: [2], ams: false,
                                                          leveling: true)["print"] as? [String: Any])
        XCTAssertEqual(noAms["ams_mapping"] as? [Int], [])
    }

    func testLanTypeAndAccess() throws {
        let p = try Lan.printer(type: "bambu_lan", access: LanAccess(address: "http://192.168.1.53:8883/", password: "12345678"))
        let b = try XCTUnwrap(p as? BambuPrinter)
        XCTAssertEqual(b.host, "192.168.1.53")
        XCTAssertEqual(b.code, "12345678")
        XCTAssertTrue(Lan.canRelay("bambu_lan"))
    }

    // MARK: print file

    static let gcode = """
        ; HEADER_BLOCK_START
        ; HEADER_BLOCK_END
        G28
        T1
        G1 X10 Y10 E1

        ; filament_type = PLA;PETG
        ; filament_colour = #F2754E;#00FF00

        """

    private func tempGcode(_ text: String = BambuTests.gcode) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bambu-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("two.gcode")
        try Data(text.utf8).write(to: url)
        return url
    }

    func testWrapped3MF() throws {
        let g = try tempGcode()
        let out = g.deletingLastPathComponent().appendingPathComponent("two.gcode.3mf")
        XCTAssertEqual(try Bambu3MF.wrap(gcode: g, to: out), 2)
        let zip = try ZipReader(Data(contentsOf: out))
        let gcode = try XCTUnwrap(zip.read("Metadata/plate_1.gcode"))
        XCTAssertEqual(gcode, try Data(contentsOf: g))
        let md5 = Insecure.MD5.hash(data: gcode).map { String(format: "%02X", $0) }.joined()
        XCTAssertEqual(try zip.read("Metadata/plate_1.gcode.md5").map { String(decoding: $0, as: UTF8.self) }, md5)
        let info = String(decoding: try XCTUnwrap(zip.read("Metadata/slice_info.config")), as: UTF8.self)
        XCTAssertTrue(info.contains(#"type="PETG" color="#00FF00""#))
        XCTAssertTrue(info.contains(#"type="PLA" color="#F2754E""#))
        XCTAssertTrue(zip.has("3D/3dmodel.model"))
        XCTAssertTrue(zip.has("[Content_Types].xml"))
        // no footer: one PLA filament
        XCTAssertEqual(Bambu3MF.filaments(tail: "G28\n").types, ["PLA"])
    }

    func testBigEntryRoundTrips() throws {
        var text = ""
        for i in 0 ..< 60_000 { text += "G1 X\(i % 250) Y\(i % 210) E0.0\(i % 10)\n" }
        let g = try tempGcode(text)
        let out = g.deletingLastPathComponent().appendingPathComponent("big.gcode.3mf")
        try Bambu3MF.wrap(gcode: g, to: out)
        XCTAssertEqual(try ZipReader(Data(contentsOf: out)).read("Metadata/plate_1.gcode"), Data(text.utf8))
        XCTAssertEqual(CRC32.update(0, Data("123456789".utf8)), 0xCBF4_3926)
    }

    // MARK: MQTT framing

    func testMQTTFraming() throws {
        let connect = [UInt8](MQTT.connect(clientId: "c", user: "bblp", password: "pw"))
        XCTAssertEqual(connect[0], 0x10)
        XCTAssertEqual(Int(connect[1]), connect.count - 2)
        XCTAssertEqual(Array(connect[2 ..< 8]), [0, 4] + Array("MQTT".utf8))
        XCTAssertEqual(connect[8], 4)
        XCTAssertEqual(connect[9], 0xC2)
        XCTAssertEqual(MQTT.remainingLength(127), [127])
        XCTAssertEqual(MQTT.remainingLength(128), [0x80, 1])
        XCTAssertEqual(MQTT.remainingLength(16_384), [0x80, 0x80, 1])

        let payload = Data(String(repeating: "x", count: 300).utf8)
        var buffer = [UInt8](MQTT.publish(topic: "device/S/report", payload: payload)) + [0x20, 2, 0, 0, 0x90]
        let half = Array(buffer[0 ..< 100])
        var partial = half
        XCTAssertEqual(try MQTT.parse(&partial), [])
        XCTAssertEqual(partial, half)                       // incomplete packets stay
        let packets = try MQTT.parse(&buffer)
        XCTAssertEqual(packets, [.publish(topic: "device/S/report", payload: payload), .connack(code: 0)])
        XCTAssertEqual(buffer, [0x90])                     // the SUBACK isn't complete yet
        // QoS 1 publishes carry a packet id after the topic
        var qos1: [UInt8] = [0x32, 7] + MQTT.string("t") + [0, 9] + Array("ab".utf8)
        XCTAssertEqual(try MQTT.parse(&qos1), [.publish(topic: "t", payload: Data("ab".utf8))])
    }

    // MARK: against a fake printer

    func testStatusSendAndStartAgainstAFakePrinter() async throws {
        let broker = try FakeBroker(report: try JSONSerialization.data(withJSONObject: ["print": try report()]))
        let ftp = try FakeFTP()
        defer { broker.stop(); ftp.stop() }
        let mqttPort = try await broker.ready(), ftpPort = try await ftp.ready()
        var printer = BambuPrinter(host: "127.0.0.1", code: "12345678")
        printer.mqttPort = mqttPort
        printer.tls = false
        printer.serial = "01P00C0000000"
        printer.uploader = BambuFTPS(port: ftpPort, tls: false, timeout: 5)
        printer.links = BambuLinks()

        let st = try await printer.status()
        XCTAssertEqual(st.state, "standby")
        XCTAssertEqual(st.lanes.count, 4)
        XCTAssertEqual(broker.login, ["bblp", "12345678"])
        XCTAssertTrue(broker.subscribed.contains("device/01P00C0000000/report"))

        let steps = Recorder()
        let options = SendOptions(start: true, leveling: nil, spoolId: nil, tools: [0: 3, 1: 0],
                                  onStep: { steps.add($0.rawValue) }, onProgress: nil)
        try await printer.send(file: try tempGcode(), name: "Ring – v2 (1).gcode", options: options)
        XCTAssertEqual(steps.items, ["upload", "start"])
        XCTAssertEqual(ftp.stored?.name, "Ring_v2_1.gcode.3mf")
        let zip = try ZipReader(try XCTUnwrap(ftp.stored?.data))
        XCTAssertEqual(try zip.read("Metadata/plate_1.gcode"), Data(BambuTests.gcode.utf8))
        let start = try XCTUnwrap(broker.commands.first { $0["command"] as? String == "project_file" })
        XCTAssertEqual(start["ams_mapping"] as? [Int], [3, 0])
        XCTAssertEqual(start["subtask_name"] as? String, "Ring_v2_1")
        XCTAssertEqual(start["bed_leveling"] as? Bool, true)

        // the printer now reports the print (merged into the kept report)
        let running = try await printer.status()
        XCTAssertEqual(running.state, "printing")
        XCTAssertEqual(running.file, "Ring_v2_1")
        try await printer.control("cancel")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(broker.commands.last?["command"] as? String, "stop")
    }

    func testWrongAccessCode() async throws {
        let broker = try FakeBroker(report: Data("{}".utf8), refuse: true)
        defer { broker.stop() }
        var printer = BambuPrinter(host: "127.0.0.1", code: "wrong")
        printer.mqttPort = try await broker.ready()
        printer.tls = false
        printer.serial = "01P00C0000000"
        printer.links = BambuLinks()
        do {
            _ = try await printer.status()
            XCTFail("no error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "the printer refused the access code")
        }
    }

    func testIgnoredStartIsAnError() async throws {
        let broker = try FakeBroker(report: try JSONSerialization.data(withJSONObject: ["print": try report()]), ignoreStart: true)
        let ftp = try FakeFTP()
        defer { broker.stop(); ftp.stop() }
        var printer = BambuPrinter(host: "127.0.0.1", code: "12345678")
        printer.mqttPort = try await broker.ready()
        printer.tls = false
        printer.serial = "01P00C0000000"
        printer.uploader = BambuFTPS(port: try await ftp.ready(), tls: false, timeout: 5)
        printer.links = BambuLinks()
        printer.startTimeout = 2
        do {
            try await printer.send(file: try tempGcode(), name: "cube.gcode",
                                   options: SendOptions(start: true, leveling: nil, spoolId: nil, onStep: nil, onProgress: nil))
            XCTFail("no error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("LAN-only mode"), error.localizedDescription)
        }
        XCTAssertEqual(broker.commands.filter { $0["command"] as? String == "project_file" }.count, 1)   // never sent twice
    }
}

// MARK: fakes

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [String] = []
    func add(_ s: String) { lock.withLock { list.append(s) } }
    var items: [String] { lock.withLock { list } }
}

private func listen(_ queue: DispatchQueue, _ handler: @escaping @Sendable (NWConnection) -> Void) throws -> NWListener {
    let l = try NWListener(using: .tcp, on: .any)
    l.newConnectionHandler = { c in
        c.start(queue: queue)
        handler(c)
    }
    l.start(queue: queue)
    return l
}

private func waitForPort(_ l: NWListener) async throws -> UInt16 {
    for _ in 0 ..< 100 {
        if let p = l.port?.rawValue, p != 0 { return p }
        try await Task.sleep(for: .milliseconds(20))
    }
    throw LanError("listener not ready")
}

/// A Bambu printer's MQTT side: CONNACK (or "not authorised"), SUBACK, the full report on "pushall", and PREPARE with
/// the task name after a `project_file` (unless it ignores starts like a printer without LAN-only mode).
private final class FakeBroker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fake.mqtt")
    private let lock = NSLock()
    private var listener: NWListener!
    private let report: Data
    private let refuse: Bool
    private let ignoreStart: Bool
    private var _login: [String] = []
    private var _subscribed: [String] = []
    private var _commands: [[String: Any]] = []

    var login: [String] { lock.withLock { _login } }
    var subscribed: [String] { lock.withLock { _subscribed } }
    var commands: [[String: Any]] { lock.withLock { _commands } }

    init(report: Data, refuse: Bool = false, ignoreStart: Bool = false) throws {
        self.report = report; self.refuse = refuse; self.ignoreStart = ignoreStart
        listener = try listen(queue) { [weak self] c in self?.serve(c, buffer: []) }
    }

    func ready() async throws -> UInt16 { try await waitForPort(listener) }
    func stop() { listener.cancel() }

    private func serve(_ c: NWConnection, buffer: [UInt8]) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buf = buffer + [UInt8](data ?? Data())
            // CONNECT and SUBSCRIBE arrive as `.other`; their bodies are read from the raw bytes first
            self.inspect(buf)
            for packet in (try? MQTT.parse(&buf)) ?? [] { self.handle(packet, c) }
            if done || error != nil { return }
            self.serve(c, buffer: buf)
        }
    }

    /// User name, password and subscribed topic straight from complete CONNECT / SUBSCRIBE packets.
    private func inspect(_ buf: [UInt8]) {
        var i = 0
        while i + 2 <= buf.count {
            let type = buf[i], len = Int(buf[i + 1])          // the test packets are short (< 128 bytes)
            guard buf[i + 1] < 0x80, i + 2 + len <= buf.count else { return }
            let body = Array(buf[i + 2 ..< i + 2 + len])
            func str(_ at: Int) -> (String, Int) {
                let n = Int(body[at]) << 8 | Int(body[at + 1])
                return (String(decoding: body[at + 2 ..< at + 2 + n], as: UTF8.self), at + 2 + n)
            }
            if type == 0x10 {
                let (_, p1) = str(0)                           // "MQTT"
                let (_, p2) = str(p1 + 4)                      // client id after level, flags, keep-alive
                let (user, p3) = str(p2)
                let (pw, _) = str(p3)
                lock.withLock { _login = [user, pw] }
            } else if type == 0x82 {
                lock.withLock { _subscribed.append(str(2).0) }
            }
            i += 2 + len
        }
    }

    private func handle(_ packet: MQTT.Packet, _ c: NWConnection) {
        switch packet {
        case .other(0x10):
            c.send(content: Data([0x20, 2, 0, refuse ? 5 : 0]), completion: .idempotent)
        case .other(0x82):
            c.send(content: Data([0x90, 3, 0, 1, 0]), completion: .idempotent)
        case .publish(_, let payload):
            guard let obj = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] else { return }
            if (obj["pushing"] as? [String: Any])?["command"] as? String == "pushall" {
                c.send(content: MQTT.publish(topic: "device/01P00C0000000/report", payload: report), completion: .idempotent)
            }
            if let p = obj["print"] as? [String: Any] {
                lock.withLock { _commands.append(p) }
                if p["command"] as? String == "project_file", !ignoreStart {
                    let update = ["print": ["command": "push_status", "gcode_state": "PREPARE", "subtask_name": p["subtask_name"] ?? ""]]
                    let data = (try? JSONSerialization.data(withJSONObject: update)) ?? Data()
                    c.send(content: MQTT.publish(topic: "device/01P00C0000000/report", payload: data), completion: .idempotent)
                }
            }
        default: break
        }
    }
}

/// A Bambu printer's FTP side (plain, passive mode): keeps the one stored file.
private final class FakeFTP: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fake.ftp")
    private let lock = NSLock()
    private var listener: NWListener!
    private var data: NWListener?
    private var received = Data()
    private var name = ""
    private var _stored: (name: String, data: Data)?

    var stored: (name: String, data: Data)? { lock.withLock { _stored } }

    init() throws {
        listener = try listen(queue) { [weak self] c in
            c.send(content: Data("220 ready\r\n".utf8), completion: .idempotent)
            self?.serve(c, pending: "")
        }
    }

    func ready() async throws -> UInt16 { try await waitForPort(listener) }
    func stop() { listener.cancel(); data?.cancel() }

    private func reply(_ c: NWConnection, _ text: String) { c.send(content: Data("\(text)\r\n".utf8), completion: .idempotent) }

    private func serve(_ c: NWConnection, pending: String) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, done, error in
            guard let self else { return }
            var text = pending + String(decoding: chunk ?? Data(), as: UTF8.self)
            while let r = text.range(of: "\r\n") {
                let line = String(text[..<r.lowerBound])
                text.removeSubrange(..<r.upperBound)
                self.command(line, c)
            }
            if done || error != nil { return }
            self.serve(c, pending: text)
        }
    }

    private func command(_ line: String, _ c: NWConnection) {
        let verb = line.split(separator: " ").first.map(String.init) ?? ""
        switch verb {
        case "USER": reply(c, "331 password please")
        case "PASS": reply(c, line == "PASS 12345678" ? "230 logged in" : "530 wrong")
        case "TYPE": reply(c, "200 binary")
        case "PASV":
            guard let l = try? NWListener(using: .tcp, on: .any) else { return reply(c, "425 no") }
            l.newConnectionHandler = { [weak self] d in
                d.start(queue: self?.queue ?? .main)
                self?.drain(d, control: c)
            }
            l.stateUpdateHandler = { [weak self] state in
                guard case .ready = state, let p = l.port?.rawValue else { return }
                self?.reply(c, "227 Entering Passive Mode (127,0,0,1,\(p / 256),\(p % 256))")
            }
            lock.withLock { data = l }
            l.start(queue: queue)
        case "STOR":
            lock.withLock { name = String(line.dropFirst(5)) }
            reply(c, "150 go ahead")
        case "QUIT": reply(c, "221 bye")
        default: reply(c, "502 not here")
        }
    }

    private func drain(_ d: NWConnection, control: NWConnection) {
        d.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, done, error in
            guard let self else { return }
            if let chunk { self.lock.withLock { self.received.append(chunk) } }
            if done || error != nil {
                self.lock.withLock { self._stored = (self.name, self.received) }
                self.reply(control, "226 stored")
                d.cancel()
                return
            }
            self.drain(d, control: control)
        }
    }
}
