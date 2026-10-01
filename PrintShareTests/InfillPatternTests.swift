import CoreGraphics
import XCTest
@testable import PrintShare

final class InfillPatternTests: XCTestCase {
    /// Real `/options` output of server 0.15.2 (Orca 2.4.2 Elegoo profiles; the CC preset's legacy zig-zag comes as rectilinear).
    func testOptionsWithInfillPatterns() throws {
        let o = try Fixture.decode(Options.self, "options_infill")
        XCTAssertEqual(o.infillPatterns?.count, 26)
        XCTAssertEqual(o.defaults.infillPattern, "rectilinear")
        XCTAssertEqual(o.defaults.infillLineWidth, 0.45)
        // older server: no list, no pattern -> no choice
        let old = try Fixture.decode(Options.self, "options")
        XCTAssertNil(old.infillPatterns)
        XCTAssertNil(old.defaults.infillPattern)
        XCTAssertEqual(InfillPattern.choices(server: old.infillPatterns, current: nil), [])
    }

    func testJobOptionsSendInfillPattern() throws {
        let data = try JSONEncoder().encode(JobOptions(infillPattern: "gyroid"))
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["infill_pattern"] as? String, "gyroid")
        let back = try JSONDecoder().decode(JobOptions.self, from: data)
        XCTAssertEqual(back.infillPattern, "gyroid")
    }

    func testChoices() {
        let all = ["rectilinear", "grid", "gyroid", "hilbertcurve", "lightning"]
        XCTAssertEqual(InfillPattern.choices(server: all, current: "rectilinear"), ["rectilinear", "grid", "gyroid", "lightning"])
        // the profile's own pattern stays choosable even if the app has no picture for it
        XCTAssertEqual(InfillPattern.choices(server: all, current: "hilbertcurve").first, "hilbertcurve")
        XCTAssertEqual(InfillPattern.layer("hilbertcurve", density: 0.2, lineWidth: 0.45, side: 30), .unsupported)
        XCTAssertEqual(InfillPattern.layer("lightning", density: 0.2, lineWidth: 0.45, side: 30), .unsupported)
    }

    /// The preview is to scale: line length × line width / area of the top layer ≈ the chosen density.
    func testDrawnDensityMatchesPercentage() {
        for pattern in InfillPattern.offered where InfillPattern.hasPreview(pattern) {
            for density in [0.1, 0.15, 0.3, 0.5] {
                guard case .lines(let top, _) = InfillPattern.layer(pattern, density: density, lineWidth: 0.45, side: 30)
                else { return XCTFail(pattern) }
                let drawn = InfillPattern.length(top, inside: 30) * 0.45 / 900
                XCTAssertEqual(drawn / density, 1, accuracy: 0.15, "\(pattern) \(density)")
            }
        }
    }

    func testEmptyAndSolid() {
        XCTAssertEqual(InfillPattern.layer("grid", density: 0, lineWidth: 0.45, side: 30), .empty)
        XCTAssertEqual(InfillPattern.layer("grid", density: 1, lineWidth: 0.45, side: 30), .solid)
    }

    func testGridSpacing() {
        // 20 % grid, 0.45 mm lines: each direction 4.5 mm apart (two directions share the density)
        guard case .lines(let top, let below) = InfillPattern.layer("grid", density: 0.2, lineWidth: 0.45, side: 30)
        else { return XCTFail() }
        XCTAssertTrue(below.isEmpty)
        let a = top[0], b = top[1]
        let dist = abs((b[0].x - a[0].x) * sin(.pi / 4) - (b[0].y - a[0].y) * cos(.pi / 4))
        XCTAssertEqual(Double(dist), 4.5, accuracy: 0.001)
    }

    func testPointsPerMillimetre() {
        // iPhone 14 Pro: 460 ppi, 3 px per point -> 153 pt per inch -> 3 cm ≈ 181 pt
        XCTAssertEqual(ScreenMetrics.pointsPerMM(model: "iPhone15,2", nativeScale: 3) * 30, 181.1, accuracy: 0.1)
        // Display Zoom (larger text): fewer pixels per point, more points per mm
        XCTAssertGreaterThan(ScreenMetrics.pointsPerMM(model: "iPhone15,2", nativeScale: 2.88),
                             ScreenMetrics.pointsPerMM(model: "iPhone15,2", nativeScale: 3))
        XCTAssertEqual(ScreenMetrics.ppi(model: "iPhone14,6"), 326)   // SE 3
        XCTAssertEqual(ScreenMetrics.ppi(model: "iPhone14,4"), 476)   // 13 mini
        XCTAssertEqual(ScreenMetrics.ppi(model: "iPad14,1"), 326)     // iPad mini 6
        XCTAssertEqual(ScreenMetrics.ppi(model: "iPad13,18"), 264)
        XCTAssertNil(ScreenMetrics.ppi(model: "arm64"))
    }
}
