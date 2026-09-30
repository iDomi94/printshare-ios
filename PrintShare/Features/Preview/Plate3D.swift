import SceneKit
import SwiftUI
import UIKit

/// Triangle mesh of the sliced plate for the 3D preview, built from the preview's paths (the app never parses G-code).
/// Every extrusion line becomes a small ridge (top edge at the layer height, sides one layer lower, open ends), one mesh
/// per layer so the layer slider can hide what lies above. Millimetres; SceneKit is Y-up, so x = X - bed/2, y = Z,
/// z = bed/2 - Y (the bed centre is the origin, the front of the bed faces +z).
struct PlateMesh: Sendable {
    struct Layer: Sendable {
        /// xyz per vertex.
        var positions: [Float] = []
        /// xyz per vertex, empty when drawn as lines.
        var normals: [Float] = []
        /// rgb 0...1 per vertex.
        var colors: [Float] = []
        /// Triangles, or line pairs when `PlateMesh.lines`.
        var indices: [UInt32] = []
    }

    /// Drawn line width in mm (the usual 0.4 mm nozzle).
    static let width: Float = 0.42
    /// Above this many segments the paths are drawn as thin lines instead of ridges, to keep memory in check.
    static let ridgeBudget = 300_000

    var layers: [Layer]
    var lines: Bool
    var bed: SIMD2<Float>
    /// Model extent in scene coordinates (without start code such as the purge line when the server reports `bounds`).
    var low: SIMD3<Float>
    var high: SIMD3<Float>
    var center: SIMD3<Float> { (low + high) / 2 }

    /// `colors` maps the line type (or, with `byTool`, the filament) to rgb 0...1; paths whose key is missing are hidden.
    static func build(_ p: Preview, colors: [Int: SIMD3<Float>], byTool: Bool, budget: Int = ridgeBudget) -> PlateMesh {
        let bed = (p.bed?.count ?? 0) >= 2 ? SIMD2(Float(p.bed![0]), Float(p.bed![1])) : SIMD2<Float>(256, 256)
        let half = bed / 2
        let unit = Float(p.unit > 0 ? p.unit : 10)
        let off = p.hasTools ? 2 : 1  // first coordinate in a path

        func key(_ raw: [Double]) -> Int {
            byTool ? (p.hasTools ? max(0, Int(raw[1])) : 0) : max(0, Int(raw[0]))
        }
        func points(_ raw: [Double]) -> [SIMD2<Float>] {
            var pts: [SIMD2<Float>] = []
            pts.reserveCapacity((raw.count - off) / 2)
            var i = off
            while i + 1 < raw.count {
                let q = SIMD2(Float(raw[i]) / unit - half.x, half.y - Float(raw[i + 1]) / unit)
                if pts.last != q { pts.append(q) }
                i += 2
            }
            return pts
        }

        // pass 1: extent of everything and the number of visible segments
        var lo = SIMD2<Float>(repeating: .infinity), hi = SIMD2<Float>(repeating: -.infinity)
        var top: Float = 0
        var segments = 0
        for l in p.layers {
            for raw in l.paths where raw.count >= off + 4 {
                var i = off
                while i + 1 < raw.count {
                    let q = SIMD2(Float(raw[i]) / unit - half.x, half.y - Float(raw[i + 1]) / unit)
                    lo = pointwiseMin(lo, q); hi = pointwiseMax(hi, q)
                    i += 2
                }
                top = max(top, Float(l.z))
                if colors[key(raw)] != nil { segments += (raw.count - off) / 2 - 1 }
            }
        }
        if let b = p.bounds, b.count >= 4, b[2] > b[0], b[3] > b[1] {
            lo = SIMD2(Float(b[0]) - half.x, half.y - Float(b[3]))
            hi = SIMD2(Float(b[2]) - half.x, half.y - Float(b[1]))
        }
        if !lo.x.isFinite { lo = -half; hi = half }
        let lines = segments > budget

        // pass 2: geometry per layer
        var layers: [Layer] = []
        layers.reserveCapacity(p.layers.count)
        var below: Float = 0
        for l in p.layers {
            let z = Float(l.z)
            let h = min(max(z - below, 0.05), 1)  // layer height; the first layer is its own height
            below = max(below, z)
            var layer = Layer()
            for raw in l.paths where raw.count >= off + 4 {
                guard let c = colors[key(raw)] else { continue }
                let pts = points(raw)
                guard pts.count >= 2 else { continue }
                if lines { line(pts, z, c, &layer) } else { ridge(pts, z, h, c, &layer) }
            }
            layers.append(layer)
        }
        return PlateMesh(layers: layers, lines: lines, bed: bed, low: SIMD3(lo.x, 0, lo.y), high: SIMD3(hi.x, top, hi.y))
    }

    private static func append(_ a: inout [Float], _ v: SIMD3<Float>) { a.append(v.x); a.append(v.y); a.append(v.z) }

    /// Left of a direction in the scene's xz plane.
    private static func left(_ d: SIMD2<Float>) -> SIMD2<Float> { SIMD2(d.y, -d.x) }

    /// Three vertices per point (left foot, top, right foot) with a mitred side direction, two sloped faces per segment.
    private static func ridge(_ pts: [SIMD2<Float>], _ z: Float, _ h: Float, _ c: SIMD3<Float>, _ out: inout Layer) {
        let base = UInt32(out.positions.count / 3)
        let halfWidth = width / 2
        for k in pts.indices {
            let dIn = k > 0 ? simd_normalize(pts[k] - pts[k - 1]) : nil
            let dOut = k + 1 < pts.count ? simd_normalize(pts[k + 1] - pts[k]) : nil
            var side = left(dIn ?? dOut!)
            var scale: Float = 1
            if let a = dIn, let b = dOut {
                let m = left(a) + left(b)
                let len = simd_length(m)
                // mitre join, capped so sharp turns don't spike; near reversals keep the incoming side
                if len > 0.2 {
                    side = m / len
                    scale = 1 / max(simd_dot(side, left(a)), 0.5)
                }
            }
            let q = pts[k], s = side * halfWidth * scale
            append(&out.positions, SIMD3(q.x + s.x, z - h, q.y + s.y))
            append(&out.positions, SIMD3(q.x, z, q.y))
            append(&out.positions, SIMD3(q.x - s.x, z - h, q.y - s.y))
            append(&out.normals, simd_normalize(SIMD3(side.x, 0.8, side.y)))
            append(&out.normals, SIMD3(0, 1, 0))
            append(&out.normals, simd_normalize(SIMD3(-side.x, 0.8, -side.y)))
            for _ in 0..<3 { append(&out.colors, c) }
        }
        for k in 0..<UInt32(pts.count - 1) {
            let l0 = base + 3 * k, t0 = l0 + 1, r0 = l0 + 2
            let l1 = l0 + 3, t1 = l0 + 4, r1 = l0 + 5
            out.indices += [l0, l1, t1, l0, t1, t0, t0, t1, r1, t0, r1, r0]
        }
    }

    private static func line(_ pts: [SIMD2<Float>], _ z: Float, _ c: SIMD3<Float>, _ out: inout Layer) {
        let base = UInt32(out.positions.count / 3)
        for q in pts {
            append(&out.positions, SIMD3(q.x, z, q.y))
            append(&out.colors, c)
        }
        for k in 0..<UInt32(pts.count - 1) { out.indices += [base + k, base + k + 1] }
    }
}

/// SceneKit scene of the sliced plate: bed with a 10 mm grid, one node per layer, camera and lights. The model centre
/// is the origin, so the camera orbits around the model. `setLayers` swaps the layers (colour mode, legend toggles)
/// and keeps the camera where the user left it.
@MainActor
final class PlateScene {
    let scene = SCNScene()
    let camera = SCNNode()
    private let content = SCNNode()
    private var layerNodes: [SCNNode] = []
    private var upTo = Int.max

    var layerCount: Int { layerNodes.count }

    init(_ mesh: PlateMesh) {
        scene.background.contents = UIColor(Theme.input)
        let center = mesh.center
        content.position = SCNVector3(-center.x, -center.y, -center.z)
        scene.rootNode.addChildNode(content)

        let bed = SCNBox(width: CGFloat(mesh.bed.x), height: 1, length: CGFloat(mesh.bed.y), chamferRadius: 0)
        bed.materials = [Self.flat(UIColor(Theme.track))]
        let bedNode = SCNNode(geometry: bed)
        bedNode.position = SCNVector3(0, -0.52, 0)  // top just below the first layer
        content.addChildNode(bedNode)
        if let grid = Self.grid(mesh.bed) {
            let gridNode = SCNNode(geometry: grid)
            gridNode.position = SCNVector3(0, -0.01, 0)
            content.addChildNode(gridNode)
        }

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        scene.rootNode.addChildNode(ambient)

        let cam = SCNCamera()
        cam.fieldOfView = 40
        cam.automaticallyAdjustsZRange = true
        camera.camera = cam
        let size = (mesh.high - mesh.low).max()
        let distance = max(size, 40) * 1.7
        camera.position = SCNVector3(distance * 0.45, distance * 0.6, distance)
        camera.look(at: SCNVector3(0, 0, 0))
        let head = SCNNode()  // light from the viewer, moves with the camera
        head.light = SCNLight()
        head.light?.type = .directional
        head.light?.intensity = 800
        camera.addChildNode(head)
        scene.rootNode.addChildNode(camera)

        setLayers(mesh)
    }

    func setLayers(_ mesh: PlateMesh) {
        layerNodes.forEach { $0.removeFromParentNode() }
        let material = SCNMaterial()
        material.diffuse.contents = UIColor.white  // multiplied with the vertex colours
        material.lightingModel = mesh.lines ? .constant : .blinn
        material.specular.contents = UIColor(white: 0.25, alpha: 1)
        material.isDoubleSided = true
        layerNodes = mesh.layers.map { layer in
            let node = SCNNode()
            if let g = Self.geometry(layer, lines: mesh.lines) {
                g.materials = [material]
                node.geometry = g
            }
            content.addChildNode(node)
            return node
        }
        show(upTo: upTo)
    }

    /// Hides the layers above `index` (0-based), like the layer slider of the 2D view.
    func show(upTo index: Int) {
        upTo = index
        for (i, node) in layerNodes.enumerated() where node.isHidden != (i > index) { node.isHidden = i > index }
    }

    func isShown(_ index: Int) -> Bool { index < layerNodes.count && !layerNodes[index].isHidden }

    private static func flat(_ color: UIColor) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .lambert
        return m
    }

    private static func data(_ a: [Float]) -> Data { a.withUnsafeBufferPointer { Data(buffer: $0) } }

    private static func source(_ a: [Float], _ semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
        SCNGeometrySource(data: data(a), semantic: semantic, vectorCount: a.count / 3, usesFloatComponents: true,
                          componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
    }

    static func geometry(_ l: PlateMesh.Layer, lines: Bool) -> SCNGeometry? {
        guard !l.indices.isEmpty else { return nil }
        var sources = [source(l.positions, .vertex), source(l.colors, .color)]
        if !l.normals.isEmpty { sources.append(source(l.normals, .normal)) }
        let indices = l.indices.withUnsafeBufferPointer { Data(buffer: $0) }
        let element = SCNGeometryElement(data: indices, primitiveType: lines ? .line : .triangles,
                                         primitiveCount: l.indices.count / (lines ? 2 : 3), bytesPerIndex: 4)
        return SCNGeometry(sources: sources, elements: [element])
    }

    /// 10 mm grid lines on the bed.
    private static func grid(_ bed: SIMD2<Float>) -> SCNGeometry? {
        var layer = PlateMesh.Layer()
        let half = bed / 2
        let line = SIMD3<Float>(0.55, 0.55, 0.6)
        func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>) {
            let base = UInt32(layer.positions.count / 3)
            layer.positions += [a.x, a.y, a.z, b.x, b.y, b.z]
            layer.colors += [line.x, line.y, line.z, line.x, line.y, line.z]
            layer.indices += [base, base + 1]
        }
        var x: Float = 0
        while x <= bed.x { add(SIMD3(x - half.x, 0, -half.y), SIMD3(x - half.x, 0, half.y)); x += 10 }
        var y: Float = 0
        while y <= bed.y { add(SIMD3(-half.x, 0, half.y - y), SIMD3(half.x, 0, half.y - y)); y += 10 }
        let g = geometry(layer, lines: true)
        let m = SCNMaterial()
        m.diffuse.contents = UIColor(Theme.line)
        m.lightingModel = .constant
        g?.materials = [m]
        return g
    }
}

/// SCNView for the plate: orbit around the model with the up axis kept (turntable), pinch to zoom, double tap resets.
struct PlateSceneView: UIViewRepresentable {
    let plate: PlateScene
    let upTo: Int

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = UIColor(Theme.input)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = SCNVector3(0, 0, 0)
        attach(view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        if view.scene !== plate.scene { attach(view) }
        plate.show(upTo: upTo)
    }

    private func attach(_ view: SCNView) {
        view.scene = plate.scene
        view.pointOfView = plate.camera
        plate.show(upTo: upTo)
    }
}
