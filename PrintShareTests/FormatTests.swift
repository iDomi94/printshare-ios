import XCTest
@testable import PrintShare

final class FormatTests: XCTestCase {
    func testShortName() {
        XCTAssertEqual(Format.shortName("Elegoo PLA @ECC"), "Elegoo PLA")
        XCTAssertEqual(Format.shortName("0.20mm Standard @Elegoo CC 0.4 nozzle"), "0.20mm Standard")
        XCTAssertEqual(Format.shortName("Plain"), "Plain")
        XCTAssertEqual(Format.shortName(nil), "")
    }

    func testBrandOf() {
        XCTAssertEqual(Format.brandOf("Elegoo PLA @ECC"), "Elegoo")
        XCTAssertEqual(Format.brandOf("@x"), "@x")
    }

    func testExtractLink() {
        XCTAssertEqual(Format.extractLink("Look: https://www.printables.com/model/3161-3d-benchy, cool"),
                       "https://www.printables.com/model/3161-3d-benchy,")
        XCTAssertEqual(Format.extractLink("<https://a.b/c>"), "https://a.b/c")
        XCTAssertEqual(Format.extractLink("no link"), "")
        XCTAssertEqual(Format.extractLink(nil), "")
    }

    func testJobName() {
        XCTAssertEqual(Format.jobName(file: "benchy.stl", link: "x"), "benchy.stl")
        XCTAssertEqual(Format.jobName(file: nil, link: "https://www.printables.com/de/model/3161-3d-benchy"), "3d benchy")
        XCTAssertEqual(Format.jobName(file: nil, link: "upload:abc"), "upload:abc")
        XCTAssertEqual(Format.jobName(file: nil, link: "https://www.thingiverse.com/thing:1"), "thingiverse.com/thing:1")
        XCTAssertEqual(Format.jobName(file: nil, link: nil), "–")
    }

    func testDuration() {
        XCTAssertEqual(Format.duration(nil), "–")
        XCTAssertEqual(Format.duration(-1), "–")
        XCTAssertEqual(Format.duration(125 * 60), "2 h 5 min")
        XCTAssertEqual(Format.duration(300), "5 min")
    }

    func testPrintTime() {
        XCTAssertEqual(Format.printTime("35m 32s"), "35 min")
        XCTAssertEqual(Format.printTime("1h 5m 3s"), "1 h 5 min")
        XCTAssertEqual(Format.printTime("1d 2h 3m"), "26 h 3 min")
        XCTAssertEqual(Format.printTime("soon"), "soon")
        XCTAssertEqual(Format.printTime(nil), "–")
    }

    func testCompactAndTemp() {
        XCTAssertEqual(Format.compact(999), "999")
        XCTAssertEqual(Format.compact(1500), "1.5k")
        XCTAssertEqual(Format.compact(12345), "12k")
        XCTAssertEqual(Format.compact(2_000_000), "2M")
        XCTAssertEqual(Format.compact(nil), "–")
        XCTAssertEqual(Format.temp(219.6, 220), "220 / 220 °C")
        XCTAssertEqual(Format.temp(25, 0), "25 °C")
        XCTAssertEqual(Format.temp(nil, nil), "–")
    }

    func testComboWarnings() {
        let l = L10n(lang: .en)
        XCTAssertEqual(Format.comboWarnings(l, filament: "Elegoo PLA @ECC", plate: "Engineering Plate"), [l(.warnPlatePla)])
        XCTAssertEqual(Format.comboWarnings(l, filament: "Elegoo PETG @ECC", plate: "High Temp Plate"), [l(.warnPlatePetg)])
        XCTAssertEqual(Format.comboWarnings(l, filament: "Elegoo PETG @ECC", plate: "Cool Plate"), [l(.warnCoolPlate)])
        XCTAssertEqual(Format.comboWarnings(l, filament: "Generic PA-CF", plate: "Textured PEI Plate"), [l(.warnCf)])
        XCTAssertTrue(Format.comboWarnings(l, filament: "Elegoo PLA @ECC", plate: "Textured PEI Plate").isEmpty)
    }

    func testAgoIsNotEmpty() {
        let now = Date()
        XCTAssertFalse(Format.ago(L10n(lang: .de), now.timeIntervalSince1970 - 7200, now: now).isEmpty)
        XCTAssertFalse(Format.ago(L10n(lang: .en), now.timeIntervalSince1970 - 30, now: now).isEmpty)
    }

    func testChangedValues() {
        let l = L10n(lang: .en)
        let out = JobView.changedValues(l, ["enable_support": "1", "support_type": "tree(auto)", "brim_type": "outer_only",
                                            "sparse_infill_density": "20%", "wall_loops": "3"])
        XCTAssertEqual(out, ["Supports: Tree", "Brim: Outer", "Infill: 20 %", "Walls: 3"])
        XCTAssertEqual(JobView.changedValues(l, ["enable_support": "0"]), ["Supports: Off"])
        XCTAssertTrue(JobView.changedValues(l, [:]).isEmpty)
    }
}
