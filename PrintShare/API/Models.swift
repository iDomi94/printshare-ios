import Foundation

// Types of the PrintShare server API (see printshare/api.py). Field names are mapped explicitly with CodingKeys:
// a global snake_case strategy would also rewrite the keys of dictionaries such as `overrides`.

extension KeyedDecodingContainer {
    /// Value or nil when missing, null or of an unexpected type - one odd field must never break a whole screen.
    func lenient<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }
}

/// `remoteUrl`: optional second address for use away from home (e.g. Tailscale).
struct Server: Codable, Sendable, Equatable {
    var url: String
    var token: String
    var remoteUrl: String?
}

enum Route: String, Sendable { case home, remote }

struct ServerInfo: Codable, Sendable, Equatable {
    var name: String
    var version: String
    var printers: Int

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.lenient(String.self, .name) ?? "PrintShare"
        version = c.lenient(String.self, .version) ?? ""
        printers = c.lenient(Int.self, .printers) ?? 0
    }

    init(name: String, version: String, printers: Int) {
        self.name = name; self.version = version; self.printers = printers
    }

    enum CodingKeys: String, CodingKey { case name, version, printers }
}

struct Printer: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var type: String
    var machine: String
    /// Non-nil when the printer can do bed leveling before a print; the value is the suggested default.
    var leveling: Bool?

    enum CodingKeys: String, CodingKey { case id, name, type, machine, leveling }

    init(id: String, name: String, type: String = "", machine: String = "", leveling: Bool? = nil) {
        self.id = id; self.name = name; self.type = type; self.machine = machine; self.leveling = leveling
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.lenient(String.self, .name) ?? id
        type = c.lenient(String.self, .type) ?? ""
        machine = c.lenient(String.self, .machine) ?? ""
        if c.contains(.leveling), !((try? c.decodeNil(forKey: .leveling)) ?? true) {
            leveling = c.lenient(Bool.self, .leveling) ?? true
        } else {
            leveling = nil
        }
    }
}

/// `offline` is never sent by the server; the app uses it when a printer cannot be reached.
enum PrinterKind: String, Codable, Sendable {
    case idle, active, paused, done, stopped, error, unknown, offline

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = PrinterKind(rawValue: raw) ?? .unknown
    }

    var isBusy: Bool { self == .active || self == .paused }
}

struct PrinterStatus: Codable, Sendable, Equatable {
    var state: String?
    var kind: PrinterKind
    var file: String?
    var progress: Double?
    var layer: Int?
    var layers: Int?
    var printDurationS: Double?
    var timeRemainingS: Double?
    var nozzle: Double?
    var nozzleTarget: Double?
    var bed: Double?
    var bedTarget: Double?
    var camera: String?

    enum CodingKeys: String, CodingKey {
        case state, kind, file, progress, layer, layers, nozzle, bed, camera
        case printDurationS = "print_duration_s"
        case timeRemainingS = "time_remaining_s"
        case nozzleTarget = "nozzle_target"
        case bedTarget = "bed_target"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = c.lenient(String.self, .state)
        kind = c.lenient(PrinterKind.self, .kind) ?? .unknown
        file = c.lenient(String.self, .file)
        progress = c.lenient(Double.self, .progress)
        layer = c.lenient(Int.self, .layer) ?? c.lenient(Double.self, .layer).map { Int($0) }
        layers = c.lenient(Int.self, .layers) ?? c.lenient(Double.self, .layers).map { Int($0) }
        printDurationS = c.lenient(Double.self, .printDurationS)
        timeRemainingS = c.lenient(Double.self, .timeRemainingS)
        nozzle = c.lenient(Double.self, .nozzle)
        nozzleTarget = c.lenient(Double.self, .nozzleTarget)
        bed = c.lenient(Double.self, .bed)
        bedTarget = c.lenient(Double.self, .bedTarget)
        camera = c.lenient(String.self, .camera)
    }

    init(kind: PrinterKind, state: String? = nil) {
        self.kind = kind; self.state = state
    }
}

struct Defaults: Codable, Sendable, Equatable {
    var filament: String
    var process: String
    var bedType: String
    var supports: String
    var brim: String
    var infill: Int?
    var walls: Int?
    var layerHeight: String?

    enum CodingKeys: String, CodingKey {
        case filament, process, supports, brim, infill, walls
        case bedType = "bed_type"
        case layerHeight = "layer_height"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filament = try c.decode(String.self, forKey: .filament)
        process = try c.decode(String.self, forKey: .process)
        bedType = c.lenient(String.self, .bedType) ?? ""
        supports = c.lenient(String.self, .supports) ?? "off"
        brim = c.lenient(String.self, .brim) ?? "auto"
        infill = c.lenient(Int.self, .infill)
        walls = c.lenient(Int.self, .walls)
        layerHeight = c.lenient(String.self, .layerHeight)
    }

    init(filament: String, process: String, bedType: String, supports: String = "off", brim: String = "auto",
         infill: Int? = nil, walls: Int? = nil, layerHeight: String? = nil) {
        self.filament = filament; self.process = process; self.bedType = bedType; self.supports = supports
        self.brim = brim; self.infill = infill; self.walls = walls; self.layerHeight = layerHeight
    }
}

struct Options: Codable, Sendable, Equatable {
    var printer: String
    var materials: [String]
    var processes: [String]
    var plates: [String]
    var supports: [String]
    var brims: [String]
    var defaults: Defaults
}

/// Per-job overrides sent to `POST /api/jobs` (nil = keep the profile value) and echoed back in `Job.request`.
struct JobOptions: Codable, Sendable, Equatable, Hashable {
    var filament: String?
    var process: String?
    var bedType: String?
    var supports: String?
    var brim: String?
    var infill: Int?
    var walls: Int?

    enum CodingKeys: String, CodingKey {
        case filament, process, supports, brim, infill, walls
        case bedType = "bed_type"
    }

    init(filament: String? = nil, process: String? = nil, bedType: String? = nil, supports: String? = nil,
         brim: String? = nil, infill: Int? = nil, walls: Int? = nil) {
        self.filament = filament; self.process = process; self.bedType = bedType; self.supports = supports
        self.brim = brim; self.infill = infill; self.walls = walls
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        filament = c.lenient(String.self, .filament)
        process = c.lenient(String.self, .process)
        bedType = c.lenient(String.self, .bedType)
        supports = c.lenient(String.self, .supports)
        brim = c.lenient(String.self, .brim)
        infill = c.lenient(Int.self, .infill)
        walls = c.lenient(Int.self, .walls)
    }
}

struct ModelFile: Codable, Sendable, Equatable, Identifiable {
    var index: Int
    var name: String
    var size: Int?
    var id: Int { index }
}

enum JobState: String, Codable, Sendable {
    case slicing, sliced, sending, uploaded, started, error, running, done, unknown

    init(from decoder: Decoder) throws {
        let raw = (try? decoder.singleValueContainer().decode(String.self)) ?? ""
        self = JobState(rawValue: raw) ?? .unknown
    }

    /// The server is working on the job.
    var isWorking: Bool { self == .slicing || self == .running || self == .sending }
}

struct JobResult: Codable, Sendable, Equatable {
    var printer: String
    var sourceFile: String?
    var printTime: String?
    var filamentG: Double?
    var filamentM: Double?
    var layers: Int?
    var profiles: [String: String]
    var overrides: [String: String]

    enum CodingKeys: String, CodingKey {
        case printer, layers, profiles, overrides
        case sourceFile = "source_file"
        case printTime = "print_time"
        case filamentG = "filament_g"
        case filamentM = "filament_m"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        printer = c.lenient(String.self, .printer) ?? ""
        sourceFile = c.lenient(String.self, .sourceFile)
        printTime = c.lenient(String.self, .printTime)
        filamentG = c.lenient(Double.self, .filamentG)
        filamentM = c.lenient(Double.self, .filamentM)
        layers = c.lenient(Int.self, .layers)
        profiles = c.lenient([String: String].self, .profiles) ?? [:]
        overrides = c.lenient([String: String].self, .overrides) ?? [:]
    }

    init(printer: String, sourceFile: String? = nil, printTime: String? = nil, filamentG: Double? = nil,
         filamentM: Double? = nil, layers: Int? = nil, profiles: [String: String] = [:],
         overrides: [String: String] = [:]) {
        self.printer = printer; self.sourceFile = sourceFile; self.printTime = printTime
        self.filamentG = filamentG; self.filamentM = filamentM; self.layers = layers
        self.profiles = profiles; self.overrides = overrides
    }
}

struct JobRequest: Codable, Sendable, Equatable {
    var link: String
    var printer: String?
    var file: String?
    var options: JobOptions?
    var name: String?
}

struct Job: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var kind: String
    var state: JobState
    var log: [String]
    var result: JobResult?
    var error: String?
    var created: Double
    var printer: String?
    var request: JobRequest

    enum CodingKeys: String, CodingKey { case id, kind, state, log, result, error, created, printer, request }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = c.lenient(String.self, .kind) ?? ""
        state = c.lenient(JobState.self, .state) ?? .unknown
        log = c.lenient([String].self, .log) ?? []
        result = c.lenient(JobResult.self, .result)
        error = c.lenient(String.self, .error)
        created = c.lenient(Double.self, .created) ?? 0
        printer = c.lenient(String.self, .printer)
        request = c.lenient(JobRequest.self, .request) ?? JobRequest(link: "")
    }

    init(id: String, kind: String = "prepare", state: JobState, log: [String] = [], result: JobResult? = nil,
         error: String? = nil, created: Double = 0, printer: String? = nil, request: JobRequest) {
        self.id = id; self.kind = kind; self.state = state; self.log = log; self.result = result
        self.error = error; self.created = created; self.printer = printer; self.request = request
    }
}

struct JobSummary: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var kind: String
    var state: JobState
    var error: String?
    var created: Double
    var printer: String?
    var link: String?
    var file: String?
    var printTime: String?
    var filamentG: Double?

    enum CodingKeys: String, CodingKey {
        case id, kind, state, error, created, printer, link, file
        case printTime = "print_time"
        case filamentG = "filament_g"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = c.lenient(String.self, .kind) ?? ""
        state = c.lenient(JobState.self, .state) ?? .unknown
        error = c.lenient(String.self, .error)
        created = c.lenient(Double.self, .created) ?? 0
        printer = c.lenient(String.self, .printer)
        link = c.lenient(String.self, .link)
        file = c.lenient(String.self, .file)
        printTime = c.lenient(String.self, .printTime)
        filamentG = c.lenient(Double.self, .filamentG)
    }
}

struct Upload: Codable, Sendable, Equatable {
    var id: String
    var link: String
    var name: String
    var size: Int
}

struct Source: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var name: String
    var available: Bool
}

enum SortKey: String, Sendable, CaseIterable {
    case relevant, popular, makes
}

struct ModelHit: Codable, Sendable, Equatable, Identifiable {
    var source: String
    var id: String
    var name: String
    var url: String
    var author: String?
    var thumbnail: String?
    var likes: Int?
    var downloads: Int?
    var makes: Int?
    var license: String?

    /// Unique across sources (list identity).
    var key: String { "\(source)-\(id)" }

    enum CodingKeys: String, CodingKey { case source, id, name, url, author, thumbnail, likes, downloads, makes, license }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        id = c.lenient(String.self, .id) ?? c.lenient(Int.self, .id).map(String.init) ?? ""
        name = c.lenient(String.self, .name) ?? "?"
        url = c.lenient(String.self, .url) ?? ""
        author = c.lenient(String.self, .author)
        thumbnail = c.lenient(String.self, .thumbnail)
        likes = c.lenient(Int.self, .likes)
        downloads = c.lenient(Int.self, .downloads)
        makes = c.lenient(Int.self, .makes)
        license = c.lenient(String.self, .license)
    }
}

struct Recommended: Codable, Sendable, Equatable {
    var nozzle: String?
    var layerHeight: String?
    var material: String?
    var weightG: Double?
    var printHours: Double?

    enum CodingKeys: String, CodingKey {
        case nozzle, material
        case layerHeight = "layer_height"
        case weightG = "weight_g"
        case printHours = "print_hours"
    }

    var isEmpty: Bool { nozzle == nil && layerHeight == nil && material == nil && weightG == nil && printHours == nil }
}

struct ModelDetailFile: Codable, Sendable, Equatable {
    var name: String
    var size: Int?
    var sliceable: Bool
}

struct ModelDetail: Codable, Sendable, Equatable {
    var hit: ModelHit
    var images: [String]
    var summary: String
    var description: String
    var category: String?
    var recommended: Recommended
    var files: [ModelDetailFile]

    enum CodingKeys: String, CodingKey { case images, summary, description, category, recommended, files }

    init(from decoder: Decoder) throws {
        hit = try ModelHit(from: decoder)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        images = c.lenient([String].self, .images) ?? []
        summary = c.lenient(String.self, .summary) ?? ""
        description = c.lenient(String.self, .description) ?? ""
        category = c.lenient(String.self, .category)
        recommended = c.lenient(Recommended.self, .recommended) ?? Recommended()
        files = c.lenient([ModelDetailFile].self, .files) ?? []
    }

    func encode(to encoder: Encoder) throws {
        try hit.encode(to: encoder)
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(images, forKey: .images)
        try c.encode(summary, forKey: .summary)
        try c.encode(description, forKey: .description)
        try c.encodeIfPresent(category, forKey: .category)
        try c.encode(recommended, forKey: .recommended)
        try c.encode(files, forKey: .files)
    }
}

extension Recommended {
    init() { self.init(nozzle: nil, layerHeight: nil, material: nil, weightG: nil, printHours: nil) }
}

struct SearchPage: Codable, Sendable, Equatable {
    var results: [ModelHit]
    var total: Int?
    var page: Int
    var hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case results, total, page
        case hasMore = "has_more"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        results = c.lenient([ModelHit].self, .results) ?? []
        total = c.lenient(Int.self, .total)
        page = c.lenient(Int.self, .page) ?? 1
        hasMore = c.lenient(Bool.self, .hasMore) ?? false
    }
}

/// 2D G-code preview of a sliced job. Each layer holds paths as `[typeIndex, x0, y0, x1, y1, …]` with
/// coordinates in 1/`unit` mm.
struct Preview: Codable, Sendable, Equatable {
    struct Layer: Codable, Sendable, Equatable {
        var z: Double
        var paths: [[Double]]

        init(z: Double, paths: [[Double]]) { self.z = z; self.paths = paths }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            z = c.lenient(Double.self, .z) ?? 0
            paths = c.lenient([[Double]].self, .paths) ?? []
        }

        enum CodingKeys: String, CodingKey { case z, paths }
    }

    var unit: Double
    var types: [String]
    /// Bed size in mm (x, y) when the server reports it.
    var bed: [Double]?
    var layers: [Layer]

    enum CodingKeys: String, CodingKey { case unit, types, bed, layers }

    init(unit: Double = 10, types: [String] = [], bed: [Double]? = nil, layers: [Layer]) {
        self.unit = unit; self.types = types; self.bed = bed; self.layers = layers
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let u = c.lenient(Double.self, .unit) ?? 10
        unit = u > 0 ? u : 10
        types = c.lenient([String].self, .types) ?? []
        bed = c.lenient([Double].self, .bed)
        layers = c.lenient([Layer].self, .layers) ?? []
    }
}
