import Foundation

/// OpenPrintTag (https://specs.openprinttag.org): Prusa's open NFC standard for filament spools. Port of the Expo app's
/// `lib/openprinttag.ts`: finds the NDEF record "application/vnd.openprinttag" in the tag memory (NFC Type 5 /
/// ISO 15693) and decodes its CBOR sections: meta (where the regions are), main (material data), aux (consumed amount).
/// Read only.
struct OpenPrintTag: Sendable, Equatable {
    var uid = ""
    var brand: String?
    /// material_name, e.g. "PLA Galaxy Black"
    var name: String?
    /// "PLA", "PETG" …
    var materialType: String?
    /// "#RRGGBB"
    var color: String?
    /// g of material on the full spool (actual, else nominal)
    var fullWeight: Double?
    var emptySpoolWeight: Double?
    var consumedWeight: Double?
    var remainingWeight: Double?
    var density: Double?
    var location: String?

    struct TagError: Error, Equatable {
        var message: String
        init(_ message: String) { self.message = message }
    }

    static let mime = "application/vnd.openprinttag"

    /// fff_material_types (specs.openprinttag.org): key → abbreviation
    static let materialTypes: [Int: String] = [
        0: "PLA", 1: "PETG", 2: "TPU", 3: "ABS", 4: "ASA", 5: "PC", 6: "PCTG", 7: "PP", 8: "PA6", 9: "PA11", 10: "PA12",
        11: "PA66", 12: "CPE", 13: "TPE", 14: "HIPS", 15: "PHA", 16: "PET", 17: "PEI", 18: "PBT", 19: "PVB", 20: "PVA",
        21: "PEKK", 22: "PEEK", 23: "BVOH", 24: "TPC", 25: "PPS", 26: "PPSU", 27: "PVC", 28: "PEBA", 29: "PVDF", 30: "PPA",
        31: "PCL", 32: "PES", 33: "PMMA", 34: "POM", 35: "PPE", 36: "PS", 37: "PSU", 38: "TPI", 39: "SBS", 40: "OBC",
        41: "EVA", 42: "PA612",
    ]

    /// "Prusament PLA Galaxy Black" - brand + material name, as the spec recommends.
    var label: String {
        let s = [brand, name ?? materialType].compactMap { $0 }.joined(separator: " ")
        return s.isEmpty ? "OpenPrintTag" : s
    }

    /// Decodes the tag memory (all blocks, from block 0).
    static func parse(_ mem: [UInt8], uid: String = "") throws -> OpenPrintTag {
        let payload = try findPayload(mem)
        let metaItem = try CBOR.decode(payload, at: 0)
        let meta = try map(metaItem.value)
        let mainAt = number(meta[0]).map(Int.init) ?? metaItem.end
        let main = try map(try CBOR.decode(payload, at: mainAt).value)
        var aux: [Int: CBOR] = [:]
        if let at = number(meta[2]).map(Int.init), at < payload.count {
            aux = (try? map(try CBOR.decode(payload, at: at).value)) ?? [:]   // a fresh/wiped aux region may be empty
        }
        let full = number(main[17]) ?? number(main[16])
        let consumed = number(aux[0])
        var t = OpenPrintTag(uid: uid)
        t.brand = text(main[11])
        t.name = text(main[10])
        t.materialType = text(main[52]) ?? number(main[9]).flatMap { materialTypes[Int($0)] }
        t.color = rgb(main[19])
        t.fullWeight = full
        t.emptySpoolWeight = number(main[18])
        t.consumedWeight = consumed
        t.remainingWeight = full.map { max(0, $0 - (consumed ?? 0)) }
        t.density = number(main[29])
        t.location = text(aux[4])
        return t
    }

    // MARK: NFC Type 5 memory → NDEF record payload

    /// The payload of the OpenPrintTag NDEF record (capability container, TLVs, NDEF message).
    static func findPayload(_ mem: [UInt8]) throws -> [UInt8] {
        guard mem.count >= 8, mem[0] == 0xE1 || mem[0] == 0xE2 else {
            throw TagError("not an NFC Forum tag (no capability container)")
        }
        var p = mem[2] == 0 ? 8 : 4          // 8-byte CC when the size doesn't fit one byte
        while p < mem.count {
            let t = mem[p]; p += 1
            if t == 0x00 { continue }         // NULL TLV
            if t == 0xFE { break }            // terminator
            guard p < mem.count else { break }
            var len = Int(mem[p]); p += 1
            if len == 0xFF {
                guard p + 1 < mem.count else { break }
                len = Int(mem[p]) << 8 | Int(mem[p + 1]); p += 2
            }
            if t == 0x03 { return try findRecord(Array(mem[p ..< min(mem.count, p + len)])) }
            p += len
        }
        throw TagError("the tag has no NDEF data")
    }

    private static func findRecord(_ msg: [UInt8]) throws -> [UInt8] {
        var p = 0
        func byte() throws -> Int {
            guard p < msg.count else { throw TagError("tag data ends too early") }
            defer { p += 1 }
            return Int(msg[p])
        }
        while p < msg.count {
            let hdr = try byte()
            let tnf = hdr & 7, sr = hdr & 0x10, il = hdr & 0x08, cf = hdr & 0x20
            let typeLen = try byte()
            var payLen = 0
            if sr != 0 { payLen = try byte() } else { for _ in 0 ..< 4 { payLen = payLen << 8 | (try byte()) } }
            let idLen = il != 0 ? try byte() : 0
            guard p + typeLen <= msg.count else { throw TagError("tag data ends too early") }
            let type = String(decoding: msg[p ..< p + typeLen], as: UTF8.self)
            p += typeLen + idLen
            guard p + payLen <= msg.count else { throw TagError("tag data ends too early") }
            let payload = Array(msg[p ..< p + payLen])
            p += payLen
            if tnf == 2 && type == mime && cf == 0 { return payload }
            if hdr & 0x40 != 0 { break }      // message end
        }
        throw TagError("no OpenPrintTag data on this tag")
    }

    // MARK: sections

    private static func map(_ v: CBOR) throws -> [Int: CBOR] {
        guard case .map(let pairs) = v else { throw TagError("bad OpenPrintTag section") }
        var out: [Int: CBOR] = [:]
        for (k, x) in pairs { if let n = number(k) { out[Int(n)] = x } }
        return out
    }

    private static func number(_ v: CBOR?) -> Double? {
        switch v {
        case .int(let n): return Double(n)
        case .float(let d): return d.isFinite ? d : nil
        default: return nil
        }
    }

    private static func text(_ v: CBOR?) -> String? {
        guard case .text(let s) = v else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func rgb(_ v: CBOR?) -> String? {
        guard case .bytes(let b) = v, b.count >= 3 else { return nil }
        return "#" + b.prefix(3).map { String(format: "%02X", $0) }.joined()
    }
}

/// CBOR (RFC 8949), only what the tags use.
indirect enum CBOR: Equatable, Sendable {
    case int(Int64)
    case float(Double)
    case bytes([UInt8])
    case text(String)
    case array([CBOR])
    case map([(CBOR, CBOR)])
    case bool(Bool)
    case null
    case simple(Int)
    case breakMark

    static func == (a: CBOR, b: CBOR) -> Bool {
        switch (a, b) {
        case (.int(let x), .int(let y)): return x == y
        case (.float(let x), .float(let y)): return x == y
        case (.bytes(let x), .bytes(let y)): return x == y
        case (.text(let x), .text(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.map(let x), .map(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case (.bool(let x), .bool(let y)): return x == y
        case (.null, .null), (.breakMark, .breakMark): return true
        case (.simple(let x), .simple(let y)): return x == y
        default: return false
        }
    }

    /// One item at `pos`; returns it and the position after it.
    static func decode(_ b: [UInt8], at pos: Int) throws -> (value: CBOR, end: Int) {
        var p = pos
        func need(_ n: Int) throws {
            if p + n > b.count { throw OpenPrintTag.TagError("tag data ends too early") }
        }
        func uint(_ info: Int) throws -> UInt64? {
            switch info {
            case 0 ..< 24: return UInt64(info)
            case 24 ... 27:
                let n = 1 << (info - 24)
                try need(n)
                var v: UInt64 = 0
                for i in 0 ..< n { v = v << 8 | UInt64(b[p + i]) }
                p += n
                return v
            case 31: return nil               // indefinite length
            default: throw OpenPrintTag.TagError("unsupported CBOR length")
            }
        }
        func item(_ depth: Int) throws -> CBOR {
            if depth > 32 { throw OpenPrintTag.TagError("bad CBOR") }
            try need(1)
            let ib = Int(b[p]); p += 1
            let major = ib >> 5, info = ib & 31
            if major == 7 {
                switch info {
                case 31: return .breakMark
                case 20: return .bool(false)
                case 21: return .bool(true)
                case 22, 23: return .null
                case 25:
                    try need(2)
                    let v = half(UInt16(b[p]) << 8 | UInt16(b[p + 1])); p += 2
                    return .float(v)
                case 26:
                    try need(4)
                    let bits = b[p ..< p + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }; p += 4
                    return .float(Double(Float(bitPattern: bits)))
                case 27:
                    try need(8)
                    let bits = b[p ..< p + 8].reduce(UInt64(0)) { $0 << 8 | UInt64($1) }; p += 8
                    return .float(Double(bitPattern: bits))
                case 0 ..< 24: return .simple(info)
                default: throw OpenPrintTag.TagError("unsupported CBOR simple value")
                }
            }
            let n = try uint(info)
            switch major {
            case 0: return .int(Int64(clamping: n ?? 0))
            case 1: return .int(-1 - Int64(clamping: n ?? 0))
            case 2, 3:
                var bytes: [UInt8] = []
                if let n {
                    guard n <= UInt64(b.count) else { throw OpenPrintTag.TagError("tag data ends too early") }
                    try need(Int(n))
                    bytes = Array(b[p ..< p + Int(n)]); p += Int(n)
                } else {                       // indefinite: chunks until break
                    while true {
                        let c = try item(depth + 1)
                        if c == .breakMark { break }
                        if case .bytes(let x) = c { bytes += x } else if case .text(let s) = c { bytes += Array(s.utf8) }
                    }
                }
                return major == 2 ? .bytes(bytes) : .text(String(decoding: bytes, as: UTF8.self))
            case 4:
                var arr: [CBOR] = []
                var i: UInt64 = 0
                while n == nil || i < n! {
                    let v = try item(depth + 1)
                    if v == .breakMark { break }
                    arr.append(v)
                    i += 1
                }
                return .array(arr)
            case 5:
                var pairs: [(CBOR, CBOR)] = []
                var i: UInt64 = 0
                while n == nil || i < n! {
                    let k = try item(depth + 1)
                    if k == .breakMark { break }
                    pairs.append((k, try item(depth + 1)))
                    i += 1
                }
                return .map(pairs)
            case 6: return try item(depth + 1)   // tag: the tagged value
            default: throw OpenPrintTag.TagError("bad CBOR")
            }
        }
        let v = try item(0)
        return (v, p)
    }

    private static func half(_ h: UInt16) -> Double {
        let s: Double = h & 0x8000 != 0 ? -1 : 1
        let e = Int(h >> 10) & 0x1F, f = Double(h & 0x3FF)
        if e == 0 { return s * pow(2, -14) * (f / 1024) }
        if e == 31 { return f != 0 ? .nan : s * .infinity }
        return s * pow(2, Double(e - 15)) * (1 + f / 1024)
    }
}
