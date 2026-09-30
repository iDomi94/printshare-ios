import SceneKit
import XCTest
@testable import PrintShare

final class ThreeMFTests: XCTestCase {
    /// Minimal zip writer for the tests: stored or deflated entries (CRC left 0, the reader does not check it).
    private func zip(_ files: [(String, String)], deflate: Bool) throws -> Data {
        var out = Data(), central = Data()
        func le16(_ v: Int) -> Data { withUnsafeBytes(of: UInt16(v).littleEndian) { Data($0) } }
        func le32(_ v: Int) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
        for (name, text) in files {
            let raw = Data(text.utf8)
            let body = try deflate ? (raw as NSData).compressed(using: .zlib) as Data : raw
            let method = deflate ? 8 : 0
            let offset = out.count
            let n = Data(name.utf8)
            let local: [Data] = [le32(0x0403_4b50), le16(20), le16(0), le16(method), le16(0), le16(0), le32(0),
                                 le32(body.count), le32(raw.count), le16(n.count), le16(0), n, body]
            let entry: [Data] = [le32(0x0201_4b50), le16(20), le16(20), le16(0), le16(method), le16(0), le16(0), le32(0),
                                 le32(body.count), le32(raw.count), le16(n.count), le16(0), le16(0), le16(0), le16(0),
                                 le32(0), le32(offset), n]
            for d in local { out.append(d) }
            for d in entry { central.append(d) }
        }
        let cd = out.count
        out.append(central)
        let end: [Data] = [le32(0x0605_4b50), le16(0), le16(0), le16(files.count), le16(files.count),
                           le32(central.count), le32(cd), le16(0)]
        for d in end { out.append(d) }
        return out
    }

    private let rels = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
     <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
    </Relationships>
    """

    private func triangle(_ id: Int, size: Float) -> String {
        """
        <object id="\(id)" type="model"><mesh><vertices>
          <vertex x="0" y="0" z="0"/><vertex x="\(size)" y="0" z="0"/><vertex x="0" y="\(size)" z="\(size / 2)"/>
        </vertices><triangles><triangle v1="0" v2="1" v3="2"/><triangle v1="0" v2="1" v3="9"/></triangles></mesh></object>
        """
    }

    func testPlain3MFWithBuildTransform() throws {
        let model = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <resources>\(triangle(1, size: 20))</resources>
         <build><item objectid="1" transform="1 0 0 0 1 0 0 0 1 100 50 0"/></build>
        </model>
        """
        let data = try zip([("_rels/.rels", rels), ("3D/3dmodel.model", model)], deflate: false)
        let parts = try ThreeMFReader.read(data)
        XCTAssertEqual(parts.count, 1)
        XCTAssertNil(parts[0].color)
        // the triangle with the vertex index 9 is skipped (only 3 vertices)
        XCTAssertEqual(parts[0].vertices, [SIMD3<Float>(100, 50, 0), SIMD3<Float>(120, 50, 0), SIMD3<Float>(100, 70, 10)])
    }

    func testOrcaProjectWithPartsInOwnFilesAndColours() throws {
        let root = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
               xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06">
         <resources>
          <object id="3" type="model"><components>
            <component p:path="/3D/Objects/object_1.model" objectid="1" transform="1 0 0 0 1 0 0 0 1 0 0 0"/>
            <component p:path="/3D/Objects/object_1.model" objectid="2" transform="1 0 0 0 1 0 0 0 1 0 0 5"/>
          </components></object>
         </resources>
         <build><item objectid="3" transform="1 0 0 0 1 0 0 0 1 10 0 0" printable="1"/></build>
        </model>
        """
        let objects = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <resources>\(triangle(1, size: 10))\(triangle(2, size: 4))</resources><build/>
        </model>
        """
        let settings = """
        <?xml version="1.0" encoding="UTF-8"?>
        <config>
          <object id="3"><metadata key="name" value="Box"/><metadata key="extruder" value="1"/>
            <part id="1" subtype="normal_part"><metadata key="extruder" value="0"/></part>
            <part id="2" subtype="normal_part"><metadata key="extruder" value="2"/></part>
          </object>
        </config>
        """
        let project = ##"{"filament_colour": ["#FF0000", "#00FF00"], "layer_height": "0.2"}"##
        let data = try zip([("_rels/.rels", rels), ("3D/3dmodel.model", root), ("3D/Objects/object_1.model", objects),
                            ("Metadata/model_settings.config", settings), ("Metadata/project_settings.config", project)],
                           deflate: true)
        let parts = try ThreeMFReader.read(data)
        XCTAssertEqual(parts.map(\.color), ["#FF0000", "#00FF00"])
        XCTAssertEqual(parts[0].vertices.first, SIMD3<Float>(10, 0, 0))   // part 1: object colour (extruder 0 = inherit)
        XCTAssertEqual(parts[1].vertices.last, SIMD3<Float>(10, 4, 7))    // part 2: moved up 5 mm, then 10 mm in x
    }

    @MainActor
    func testSceneFromA3MF() throws {
        let model = """
        <model xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <resources>\(triangle(1, size: 20))</resources><build><item objectid="1"/></build></model>
        """
        // no _rels: the reader falls back to 3D/3dmodel.model (name case differs on purpose)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID().uuidString).3mf")
        try zip([("3D/3DModel.model", model)], deflate: true).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let built = try ModelScene.make(url)
        let (lo, hi) = built.scene.rootNode.childNodes[0].boundingBox
        XCTAssertEqual(Double(hi.x - lo.x), 20, accuracy: 0.01)
        XCTAssertEqual(Double(hi.y - lo.y), 10, accuracy: 0.01)
    }

    func testRejectsBrokenFiles() throws {
        XCTAssertThrowsError(try ThreeMFReader.read(Data("solid x".utf8)))
        let empty = try zip([("3D/3dmodel.model", "<model><resources/><build/></model>")], deflate: false)
        XCTAssertThrowsError(try ThreeMFReader.read(empty))
    }

    func testTransformAndPrusaColours() {
        let m = ThreeMFReader.transform("0 1 0 -1 0 0 0 0 1 5 6 7")  // 90° about Z, then moved
        let p = m * SIMD4<Float>(1, 0, 0, 1)
        XCTAssertEqual(SIMD3(p.x, p.y, p.z), SIMD3<Float>(5, 7, 7))
        XCTAssertEqual(ThreeMFReader.transform(nil), matrix_identity_float4x4)
        let cfg = """
        ; extruder_colour = "";""
        ; filament_colour = "#FF8000";"#FFFFFF"
        """
        XCTAssertEqual(ObjectSettings.prusaColors(cfg), ["#FF8000", "#FFFFFF"])
        XCTAssertEqual(ObjectSettings.prusaColors("; extruder_colour = \"#123456\";\"\"\n"), ["#123456", ""])
    }
}
