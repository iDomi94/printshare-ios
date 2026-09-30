import SceneKit
import XCTest
@testable import PrintShare

final class ModelSceneTests: XCTestCase {
    func testWhichFilesHaveA3DView() {
        XCTAssertTrue(ModelScene.canShow("Benchy.STL"))
        XCTAssertTrue(ModelScene.canShow("part.obj"))
        XCTAssertFalse(ModelScene.canShow("plate.3mf"))
        XCTAssertFalse(ModelScene.canShow("bracket.step"))
    }

    @MainActor
    func testBuildsASceneFromAnAsciiStl() throws {
        let stl = """
        solid tri
        facet normal 0 0 1
          outer loop
            vertex 0 0 0
            vertex 20 0 0
            vertex 0 20 10
          endloop
        endfacet
        endsolid tri
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tri-\(UUID().uuidString).stl")
        try Data(stl.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let built = try ModelScene.make(url)
        XCTAssertNotNil(built.camera.camera)
        XCTAssertTrue(built.camera.parent === built.scene.rootNode)
        let (lo, hi) = built.scene.rootNode.childNodes[0].boundingBox
        XCTAssertEqual(Double(hi.x - lo.x), 20, accuracy: 0.01)
        XCTAssertEqual(Double(hi.y - lo.y), 10, accuracy: 0.01)  // Z-up height became Y
        XCTAssertEqual(Double(lo.x + hi.x), 0, accuracy: 0.01)   // centred
    }
}
