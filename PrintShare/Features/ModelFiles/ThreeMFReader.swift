import Foundation
import simd

/// 3MF (a zip with XML meshes) → triangles per filament colour, for the 3D view before slicing.
/// Handles plain 3MF, OrcaSlicer/Bambu projects (objects split into `3D/Objects/*.model`, colours per object/part
/// from `Metadata/model_settings.config` + `project_settings.config`) and PrusaSlicer projects (object colours).
/// Painted colours (`paint_color`, `mmu_segmentation`) are not shown; such objects get their object colour.
enum ThreeMFReader {
    struct Part: Equatable {
        /// "#RRGGBB" of the filament, nil = unknown (the view uses its accent colour).
        var color: String?
        /// Triangle soup in model coordinates (mm, Z up), three vertices per triangle.
        var vertices: [SIMD3<Float>]
    }

    enum Failure: Error { case notAZip, unsupported, noModel }

    static func read(_ data: Data) throws -> [Part] {
        let zip = try ZipReader(data)
        let root = rootModelPath(zip)
        guard let rootData = try zip.read(root) else { throw Failure.noModel }
        var files: [String: ModelXML] = [root: try ModelXML.parse(rootData)]
        func model(_ path: String) throws -> ModelXML? {
            if let m = files[path] { return m }
            guard let d = try zip.read(path) else { return nil }
            let m = try ModelXML.parse(d)
            files[path] = m
            return m
        }

        let settings = try ObjectSettings(zip)
        var byColor: [Int: [SIMD3<Float>]] = [:]  // extruder (1-based, 0 = unknown) -> triangles
        var depth = 0

        func add(path: String, id: Int, transform: simd_float4x4, extruder: Int, item: Int) throws {
            guard depth < 16, let file = try model(path), let object = file.objects[id] else { return }
            depth += 1
            defer { depth -= 1 }
            if let mesh = object.mesh {
                var out = byColor[extruder, default: []]
                out.reserveCapacity(out.count + mesh.triangles.count * 3)
                let n = mesh.vertices.count
                for t in mesh.triangles where t.x < n && t.y < n && t.z < n && t.x >= 0 && t.y >= 0 && t.z >= 0 {
                    for i in [t.x, t.y, t.z] {
                        let v = transform * SIMD4<Float>(mesh.vertices[i], 1)
                        out.append(SIMD3<Float>(v.x, v.y, v.z))
                    }
                }
                byColor[extruder] = out
            }
            for c in object.components {
                let part = settings.parts[item]?[c.object] ?? 0
                try add(path: c.path ?? path, id: c.object, transform: transform * c.transform,
                        extruder: part > 0 ? part : extruder, item: item)
            }
        }

        for item in files[root]?.items ?? [] {
            try add(path: item.path ?? root, id: item.object, transform: item.transform,
                    extruder: settings.objects[item.object] ?? 0, item: item.object)
        }
        let parts = byColor.keys.sorted().compactMap { k -> Part? in
            guard let v = byColor[k], !v.isEmpty else { return nil }
            let color = k > 0 && k <= settings.colors.count ? settings.colors[k - 1] : nil
            return Part(color: color, vertices: v)
        }
        guard !parts.isEmpty else { throw Failure.noModel }
        return parts
    }

    /// The model the package points at (`_rels/.rels`), else `3D/3dmodel.model`, else the first `.model` file.
    static func rootModelPath(_ zip: ZipReader) -> String {
        if let rels = try? zip.read("_rels/.rels"), let text = String(data: rels, encoding: .utf8),
           let target = firstMatch(#"Target="([^"]+)"[^>]*Type="[^"]*3dmodel""#, text)
                ?? firstMatch(#"Type="[^"]*3dmodel"[^>]*Target="([^"]+)""#, text) {
            let path = normalize(target)
            if zip.has(path) { return path }
        }
        if zip.has("3D/3dmodel.model") { return "3D/3dmodel.model" }
        return zip.names.sorted().first { $0.lowercased().hasSuffix(".model") } ?? "3D/3dmodel.model"
    }

    static func normalize(_ path: String) -> String {
        path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    static func firstMatch(_ pattern: String, _ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// "m00 m01 m02 m10 m11 m12 m20 m21 m22 m30 m31 m32" (3MF row-vector form) → column-vector affine matrix.
    static func transform(_ s: String?) -> simd_float4x4 {
        let m = (s ?? "").split(whereSeparator: \.isWhitespace).compactMap { Float($0) }
        guard m.count == 12 else { return matrix_identity_float4x4 }
        return simd_float4x4(rows: [SIMD4(m[0], m[3], m[6], m[9]), SIMD4(m[1], m[4], m[7], m[10]),
                                    SIMD4(m[2], m[5], m[8], m[11]), SIMD4(0, 0, 0, 1)])
    }
}

// MARK: one .model file

/// Objects (mesh or components) and build items of one 3MF model file.
final class ModelXML: NSObject, XMLParserDelegate {
    struct Mesh {
        var vertices: [SIMD3<Float>] = []
        var triangles: [SIMD3<Int>] = []
    }

    struct Ref {
        var object: Int
        var path: String?
        var transform: simd_float4x4
    }

    struct Object {
        var mesh: Mesh?
        var components: [Ref] = []
    }

    private(set) var objects: [Int: Object] = [:]
    private(set) var items: [Ref] = []
    private var current: Int?
    private var object = Object()

    static func parse(_ data: Data) throws -> ModelXML {
        let model = ModelXML()
        let parser = XMLParser(data: data)
        parser.delegate = model
        guard parser.parse() else { throw parser.parserError ?? ThreeMFReader.Failure.noModel }
        return model
    }

    private static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    /// Attribute by local name ("p:path" → "path").
    private static func attr(_ a: [String: String], _ name: String) -> String? {
        a[name] ?? a.first { local($0.key) == name }?.value
    }

    private static func ref(_ a: [String: String]) -> Ref? {
        guard let id = attr(a, "objectid").flatMap({ Int($0) }) else { return nil }
        return Ref(object: id, path: attr(a, "path").map(ThreeMFReader.normalize),
                   transform: ThreeMFReader.transform(attr(a, "transform")))
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes a: [String: String] = [:]) {
        switch Self.local(elementName) {
        case "object":
            current = a["id"].flatMap { Int($0) }
            object = Object()
        case "mesh":
            object.mesh = Mesh()
        case "vertex":
            guard let x = a["x"].flatMap({ Float($0) }), let y = a["y"].flatMap({ Float($0) }),
                  let z = a["z"].flatMap({ Float($0) }) else { return }
            object.mesh?.vertices.append(SIMD3(x, y, z))
        case "triangle":
            guard let v1 = a["v1"].flatMap({ Int($0) }), let v2 = a["v2"].flatMap({ Int($0) }),
                  let v3 = a["v3"].flatMap({ Int($0) }) else { return }
            object.mesh?.triangles.append(SIMD3(v1, v2, v3))
        case "component":
            if let r = Self.ref(a) { object.components.append(r) }
        case "item":
            if let r = Self.ref(a) { items.append(r) }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        if Self.local(elementName) == "object", let id = current {
            objects[id] = object
            current = nil
        }
    }
}

// MARK: slicer project settings (colours per object / part)

/// Filament per build object and per part, and the project's filament colours.
struct ObjectSettings {
    var objects: [Int: Int] = [:]
    var parts: [Int: [Int: Int]] = [:]
    var colors: [String] = []

    init() {}

    init(_ zip: ZipReader) throws {
        if let d = try zip.read("Metadata/model_settings.config") ?? zip.read("Metadata/Slic3r_PE_model.config") {
            let parser = XMLParser(data: d)
            let collector = Collector()
            parser.delegate = collector
            if parser.parse() { objects = collector.objects; parts = collector.parts }
        }
        if let d = try zip.read("Metadata/project_settings.config"),
           let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            colors = Self.hexList(json["filament_colour"])
        } else if let d = try zip.read("Metadata/Slic3r_PE.config"), let text = String(data: d, encoding: .utf8) {
            colors = Self.prusaColors(text)
        }
    }

    static func hexList(_ v: Any?) -> [String] {
        let raw: [String] = (v as? [String]) ?? ((v as? String).map { $0.split(separator: ";").map(String.init) } ?? [])
        return raw.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
    }

    /// `; extruder_colour = "#FF0000";"#00FF00"` wins over `filament_colour` when it has any colour set.
    static func prusaColors(_ text: String) -> [String] {
        func list(_ key: String) -> [String] {
            for line in text.split(whereSeparator: \.isNewline) {
                let l = line.trimmingCharacters(in: .whitespaces)
                guard l.hasPrefix("; \(key) =") else { continue }
                return hexList(String(l.dropFirst("; \(key) =".count)))
            }
            return []
        }
        let extruder = list("extruder_colour")
        return extruder.contains { !$0.isEmpty } ? extruder : list("filament_colour")
    }

    /// `<object id="N"><metadata key="extruder" value="2"/><part id="K"><metadata key="extruder" …/></part>`.
    /// PrusaSlicer volumes (triangle ranges) are skipped.
    private final class Collector: NSObject, XMLParserDelegate {
        var objects: [Int: Int] = [:]
        var parts: [Int: [Int: Int]] = [:]
        private var object: Int?
        private var part: Int?
        private var inVolume = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes a: [String: String] = [:]) {
            switch elementName {
            case "object": object = a["id"].flatMap { Int($0) }
            case "part": part = a["id"].flatMap { Int($0) }
            case "volume": inVolume = true
            case "metadata":
                guard a["key"] == "extruder", let value = a["value"].flatMap({ Int($0) }), let object, !inVolume else { return }
                if let part { parts[object, default: [:]][part] = value } else { objects[object] = value }
            default: break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            switch elementName {
            case "object": object = nil
            case "part": part = nil
            case "volume": inVolume = false
            default: break
            }
        }
    }
}

// MARK: zip

/// Minimal zip reader (stored and deflate, zip64 sizes) – enough for 3MF packages, no third-party code.
struct ZipReader {
    struct Entry {
        var method: UInt16
        var compressed: Int
        var size: Int
        var offset: Int
    }

    private let data: Data
    private var entries: [String: Entry] = [:]
    var names: [String] { Array(entries.keys) }

    /// Larger entries are refused (a 3MF model is far smaller; protects against zip bombs).
    static let maxEntry = 512 * 1024 * 1024

    init(_ data: Data) throws {
        self.data = data.startIndex == 0 ? data : Data(data)
        let d = self.data
        guard d.count >= 22 else { throw ThreeMFReader.Failure.notAZip }
        var eocd = -1
        var i = d.count - 22
        let stop = max(0, d.count - 22 - 65_535)
        while i >= stop {
            if Self.u32(d, i) == 0x0605_4b50 { eocd = i; break }
            i -= 1
        }
        guard eocd >= 0 else { throw ThreeMFReader.Failure.notAZip }
        var count = Int(Self.u16(d, eocd + 10))
        var cd = Int(Self.u32(d, eocd + 16))
        if cd == 0xFFFF_FFFF || count == 0xFFFF {
            // zip64: locator right before the end record points at the zip64 end record
            let loc = eocd - 20
            guard loc >= 0, Self.u32(d, loc) == 0x0706_4b50 else { throw ThreeMFReader.Failure.unsupported }
            let rec = Int(Self.u64(d, loc + 8))
            guard rec >= 0, rec + 56 <= d.count, Self.u32(d, rec) == 0x0606_4b50 else { throw ThreeMFReader.Failure.unsupported }
            count = Int(Self.u64(d, rec + 32))
            cd = Int(Self.u64(d, rec + 48))
        }
        var p = cd
        for _ in 0..<count {
            guard p >= 0, p + 46 <= d.count, Self.u32(d, p) == 0x0201_4b50 else { throw ThreeMFReader.Failure.notAZip }
            let method = Self.u16(d, p + 10)
            var compressed = Int(Self.u32(d, p + 20)), size = Int(Self.u32(d, p + 24))
            let nameLen = Int(Self.u16(d, p + 28)), extraLen = Int(Self.u16(d, p + 30)), commentLen = Int(Self.u16(d, p + 32))
            var offset = Int(Self.u32(d, p + 42))
            guard p + 46 + nameLen + extraLen <= d.count else { throw ThreeMFReader.Failure.notAZip }
            let name = String(decoding: d[(p + 46)..<(p + 46 + nameLen)], as: UTF8.self)
            // zip64 extra field: the 64-bit values of the fields set to 0xFFFFFFFF, in this order
            var e = p + 46 + nameLen
            let end = e + extraLen
            while e + 4 <= end {
                let tag = Self.u16(d, e), len = Int(Self.u16(d, e + 2))
                if tag == 0x0001 {
                    var q = e + 4
                    if size == 0xFFFF_FFFF, q + 8 <= e + 4 + len { size = Int(Self.u64(d, q)); q += 8 }
                    if compressed == 0xFFFF_FFFF, q + 8 <= e + 4 + len { compressed = Int(Self.u64(d, q)); q += 8 }
                    if offset == 0xFFFF_FFFF, q + 8 <= e + 4 + len { offset = Int(Self.u64(d, q)) }
                }
                e += 4 + len
            }
            entries[name] = Entry(method: method, compressed: compressed, size: size, offset: offset)
            p += 46 + nameLen + extraLen + commentLen
        }
    }

    func has(_ name: String) -> Bool { entry(name) != nil }

    /// Names in 3MF are case-insensitive in practice (writers differ in "3D/3dmodel.model" vs "3D/3DModel.model").
    private func entry(_ name: String) -> Entry? {
        entries[name] ?? entries.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// Contents of one file, nil when the package has no such file.
    func read(_ name: String) throws -> Data? {
        guard let e = entry(name) else { return nil }
        let d = data
        guard e.offset >= 0, e.offset + 30 <= d.count, Self.u32(d, e.offset) == 0x0403_4b50,
              e.size <= Self.maxEntry, e.compressed >= 0 else { throw ThreeMFReader.Failure.notAZip }
        let start = e.offset + 30 + Int(Self.u16(d, e.offset + 26)) + Int(Self.u16(d, e.offset + 28))
        guard start + e.compressed <= d.count else { throw ThreeMFReader.Failure.notAZip }
        let raw = d.subdata(in: start..<(start + e.compressed))
        switch e.method {
        case 0:
            return raw
        case 8:
            // Apple's "zlib" algorithm is raw DEFLATE, exactly what zip stores
            return try (raw as NSData).decompressed(using: .zlib) as Data
        default:
            throw ThreeMFReader.Failure.unsupported
        }
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[o]) | UInt16(d[o + 1]) << 8
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        UInt32(u16(d, o)) | UInt32(u16(d, o + 2)) << 16
    }

    private static func u64(_ d: Data, _ o: Int) -> UInt64 {
        UInt64(u32(d, o)) | UInt64(u32(d, o + 4)) << 32
    }
}
