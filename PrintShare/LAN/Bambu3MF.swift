import Compression
import CryptoKit
import Foundation

/// Bambu printers start prints from a ".gcode.3mf": the G-code as `Metadata/plate_1.gcode` plus its MD5 and a
/// `slice_info.config` naming the filaments (Expo app `modules/bambu-lan` BambuCore.wrap3mf, server `bambu.wrap_3mf`).
enum Bambu3MF {
    /// Filament types and colours from the end of an OrcaSlicer G-code ("; filament_type = PLA;PETG").
    static func filaments(tail text: String) -> (types: [String], colours: [String]) {
        func field(_ key: String) -> [String] {
            let lines = text.components(separatedBy: "\n").filter { $0.hasPrefix("; \(key) = ") }
            guard let v = lines.last?.dropFirst("; \(key) = ".count).trimmingCharacters(in: .whitespacesAndNewlines),
                  !v.isEmpty else { return [] }
            return v.split(separator: ";", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "") }
        }
        let types = field("filament_type")
        return (types.isEmpty ? ["PLA"] : types, field("filament_colour"))
    }

    static func filaments(of gcode: URL) throws -> (types: [String], colours: [String]) {
        let h = try FileHandle(forReadingFrom: gcode)
        defer { try? h.close() }
        let size = try h.seekToEnd()
        try h.seek(toOffset: size - min(size, 600_000))
        return filaments(tail: String(decoding: try h.readToEnd() ?? Data(), as: UTF8.self))
    }

    private static func xml(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
    }

    static func sliceInfo(types: [String], colours: [String]) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<config>\n  <plate>\n    <metadata key=\"index\" value=\"1\"/>\n"
        for (i, type) in types.enumerated() {
            let colour = i < colours.count && colours[i].hasPrefix("#") ? colours[i] : "#FFFFFF"
            out += "    <filament id=\"\(i + 1)\" type=\"\(xml(type))\" color=\"\(xml(colour))\" />\n"
        }
        return out + "  </plate>\n</config>\n"
    }

    static let contentTypes = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
         <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
         <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
         <Default Extension="gcode" ContentType="text/x.gcode"/>
        </Types>

        """
    static let rels = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
         <Relationship Target="/3D/3dmodel.model" Id="rel-1" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
        </Relationships>

        """
    static let model = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <metadata name="Application">PocketPrint3D</metadata>
         <resources/>
         <build/>
        </model>

        """

    /// Wraps the G-code into a minimal sliced 3MF at `out`; returns the number of filaments in it.
    @discardableResult
    static func wrap(gcode: URL, to out: URL) throws -> Int {
        let fil = try filaments(of: gcode)
        let zip = try ZipWriter(url: out)
        try zip.add("[Content_Types].xml", Data(contentTypes.utf8))
        try zip.add("_rels/.rels", Data(rels.utf8))
        try zip.add("3D/3dmodel.model", Data(model.utf8))
        try zip.add("Metadata/slice_info.config", Data(sliceInfo(types: fil.types, colours: fil.colours).utf8))
        var md5 = Insecure.MD5()
        try zip.add("Metadata/plate_1.gcode", file: gcode) { md5.update(data: $0) }
        let hex = md5.finalize().map { String(format: "%02X", $0) }.joined()
        try zip.add("Metadata/plate_1.gcode.md5", Data(hex.utf8))
        try zip.finish()
        return fil.types.count
    }
}

/// Minimal zip writer (deflate, no zip64) – enough for the print file; streams large entries from disk.
final class ZipWriter {
    private struct Entry { var name: Data; var crc: UInt32; var compressed: UInt32; var size: UInt32; var offset: UInt32 }

    private let out: FileHandle
    private var entries: [Entry] = []

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        out = try FileHandle(forWritingTo: url)
    }

    deinit { try? out.close() }

    func add(_ name: String, _ data: Data) throws {
        try add(name, chunks: { emit in try emit(data) }, onRaw: nil)
    }

    /// Streams `file` into the entry; `onRaw` sees every uncompressed chunk (for a checksum of the content).
    func add(_ name: String, file: URL, onRaw: ((Data) -> Void)? = nil) throws {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        try add(name, chunks: { emit in
            while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty { try emit(chunk) }
        }, onRaw: onRaw)
    }

    private func add(_ name: String, chunks: ((Data) throws -> Void) throws -> Void, onRaw: ((Data) -> Void)?) throws {
        let nameData = Data(name.utf8)
        let offset = try out.offset()
        try out.write(contentsOf: localHeader(nameData, crc: 0, compressed: 0, size: 0))
        var crc: UInt32 = 0, size: UInt64 = 0, compressed: UInt64 = 0
        let sink = out
        let filter = try OutputFilter(.compress, using: .zlib) { (data: Data?) in   // zlib here = raw deflate
            if let data { compressed += UInt64(data.count); try sink.write(contentsOf: data) }
        }
        try chunks { chunk in
            crc = CRC32.update(crc, chunk)
            size += UInt64(chunk.count)
            onRaw?(chunk)
            try filter.write(chunk)
        }
        try filter.finalize()
        guard size < 0xFFFF_FFFF, compressed < 0xFFFF_FFFF, offset < 0xFFFF_FFFF else { throw LanError("the print file is too large") }
        let end = try out.offset()
        try out.seek(toOffset: offset)
        try out.write(contentsOf: localHeader(nameData, crc: crc, compressed: UInt32(compressed), size: UInt32(size)))
        try out.seek(toOffset: end)
        entries.append(Entry(name: nameData, crc: crc, compressed: UInt32(compressed), size: UInt32(size), offset: UInt32(offset)))
    }

    private func localHeader(_ name: Data, crc: UInt32, compressed: UInt32, size: UInt32) -> Data {
        var d = Data()
        d.le32(0x0403_4b50); d.le16(20); d.le16(0); d.le16(8)                // version, flags, deflate
        d.le16(0); d.le16(0x21)                                                 // time, date (1980-01-01)
        d.le32(crc); d.le32(compressed); d.le32(size)
        d.le16(UInt16(name.count)); d.le16(0)
        d.append(name)
        return d
    }

    func finish() throws {
        let start = try out.offset()
        var dir = Data()
        for e in entries {
            dir.le32(0x0201_4b50); dir.le16(20); dir.le16(20); dir.le16(0); dir.le16(8)
            dir.le16(0); dir.le16(0x21)
            dir.le32(e.crc); dir.le32(e.compressed); dir.le32(e.size)
            dir.le16(UInt16(e.name.count)); dir.le16(0); dir.le16(0)          // name, extra, comment
            dir.le16(0); dir.le16(0); dir.le32(0)                               // disk, internal, external attributes
            dir.le32(e.offset)
            dir.append(e.name)
        }
        try out.write(contentsOf: dir)
        var end = Data()
        end.le32(0x0605_4b50); end.le16(0); end.le16(0)
        end.le16(UInt16(entries.count)); end.le16(UInt16(entries.count))
        end.le32(UInt32(dir.count)); end.le32(UInt32(start)); end.le16(0)
        try out.write(contentsOf: end)
        try out.close()
    }
}

enum CRC32 {
    static let table: [UInt32] = (0 ..< 256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0 ..< 8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func update(_ crc: UInt32, _ data: Data) -> UInt32 {
        var c = ~crc
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            for b in buf { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return ~c
    }
}

private extension Data {
    mutating func le16(_ v: UInt16) { append(UInt8(v & 0xFF)); append(UInt8(v >> 8)) }
    mutating func le32(_ v: UInt32) { for s in stride(from: 0, to: 32, by: 8) { append(UInt8((v >> UInt32(s)) & 0xFF)) } }
}
