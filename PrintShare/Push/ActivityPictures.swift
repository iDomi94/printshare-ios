import ActivityKit
import Foundation
import Metal
import SceneKit
import SwiftUI
import UIKit

/// The pictures of the Live Activity and of the printer list (0.9.20): "printed up to layer X" rendered from the G-code
/// preview with the 3D view's mesh, and camera pictures on request. Everything lands in the App Group
/// (`ActivityImages`), where the widget reads it - Live Activity pushes carry no pictures.
@MainActor
enum ActivityPictures {
    /// Pixel size of a layer picture (shown at 52-76 pt).
    static let size = CGSize(width: 228, height: 228)
    /// Above this many segments the thumbnails are drawn as lines (memory, speed).
    static let budget = 120_000
    private static var inFlight: Set<String> = []

    /// Renders the job's layer pictures once (no-op when they exist, or when the job has no preview, e.g. a print
    /// started at the printer). Returns true when the pictures are there.
    @discardableResult
    static func prepare(job: String, api: APIClient) async -> Bool {
        if ActivityImages.hasFrames(job) { return true }
        guard let folder = ActivityImages.folder(job), let none = ActivityImages.noPreviewURL(job),
              !FileManager.default.fileExists(atPath: none.path), !inFlight.contains(job) else { return false }
        inFlight.insert(job)
        defer { inFlight.remove(job) }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let preview: Preview
        do {
            preview = try await api.preview(job: job)
        } catch let e as APIError where [400, 404, 409].contains(e.status) {
            FileManager.default.createFile(atPath: none.path, contents: Data())
            return false
        } catch {
            return false        // offline for now: the next start of the app tries again
        }
        guard !preview.layers.isEmpty else {
            FileManager.default.createFile(atPath: none.path, contents: Data())
            return false
        }
        let colors = colors(preview)
        let budget = self.budget
        let mesh = await Task.detached(priority: .utility) {
            PlateMesh.build(preview, colors: colors, byTool: true, budget: budget)
        }.value
        return await render(mesh, job: job)
    }

    /// Filament colours (the model as it will look); without them the app's accent orange.
    nonisolated static func colors(_ p: Preview) -> [Int: SIMD3<Float>] {
        var out: [Int: SIMD3<Float>] = [:]
        for k in 0..<16 {
            let hex = (k < p.filamentColors.count ? Color.hexValue(p.filamentColors[k]) : nil)
                ?? (k == 0 ? 0xFF8A3D : PreviewColors.fallbackHex(k))
            out[k] = PreviewColors.rgb(hex)
        }
        return out
    }

    /// Preview layer index shown by picture `n` (-1 = nothing printed yet).
    nonisolated static func upTo(frame n: Int, layers: Int) -> Int {
        Int((Double(n) * Double(layers) / Double(ActivityImages.frames)).rounded(.up)) - 1
    }

    private static func render(_ mesh: PlateMesh, job: String) async -> Bool {
        let plate = PlateScene(mesh, thumbnail: true)
        let renderer = SCNRenderer(device: MTLCreateSystemDefaultDevice(), options: nil)
        renderer.scene = plate.scene
        renderer.pointOfView = plate.camera
        let count = mesh.layers.count
        // the last picture is written last: `hasFrames` looks for it
        for n in 0...ActivityImages.frames {
            guard let url = ActivityImages.frameURL(job, n) else { return false }
            plate.show(upTo: upTo(frame: n, layers: count), ghost: true)
            let image = renderer.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
            guard let png = image.pngData(), (try? png.write(to: url, options: .atomic)) != nil else { return false }
            await Task.yield()
        }
        return true
    }

    // MARK: camera

    /// One camera picture for the job's Live Activity, then the activity is redrawn. Also called by the Live
    /// Activity's button, with the app started in the background (`RefreshCameraIntent`).
    nonisolated static func refreshCamera(job: String, printer: String, api: APIClient) async {
        guard let url = ActivityImages.cameraURL(job), let folder = ActivityImages.folder(job) else { return }
        guard let jpeg = try? await api.cameraSnapshot(printer: printer, width: 320), !jpeg.isEmpty else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? jpeg.write(to: url, options: .atomic)) != nil else { return }
        await redraw(job: job)
    }

    /// iOS draws a Live Activity again only on an update: the same state with a new stale date.
    nonisolated static func redraw(job: String) async {
        for a in Activity<PrintActivityAttributes>.activities where a.attributes.job == job {
            await a.update(ActivityContent(state: a.content.state, staleDate: Date().addingTimeInterval(30 * 60)))
        }
    }

    /// The button in the Live Activity: the app may run without a scene, so it builds its own client from the stored
    /// server (keychain item readable after the first unlock).
    nonisolated static func installIntentHook() {
        ActivityIntentHooks.refreshCamera = { job, printer in
            guard let server: Server = Keychain().getJSON(StoreKey.server), !server.url.isEmpty else { return }
            let api = APIClient(server: server, l10n: L10n(pref: .auto))
            await refreshCamera(job: job, printer: printer, api: api)
        }
    }

    // MARK: cleanup

    /// Pictures of jobs without a Live Activity that are older than a day (the printer list renders them again when
    /// needed).
    static func purge(keep: Set<String>) {
        guard let root = ActivityImages.root,
              let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return }
        for dir in items where !keep.contains(dir.lastPathComponent) {
            let at = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(at) > 24 * 3600 { try? FileManager.default.removeItem(at: dir) }
        }
    }
}
