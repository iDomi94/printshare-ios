import ModelIO
import SceneKit
import SceneKit.ModelIO
import SwiftUI
import UIKit

/// Printable files of a model (tap "X printable files" on the model page): pick one, look at it in 3D, prepare it.
struct ModelFilesSheet: View {
    let link: String
    /// Called with the chosen file; the sheet is dismissed by the caller.
    var onPrepare: (ModelFile) -> Void

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var files: [ModelFile]?
    @State private var error = ""
    @State private var attempt = 0

    var body: some View {
        let t = app.l10n
        NavigationStack {
            Group {
                if let files {
                    PSScreen {
                        PSSection {
                            ForEach(Array(files.enumerated()), id: \.element.index) { i, f in
                                if i > 0 { PSDivider() }
                                NavigationLink(value: f) {
                                    PSRow(icon: ModelScene.canShow(f.name) ? "cube" : "doc", label: f.name,
                                          value: f.size.map(Format.mb), chevron: true)
                                }
                                .buttonStyle(RowPressStyle())
                            }
                        }
                    }
                } else if !error.isEmpty {
                    PSEmpty(icon: "icloud.slash", title: error) {
                        PSButton(title: t(.tryAgain), kind: .secondary) { attempt += 1 }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
                }
            }
            .navigationTitle(files.map { $0.count == 1 ? t(.printableFile) : t(.printableFiles, ["n": String($0.count)]) } ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(t(.close)) { dismiss() } } }
            .navigationDestination(for: ModelFile.self) { f in
                ModelFileView(link: link, file: f) { onPrepare(f) }
            }
            .task(id: attempt) { await load() }
        }
    }

    /// Same list and order as the prepare screen (`/api/files`), so the index means the same file there.
    private func load() async {
        guard let api = app.api else { return }
        error = ""
        do { files = try await api.files(link: link) } catch { self.error = error.localizedDescription }
    }
}

/// One model file in 3D (STL/OBJ via ModelIO + SceneKit), with "Prepare print" for exactly this file.
struct ModelFileView: View {
    let link: String
    let file: ModelFile
    var onPrepare: () -> Void

    @Environment(AppModel.self) private var app
    @State private var scene: SCNScene?
    @State private var camera: SCNNode?
    @State private var error = ""
    @State private var attempt = 0

    var body: some View {
        let t = app.l10n
        let ext = (file.name as NSString).pathExtension.uppercased()
        return PSScreen {
            ZStack {
                Theme.input
                if let scene, let camera {
                    SceneView(scene: scene, pointOfView: camera, options: [.allowsCameraControl, .autoenablesDefaultLighting])
                } else if !ModelScene.canShow(file.name) {
                    PSEmpty(icon: "cube.transparent", title: t(.model3dUnsupported, ["ext": ext]))
                } else if !error.isEmpty {
                    PSEmpty(icon: "exclamationmark.triangle", title: error) {
                        PSButton(title: t(.tryAgain), kind: .secondary) { attempt += 1 }
                    }
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .padding(.bottom, 10)
            if scene != nil {
                Text(t(.model3dHint)).font(.footnote).foregroundStyle(Theme.sub).frame(maxWidth: .infinity)
                    .padding(.bottom, 16)
            }
            PSSection {
                PSRow(icon: "doc", label: file.name, value: file.size.map(Format.mb))
            }
        } footer: {
            PSButton(title: t(.printThis), icon: "printer") { onPrepare() }
        }
        .navigationTitle(file.name)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: attempt) { await load() }
    }

    private func load() async {
        guard let api = app.api, ModelScene.canShow(file.name), scene == nil else { return }
        error = ""
        do {
            let url = try await api.downloadModelFile(link: link, file: String(file.index), name: file.name)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let built = try ModelScene.make(url)
            scene = built.scene
            camera = built.camera
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Builds a SceneKit scene from an STL/OBJ file: one neutral material, model centred, camera looking at it.
enum ModelScene {
    static func canShow(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return ["stl", "obj"].contains(ext) && MDLAsset.canImportFileExtension(ext)
    }

    @MainActor
    static func make(_ url: URL) throws -> (scene: SCNScene, camera: SCNNode) {
        let asset = MDLAsset(url: url)
        let meshes = asset.childObjects(of: MDLMesh.self).compactMap { $0 as? MDLMesh }
        guard !meshes.isEmpty else { throw CocoaError(.fileReadCorruptFile) }

        let material = SCNMaterial()
        material.diffuse.contents = UIColor(Theme.accent)
        material.lightingModel = .blinn
        material.isDoubleSided = true
        let model = SCNNode()
        for mesh in meshes {
            mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.6)
            let node = SCNNode(mdlObject: mesh)
            node.geometry?.materials = [material]
            model.addChildNode(node)
        }
        model.eulerAngles.x = -.pi / 2  // slicer files are Z-up, SceneKit is Y-up

        let holder = SCNNode()
        holder.addChildNode(model)
        let (lo, hi) = holder.boundingBox
        model.position = SCNVector3(-(lo.x + hi.x) / 2, -(lo.y + hi.y) / 2, -(lo.z + hi.z) / 2)
        let size = max(hi.x - lo.x, hi.y - lo.y, hi.z - lo.z, 1)

        let scene = SCNScene()
        scene.background.contents = UIColor(Theme.input)
        scene.rootNode.addChildNode(holder)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 350
        scene.rootNode.addChildNode(ambient)

        let cam = SCNCamera()
        cam.fieldOfView = 40
        cam.automaticallyAdjustsZRange = true
        let camera = SCNNode()
        camera.camera = cam
        let distance = Float(size) * 1.6
        camera.position = SCNVector3(distance * 0.55, distance * 0.6, distance)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)
        return (scene, camera)
    }
}
