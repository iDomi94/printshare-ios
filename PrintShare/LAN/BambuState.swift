import Foundation

/// What a Bambu Lab report means (pure) - port of the Expo app's `lib/lan/bambuState.ts`, the same rules as the server's
/// `printshare/printers/bambu.py` (upstream 0e0e8a7).
enum BambuState {
    typealias Raw = [String: Any]

    /// gcode_state → the names the rest of the app understands
    static let states: [String: String] = [
        "IDLE": "standby", "PREPARE": "printing", "SLICING": "printing", "RUNNING": "printing", "PAUSE": "paused",
        "FINISH": "complete", "FAILED": "error",
    ]
    /// print_error "the task was cancelled"
    static let cancelled: Set<Int> = [0, 50348044]
    static let speedLevels: [Int: Int] = [1: 50, 2: 100, 3: 124, 4: 166]
    static let fans: [String: String] = ["part": "cooling_fan_speed", "aux": "big_fan1_speed", "chamber": "big_fan2_speed"]
    static let starting: Set<String> = ["PREPARE", "SLICING", "RUNNING"]
    /// serial number prefix → model (OrcaSlicer preset "Bambu Lab <model> 0.4 nozzle")
    static let models: [(String, String)] = [("01P", "P1S"), ("01S", "P1P"), ("00M", "X1 Carbon"), ("03W", "X1E"),
                                             ("030", "A1 mini"), ("039", "A1"), ("22E", "P2S"), ("094", "H2D")]

    static func model(serial: String?) -> String? {
        guard let serial else { return nil }
        return models.first { serial.hasPrefix($0.0) }?.1
    }

    static func machine(serial: String?) -> String? { model(serial: serial).map { "Bambu Lab \($0) 0.4 nozzle" } }

    /// The P1 series sends only what changed: merge into the kept report; lists of {id} (AMS units, trays) by id.
    static func merge(_ dst: inout Raw, _ src: Raw) {
        for (k, v) in src {
            if let obj = v as? Raw, var old = dst[k] as? Raw {
                merge(&old, obj)
                dst[k] = old
            } else if let list = v as? [Any], var old = dst[k] as? [Any], !list.isEmpty,
                      list.allSatisfy({ ($0 as? Raw)?["id"] != nil }) {
                for case let item as Raw in list {
                    let id = text(item["id"])
                    if let i = old.firstIndex(where: { ($0 as? Raw).map { text($0["id"]) == id } ?? false }),
                       var hit = old[i] as? Raw {
                        merge(&hit, item)
                        old[i] = hit
                    } else {
                        old.append(item)
                    }
                }
                dst[k] = old
            } else {
                dst[k] = v
            }
        }
    }

    /// "898989FF" → "#898989"; fully transparent or anything else → nil
    static func colour(_ c: Any?) -> String? {
        let s = text(c)
        guard s.matches("^[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$"), !(s.count == 8 && s.suffix(2) == "00") else { return nil }
        return "#\(s.prefix(6).uppercased())"
    }

    /// AMS trays as lanes: ids A1..A4 (B1.. for a 2nd AMS), tool = tray number across all units.
    static func lanes(_ report: Raw) -> [Lane] {
        let ams = report["ams"] as? Raw ?? [:]
        let exist = Int(text(ams["tray_exist_bits"] ?? "0"), radix: 16) ?? 0
        let now = text(ams["tray_now"] ?? "255")
        var out: [Lane] = []
        for case let unit as Raw in ams["ams"] as? [Any] ?? [] {
            guard let u = int(unit["id"]) else { continue }
            for case let tray as Raw in unit["tray"] as? [Any] ?? [] {
                guard let t = int(tray["id"]) else { continue }
                let tool = u * 4 + t
                let inserted = tool < 62 && (exist >> tool) & 1 == 1
                let weight = double(tray["tray_weight"]) ?? 0
                let remain = (tray["remain"] as? NSNumber).map(\.doubleValue).flatMap { $0 >= 0 ? $0 : nil }
                let type = text(tray["tray_type"]), brand = text(tray["tray_sub_brands"])
                var lane = Lane(id: "\(Character(UnicodeScalar(65 + u) ?? "A"))\(t + 1)", tool: tool,
                                material: inserted && !type.isEmpty ? type : nil,
                                color: inserted ? colour(tray["tray_color"]) : nil,
                                filament: inserted && !brand.isEmpty ? brand : nil,
                                loaded: inserted, inToolhead: now == String(tool))
                lane.unit = "AMS \(u + 1)"
                if inserted, weight > 0, let remain { lane.weightG = (weight * remain / 100).rounded() }
                lane.status = inserted ? "ready" : "empty"
                out.append(lane)
            }
        }
        return out.sorted { ($0.tool ?? 0) < ($1.tool ?? 0) }
    }

    static func status(_ report: Raw) -> PrinterStatus {
        let g = text(report["gcode_state"]).uppercased()
        var state: String? = states[g] ?? (g.isEmpty ? nil : g.lowercased())
        if g == "FAILED", cancelled.contains(int(report["print_error"]) ?? 0) { state = "cancelled" }
        var out = PrinterStatus(kind: Lan.kind(state), state: state, lanes: lanes(report))
        let subtask = text(report["subtask_name"])
        let gcodeFile = (text(report["gcode_file"]) as NSString).lastPathComponent
        out.file = !subtask.isEmpty ? subtask : gcodeFile.isEmpty ? nil : gcodeFile
        out.progress = double(report["mc_percent"]) ?? 0
        out.layer = int(report["layer_num"])
        out.layers = int(report["total_layer_num"])
        if let r = double(report["mc_remaining_time"]), r >= 0 { out.timeRemainingS = r * 60 }
        out.nozzle = double(report["nozzle_temper"])
        out.nozzleTarget = double(report["nozzle_target_temper"])
        out.bed = double(report["bed_temper"])
        out.bedTarget = double(report["bed_target_temper"])
        out.heaters = [
            "nozzle": HeaterState(actual: out.nozzle, target: out.nozzleTarget),
            "bed": HeaterState(actual: out.bed, target: out.bedTarget),
        ]
        for (id, key) in fans {
            if let v = double(report[key]) { out.fans[id] = (v * 100 / 15).rounded() }
        }
        let lights = (report["lights_report"] as? [Any] ?? []).compactMap { $0 as? Raw }
        out.lights = ["light": lights.contains { text($0["node"]) == "chamber_light" && text($0["mode"]) == "on" }]
        out.speed = speedLevels[int(report["spd_lvl"]) ?? 2]
        return out
    }

    /// Tray per filament of the print: the app's choice, else the tray in the toolhead for one filament, else n → n.
    static func amsMapping(filaments: Int, tools: [Int: Int]?, report: Raw) -> [Int] {
        let loaded = Int(text((report["ams"] as? Raw)?["tray_now"] ?? "255")) ?? 255
        let n = max(1, filaments)
        return (0 ..< n).map { i in
            if let t = tools?[i] { return t }
            return n <= 1 && loaded < 16 ? loaded : i
        }
    }

    static func hasAms(_ report: Raw) -> Bool {
        (Int(text((report["ams"] as? Raw)?["ams_exist_bits"] ?? "0"), radix: 16) ?? 0) > 0
    }

    /// "Ring – v2 (1).gcode" → "Ring_v2_1" (the task name the printer reports while printing)
    static func taskName(_ fileName: String) -> String {
        let stem = fileName.replacingRegex("(?i)\\.gcode$", with: "")
            .replacingRegex("[^A-Za-z0-9_.-]+", with: "_").replacingRegex("^[._]+|[._]+$", with: "")
        let out = String(stem.prefix(60))
        return out.isEmpty ? "print" : out
    }

    static func startCommand(task: String, remote: String, mapping: [Int], ams: Bool, leveling: Bool) -> Raw {
        ["print": [
            "command": "project_file", "param": "Metadata/plate_1.gcode", "url": "file:///sdcard/\(remote)", "file": remote,
            "md5": "", "subtask_name": task, "project_id": "0", "profile_id": "0", "task_id": "0", "subtask_id": "0",
            "bed_type": "auto", "timelapse": false, "bed_leveling": leveling, "bed_levelling": leveling, "flow_cali": false,
            "vibration_cali": false, "layer_inspect": false, "use_ams": ams, "ams_mapping": ams ? mapping : [Int](),
        ] as Raw]
    }

    // MARK: JSON values (the printer sends numbers as strings in places)

    static func text(_ v: Any?) -> String {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }

    static func double(_ v: Any?) -> Double? {
        if let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }

    static func int(_ v: Any?) -> Int? { double(v).map { Int($0) } }
}
