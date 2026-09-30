import XCTest
@testable import PrintShare

/// Server 0.14.0: copies, tilt, size and lay flat per print. Shapes from the server's `docs/API.md`.
final class PlateTests: XCTestCase {
    private let de = L10n(lang: .de)

    private func json(_ o: JobOptions) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(o)) as? [String: Any])
    }

    func testDefaultsSendNothing() throws {
        var o = JobOptions(process: "q")
        PlateOptions.apply(copies: 1, tilt: .asModel, scale: 100, to: &o)
        let obj = try json(o)
        for key in ["copies", "rotate_x", "rotate_y", "scale", "orient"] { XCTAssertNil(obj[key], key) }
    }

    func testOptionsUseServerKeys() throws {
        var o = JobOptions()
        PlateOptions.apply(copies: 4, tilt: .forward, scale: 150, to: &o)
        var obj = try json(o)
        XCTAssertEqual(obj["copies"] as? Int, 4)
        XCTAssertEqual(obj["rotate_x"] as? Double, 90)
        XCTAssertNil(obj["rotate_y"])
        XCTAssertEqual(obj["scale"] as? Int, 150)
        XCTAssertNil(obj["orient"])

        PlateOptions.apply(copies: 99, tilt: .auto, scale: 100, to: &o)   // replaces the earlier choice
        obj = try json(o)
        XCTAssertEqual(obj["copies"] as? Int, PlateOptions.maxCopies)
        XCTAssertEqual(obj["orient"] as? Bool, true)
        XCTAssertNil(obj["rotate_x"])
        XCTAssertNil(obj["scale"])
    }

    func testTiltRoundTripsThroughOptions() throws {
        for tilt in PlateTilt.allCases {
            var o = JobOptions()
            PlateOptions.apply(copies: 1, tilt: tilt, scale: 100, to: &o)
            let back = try JSONDecoder().decode(JobOptions.self, from: JSONEncoder().encode(o))
            XCTAssertEqual(PlateTilt(options: back), tilt)
        }
        XCTAssertEqual(PlateTilt(options: JobOptions(rotateX: 45)), PlateTilt.asModel)   // not one of the choices
        XCTAssertEqual(PlateTilt(options: nil), PlateTilt.asModel)
    }

    func testSummary() {
        XCTAssertEqual(PlateOptions.summary(de, JobOptions()), "")
        let o = JobOptions(copies: 4, rotateY: -90, scale: 50)
        XCTAssertEqual(PlateOptions.summary(de, o), "4× · Nach links kippen · 50 %")
        XCTAssertEqual(PlateOptions.summary(de, o, placed: 3), "3× · Nach links kippen · 50 %")
        XCTAssertEqual(PlateOptions.summary(de, JobOptions(orient: true)), "Automatisch hinlegen")
    }

    func testJobResultCopies() throws {
        let new = try JSONDecoder().decode(JobResult.self, from: Data(#"""
        {"printer": "cc", "profiles": {}, "overrides": {}, "copies_requested": 30, "copies": 21}
        """#.utf8))
        XCTAssertTrue(new.knowsPlate)
        XCTAssertEqual(PlateOptions.fewerHint(de, new), "Nur 21 von 30 Kopien passen auf die Platte.")

        let one = try JSONDecoder().decode(JobResult.self, from: Data(#"""
        {"printer": "cc", "profiles": {}, "overrides": {}, "copies_requested": null, "copies": null}
        """#.utf8))
        XCTAssertTrue(one.knowsPlate)
        XCTAssertNil(PlateOptions.fewerHint(de, one))

        let old = try JSONDecoder().decode(JobResult.self, from: Data(#"{"printer": "cc"}"#.utf8))   // server < 0.14
        XCTAssertFalse(old.knowsPlate)
        XCTAssertNil(old.copies)
    }

    func testFewerCopiesLogLine() {
        XCTAssertEqual(de.translateLog("Only 21 of 30 copies fit on the plate"), "Nur 21 von 30 Kopien passen auf die Platte")
    }
}
