import SceneKit
import SwiftUI
import XCTest
@testable import PrintShare

/// 3D view of the sliced plate: mesh from the preview paths, and the SceneKit scene built from it.
final class PlateMeshTests: XCTestCase {
    private let red = SIMD3<Float>(1, 0, 0)
    private let blue = SIMD3<Float>(0, 0, 1)

    /// Two layers on a 200×100 bed, unit 10: an L-shaped perimeter (type 0, tool 1) and a straight infill line (type 1, tool 0).
    private func preview(bounds: [Double]? = nil) -> Preview {
        Preview(version: 2, unit: 10, types: ["Outer wall", "Sparse infill"], bounds: bounds, bed: [200, 100], layers: [
            .init(z: 0.2, paths: [[0, 1, 1000, 500, 1200, 500, 1200, 700], [1, 0, 1000, 600, 1100, 600]]),
            .init(z: 0.4, paths: [[0, 1, 1000, 500, 1200, 500]]),
        ], filamentColors: ["#FF0000", "#0000FF"])
    }

    private func vertex(_ l: PlateMesh.Layer, _ i: Int) -> SIMD3<Float> {
        SIMD3(l.positions[3 * i], l.positions[3 * i + 1], l.positions[3 * i + 2])
    }

    func testRidgesPerPathInSceneCoordinates() {
        let mesh = PlateMesh.build(preview(), colors: [0: red, 1: blue], byTool: false)
        XCTAssertFalse(mesh.lines)
        XCTAssertEqual(mesh.layers.count, 2)
        let first = mesh.layers[0]
        // 3 + 2 points → 3 vertices each; 2 + 1 segments → 4 triangles each
        XCTAssertEqual(first.positions.count, 5 * 3 * 3)
        XCTAssertEqual(first.normals.count, first.positions.count)
        XCTAssertEqual(first.colors.count, first.positions.count)
        XCTAssertEqual(first.indices.count, 3 * 12)
        XCTAssertLessThan(first.indices.max()!, UInt32(first.positions.count / 3))
        // top of the first point: X 100 → x 0 (bed centre), Y 50 → z 0, y = layer height
        let top = vertex(first, 1)
        XCTAssertEqual(top.x, 0, accuracy: 1e-5)
        XCTAssertEqual(top.y, 0.2, accuracy: 1e-5)
        XCTAssertEqual(top.z, 0, accuracy: 1e-5)
        // feet one layer lower, half a line width to each side of a line running along +x
        let left = vertex(first, 0), right = vertex(first, 2)
        XCTAssertEqual(left.y, 0, accuracy: 1e-5)
        XCTAssertEqual(abs(left.z - right.z), PlateMesh.width, accuracy: 1e-4)
        XCTAssertEqual(left.x, 0, accuracy: 1e-5)
        // Y grows towards the back of the bed = -z in SceneKit
        let corner = vertex(first, 3 * 2 + 1)  // X 120, Y 70
        XCTAssertEqual(corner.x, 20, accuracy: 1e-5)
        XCTAssertEqual(corner.z, -20, accuracy: 1e-5)
        // colours per line type
        XCTAssertEqual(Array(first.colors[0..<3]), [1, 0, 0])
        XCTAssertEqual(Array(first.colors[first.colors.count - 3..<first.colors.count]), [0, 0, 1])
        // the second layer sits on the first one: feet at 0.2
        XCTAssertEqual(vertex(mesh.layers[1], 0).y, 0.2, accuracy: 1e-5)
        XCTAssertEqual(vertex(mesh.layers[1], 1).y, 0.4, accuracy: 1e-5)
    }

    func testMitredCornerKeepsTheLineWidth() {
        let mesh = PlateMesh.build(preview(), colors: [0: red], byTool: false)
        // the corner of the L (point 2 of the first path): feet on the diagonal, √2 × half width from the top
        let l = mesh.layers[0]
        let top = vertex(l, 4), foot = vertex(l, 3)
        let d = SIMD2(foot.x - top.x, foot.z - top.z)
        XCTAssertEqual(simd_length(d), PlateMesh.width / 2 * 2.squareRoot(), accuracy: 1e-4)
        XCTAssertEqual(abs(d.x), abs(d.y), accuracy: 1e-4)
    }

    func testHiddenKeysAndColourByFilament() {
        let byType = PlateMesh.build(preview(), colors: [1: blue], byTool: false)
        XCTAssertEqual(byType.layers[0].indices.count, 12)  // only the infill line
        XCTAssertTrue(byType.layers[1].indices.isEmpty)
        let byTool = PlateMesh.build(preview(), colors: [1: red], byTool: true)
        XCTAssertEqual(byTool.layers[0].indices.count, 2 * 12)  // the perimeter is filament 2 (tool 1)
        XCTAssertEqual(byTool.layers[1].indices.count, 12)
    }

    func testExtentUsesTheServerBoundsAndLayerTop() {
        let mesh = PlateMesh.build(preview(bounds: [100, 50, 120, 70]), colors: [0: red], byTool: false)
        XCTAssertEqual(mesh.low, SIMD3(0, 0, -20))
        XCTAssertEqual(mesh.high, SIMD3(20, 0.4, 0))
        XCTAssertEqual(mesh.bed, SIMD2(200, 100))
        // without bounds: every path, hidden ones too, so the camera doesn't jump when toggling the legend
        let all = PlateMesh.build(preview(), colors: [:], byTool: false)
        XCTAssertEqual(all.low.x, 0, accuracy: 1e-5)
        XCTAssertEqual(all.high.x, 20, accuracy: 1e-5)
    }

    func testLinesAboveTheBudget() {
        let mesh = PlateMesh.build(preview(), colors: [0: red, 1: blue], byTool: false, budget: 3)
        XCTAssertTrue(mesh.lines)
        let first = mesh.layers[0]
        XCTAssertEqual(first.positions.count, 5 * 3)
        XCTAssertTrue(first.normals.isEmpty)
        XCTAssertEqual(first.indices, [0, 1, 1, 2, 3, 4])
    }

    func testFormatOneAndMissingBed() {
        let p = Preview(version: 1, unit: 10, types: ["Outer wall"], layers: [.init(z: 0.3, paths: [[0, 0, 0, 100, 0]])])
        let mesh = PlateMesh.build(p, colors: [0: red], byTool: true)  // format 1: every path is filament 1 (key 0)
        XCTAssertEqual(mesh.bed, SIMD2(256, 256))
        XCTAssertEqual(mesh.layers[0].indices.count, 12)
        XCTAssertEqual(vertex(mesh.layers[0], 1).x, -128, accuracy: 1e-5)
        XCTAssertEqual(vertex(mesh.layers[0], 1).z, 128, accuracy: 1e-5)
    }

    @MainActor
    func testSceneHidesTheLayersAboveTheSlider() {
        let plate = PlateScene(PlateMesh.build(preview(), colors: [0: red, 1: blue], byTool: false))
        XCTAssertEqual(plate.layerCount, 2)
        XCTAssertNotNil(plate.camera.camera)
        XCTAssertTrue(plate.camera.parent === plate.scene.rootNode)
        plate.show(upTo: 0)
        XCTAssertTrue(plate.isShown(0))
        XCTAssertFalse(plate.isShown(1))
        // a rebuild (other colours) keeps the slider position
        plate.setLayers(PlateMesh.build(preview(), colors: [1: blue], byTool: false))
        XCTAssertEqual(plate.layerCount, 2)
        XCTAssertFalse(plate.isShown(1))
        plate.show(upTo: 1)
        XCTAssertTrue(plate.isShown(1))
    }

    @MainActor
    func testGeometryFromALayer() {
        let mesh = PlateMesh.build(preview(), colors: [0: red, 1: blue], byTool: false)
        let g = PlateScene.geometry(mesh.layers[0], lines: false)
        XCTAssertEqual(g?.sources(for: .vertex).first?.vectorCount, 15)
        XCTAssertEqual(g?.sources(for: .color).count, 1)
        XCTAssertEqual(g?.elements.first?.primitiveCount, 12)
        XCTAssertNil(PlateScene.geometry(PlateMesh.Layer(), lines: false))
    }

    func testPreviewColoursAsRgb() {
        XCTAssertEqual(PreviewColors.rgb(0xFF8000), SIMD3(1, 128.0 / 255, 0))
        XCTAssertEqual(PreviewColors.hex(name: "Outer wall", index: 5), 0xFF8A3D)
        XCTAssertEqual(PreviewColors.hex(name: "whatever", index: 9), PreviewColors.fallbackHex(1))
        XCTAssertEqual(Color.hexValue("#A18787"), 0xA18787)
        XCTAssertNil(Color.hexValue("red"))
    }
}
