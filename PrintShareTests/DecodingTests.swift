import XCTest
@testable import PrintShare

final class DecodingTests: XCTestCase {
    func testInfo() throws {
        let i = try Fixture.decode(ServerInfo.self, "info")
        XCTAssertEqual(i, ServerInfo(name: "PrintShare", version: "0.4.0", printers: 1))
    }

    func testPrinters() throws {
        let p = try Fixture.decode([Printer].self, "printers")
        XCTAssertEqual(p.map(\.id), ["centauri-carbon", "mk4"])
        XCTAssertNil(p[0].leveling)
        XCTAssertEqual(p[1].leveling, true)
    }

    func testOptions() throws {
        let o = try Fixture.decode(Options.self, "options")
        XCTAssertEqual(o.materials.count, 2)
        XCTAssertEqual(o.defaults.bedType, "Textured PEI Plate")
        XCTAssertEqual(o.defaults.infill, 15)
        XCTAssertEqual(o.defaults.layerHeight, "0.2")
        XCTAssertEqual(o.brims, ["auto", "off", "outer"])
    }

    func testStatus() throws {
        let s = try Fixture.decode(PrinterStatus.self, "status")
        XCTAssertEqual(s.kind, .active)
        XCTAssertEqual(s.layers, 240)
        XCTAssertEqual(s.timeRemainingS, 1200.5)
        XCTAssertEqual(s.nozzleTarget, 220)
        XCTAssertNil(s.camera)
    }

    func testUnknownStatusKindDoesNotBreakDecoding() throws {
        let s = try Fixture.decode(PrinterStatus.self, "status_unknown_kind")
        XCTAssertEqual(s.kind, .unknown)
        XCTAssertEqual(s.state, "teleporting")
        XCTAssertNil(s.progress)
    }

    func testJobKeepsOverrideKeys() throws {
        let j = try Fixture.decode(Job.self, "job_sliced")
        XCTAssertEqual(j.state, .sliced)
        XCTAssertEqual(j.result?.overrides["enable_support"], "1")
        XCTAssertEqual(j.result?.profiles["bed_type"], "Textured PEI Plate")
        XCTAssertEqual(j.result?.sourceFile, "3dbenchy.stl")
        XCTAssertEqual(j.result?.filamentG, 11.49)
        XCTAssertEqual(j.request.options?.bedType, "Textured PEI Plate")
        XCTAssertEqual(j.request.options?.infill, 20)
        XCTAssertNil(j.request.file)
        XCTAssertEqual(j.log.count, 3)
    }

    func testUnknownJobState() throws {
        let j = try Fixture.decode(Job.self, "job_unknown_state")
        XCTAssertEqual(j.state, .unknown)
        XCTAssertFalse(j.state.isWorking)
        XCTAssertEqual(j.error, "Sending failed: boom")
        XCTAssertNil(j.result)
    }

    func testJobSummaries() throws {
        let j = try Fixture.decode([JobSummary].self, "jobs")
        XCTAssertEqual(j.map(\.state), [.sliced, .done])
        XCTAssertEqual(j[0].printTime, "35m 32s")
        XCTAssertNil(j[1].printer)
    }

    func testFilesAndUpload() throws {
        let f = try Fixture.decode([ModelFile].self, "files")
        XCTAssertEqual(f.map(\.name), ["benchy.stl", "benchy.3mf"])
        XCTAssertNil(f[1].size)
        let u = try Fixture.decode(Upload.self, "upload")
        XCTAssertEqual(u.link, "upload:0123456789ab")
    }

    func testSearch() throws {
        let s = try Fixture.decode([Source].self, "sources")
        XCTAssertEqual(s.filter(\.available).map(\.id), ["printables"])
        let page = try Fixture.decode(SearchPage.self, "search")
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.total, 42)
        XCTAssertEqual(page.results[0].likes, 12345)
        XCTAssertNil(page.results[0].downloads)
        XCTAssertEqual(page.results[1].id, "763622")  // numeric ids are accepted
    }

    func testModelDetail() throws {
        let m = try Fixture.decode(ModelDetail.self, "model")
        XCTAssertEqual(m.hit.name, "3D Benchy")
        XCTAssertEqual(m.images.count, 2)
        XCTAssertEqual(m.recommended.layerHeight, "0.2 mm")
        XCTAssertEqual(m.recommended.printHours, 0.6)
        XCTAssertEqual(m.files.filter(\.sliceable).count, 1)
        XCTAssertFalse(m.recommended.isEmpty)
    }

    func testPreview() throws {
        let p = try Fixture.decode(Preview.self, "preview")
        XCTAssertEqual(p.unit, 10)
        XCTAssertEqual(p.layers.count, 2)
        XCTAssertEqual(p.layers[0].paths[0], [0, 1000, 1000, 1500, 1000, 1500, 1500])
        XCTAssertEqual(p.bed, [256, 256])
    }

    func testJobOptionsEncodingUsesServerKeys() throws {
        let data = try JSONEncoder().encode(JobOptions(process: "p", bedType: "Cool Plate", infill: 10))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["bed_type"] as? String, "Cool Plate")
        XCTAssertEqual(obj["infill"] as? Int, 10)
        XCTAssertNil(obj["filament"])
    }

    func testServerStorageFormatMatchesExpoApp() throws {
        let s = Server(url: "http://a", token: "t", remoteUrl: "http://b")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: String])
        XCTAssertEqual(obj, ["url": "http://a", "token": "t", "remoteUrl": "http://b"])
    }

    // MARK: server 0.6.0 (multicolour, preview format 2)

    func testPreviewFormat2() throws {
        let p = try Fixture.decode(Preview.self, "preview_v2")
        XCTAssertEqual(p.version, 2)
        XCTAssertTrue(p.hasTools)
        XCTAssertEqual(p.unit, 20)
        XCTAssertEqual(p.bounds, [100, 100, 110, 110])
        XCTAssertEqual(p.filamentColors, ["#FF0000", "#FFFFFF"])
        XCTAssertEqual(p.layers[0].paths[2][1], 1)  // tool of the infill after T1
    }

    func testPreviewFormat1HasNoTools() throws {
        let p = try Fixture.decode(Preview.self, "preview")
        XCTAssertEqual(p.version, 1)
        XCTAssertFalse(p.hasTools)
        XCTAssertNil(p.bounds)
        XCTAssertTrue(p.filamentColors.isEmpty)
    }

    func testInspect() throws {
        let c = try Fixture.decode(ModelColors.self, "inspect")
        XCTAssertEqual(c.file, "two colours.3mf")
        XCTAssertTrue(c.isMulticolor)
        XCTAssertEqual(c.usedFilaments.map(\.index), [1, 2])
        XCTAssertNil(c.filaments[1].name)
        XCTAssertFalse(c.painted)
        XCTAssertFalse(ModelColors(filaments: [.init(index: 1, color: "#FF0000")], used: [1]).isMulticolor)
    }

    func testJobWithFilaments() throws {
        let j = try Fixture.decode(Job.self, "job_multicolor")
        XCTAssertEqual(j.result?.filaments.map(\.index), [1, 2])
        XCTAssertEqual(j.result?.filaments[0].grams, 12.25)
        XCTAssertNil(j.result?.filaments[1].color)
        XCTAssertEqual(j.request.options?.filaments, [nil, "Generic PETG @ECC"])
        // single-colour jobs of older servers have no list
        XCTAssertEqual(try Fixture.decode(Job.self, "job_sliced").result?.filaments, [])
    }

    func testJobOptionsEncodeFilamentsWithNulls() throws {
        let o = JobOptions(process: "q", filaments: [nil, "PETG"])
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(o)) as? [String: Any])
        let list = try XCTUnwrap(obj["filaments"] as? [Any])
        XCTAssertTrue(list[0] is NSNull)
        XCTAssertEqual(list[1] as? String, "PETG")
        XCTAssertNil(obj["filament"])
        let plain = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(JobOptions())) as? [String: Any])
        XCTAssertNil(plain["filaments"])
    }
}
