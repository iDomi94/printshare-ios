import SwiftUI

/// One layer of the preview, ready to draw: paths grouped by line type and by filament, in millimetres (y up).
private struct PreviewLayer {
    var z: Double
    var byType: [Int: Path]
    var byTool: [Int: Path]
}

private struct PreviewScene {
    var layers: [PreviewLayer]
    var typeCount: Int
    /// Filaments (tools) used anywhere in the print, ascending. Empty for format 1.
    var tools: [Int]
    var minX: Double, minY: Double, maxX: Double, maxY: Double
    var bed: (w: Double, h: Double)
}

/// Top switch: 2D around the model, 2D whole bed, or the sliced plate in 3D.
private enum ViewMode: Hashable { case model, bed, threeD }
/// Colour the lines by line type or by filament; filament only makes sense with more than one.
private enum ColorMode: Hashable { case type, color }

/// G-code preview (SL-06/07): layer slider, colours per line type or filament, legend toggles; 2D around the model or
/// the whole bed, or the sliced plate in 3D (rotatable).
struct PreviewView: View {
    let id: String

    @Environment(AppModel.self) private var app
    @State private var preview: Preview?
    @State private var scene: PreviewScene?
    @State private var loaded = false
    @State private var error = ""
    @State private var layer = 0
    @State private var hidden: Set<String> = []  // "type:3" / "color:1"
    @State private var mode: ViewMode = .model
    @State private var colorPref: ColorMode?
    @State private var plate: PlateScene?
    @State private var plateBuilt: PlateKey?

    var body: some View {
        let t = app.l10n
        Group {
            if let scene, let preview {
                viewer(t, scene, preview)
            } else if !error.isEmpty {
                PSEmpty(icon: "icloud.slash", title: error) {
                    PSButton(title: t(.tryAgain), kind: .secondary) { Task { await load() } }
                }
                .frame(maxHeight: .infinity).background(Theme.bg)
            } else if loaded {
                PSEmpty(icon: "square.3.layers.3d", title: t(.previewEmpty))
                    .frame(maxHeight: .infinity).background(Theme.bg)
            } else {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            }
        }
        .navigationTitle(t(.previewTitle))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func colorMode(_ scene: PreviewScene) -> ColorMode {
        colorPref ?? (scene.tools.count > 1 ? .color : .type)
    }

    // MARK: viewer

    private func viewer(_ t: L10n, _ scene: PreviewScene, _ preview: Preview) -> some View {
        let last = max(scene.layers.count - 1, 0)
        let current = min(layer, last)
        let cmode = colorMode(scene)
        return ScrollView {
            VStack(spacing: 12) {
                Picker("", selection: $mode) {
                    Text(t(.fitModel)).tag(ViewMode.model)
                    Text(t(.wholePlate)).tag(ViewMode.bed)
                    Text(t(.view3d)).tag(ViewMode.threeD)
                }
                .pickerStyle(.segmented).labelsHidden()
                if scene.tools.count > 1 {
                    Picker(t(.colorMode), selection: Binding(get: { cmode }, set: { colorPref = $0 })) {
                        Text(t(.byColor)).tag(ColorMode.color)
                        Text(t(.byLineType)).tag(ColorMode.type)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                }

                Group {
                    if mode == .threeD {
                        plateView(t, current)
                    } else {
                        canvas(scene, preview, current, cmode)
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 640)
                .background(mode == .threeD ? Theme.input : Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .accessibilityHidden(true)
                if mode == .threeD && plate != nil {
                    Text(t(.preview3dHint)).font(.footnote).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
                }

                VStack(spacing: 4) {
                    HStack {
                        Text(t(.layerOf, ["n": String(current + 1), "total": String(scene.layers.count)]))
                            .font(.headline).foregroundStyle(Theme.text)
                        Spacer()
                        Text(t(.zHeight, ["z": String(format: "%.2f", scene.layers.isEmpty ? 0 : scene.layers[current].z)]))
                            .font(.subheadline).foregroundStyle(Theme.sub)
                    }
                    HStack(spacing: 12) {
                        stepButton("minus", t(.prevLayer), disabled: current <= 0) { layer = max(0, current - 1) }
                        Slider(value: Binding(get: { Double(current) }, set: { layer = Int($0.rounded()) }),
                               in: 0...Double(max(last, 1)), step: 1)
                            .disabled(last == 0)
                            .accessibilityLabel(t(.layerOf, ["n": String(current + 1), "total": String(scene.layers.count)]))
                        stepButton("plus", t(.nextLayer), disabled: current >= last) { layer = min(last, current + 1) }
                    }
                }
                legend(t, scene, preview, current, cmode)
            }
            .padding(Theme.space)
            .frame(maxWidth: .infinity)
        }
        // dragging in the 3D view rotates the plate instead of scrolling the page
        .scrollDisabled(mode == .threeD)
        .background(Theme.bg)
        .task(id: PlateKey(on: mode == .threeD, color: cmode == .color, hidden: hidden)) {
            await buildPlate(scene, preview, cmode, PlateKey(on: true, color: cmode == .color, hidden: hidden))
        }
    }

    // MARK: 3D

    private struct PlateKey: Hashable {
        var on: Bool
        var color: Bool
        var hidden: Set<String>
    }

    @ViewBuilder
    private func plateView(_ t: L10n, _ current: Int) -> some View {
        if let plate {
            PlateSceneView(plate: plate, upTo: current)
        } else {
            ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Builds (or, after a colour change or legend toggle, rebuilds) the 3D plate off the main thread; the scene and its
    /// camera are kept, so the view stays where the user turned it.
    private func buildPlate(_ scene: PreviewScene, _ preview: Preview, _ cmode: ColorMode, _ key: PlateKey) async {
        guard mode == .threeD, plateBuilt != key else { return }
        let keys: [Int] = cmode == .color ? scene.tools : Array(0..<scene.typeCount)
        var visible: [Int: SIMD3<Float>] = [:]
        for k in keys where !hidden.contains(Self.hiddenKey(cmode, k)) {
            visible[k] = PreviewColors.rgb(Self.hex(preview, cmode, k))
        }
        let colors = visible
        let byTool = cmode == .color
        let mesh = await Task.detached(priority: .userInitiated) {
            PlateMesh.build(preview, colors: colors, byTool: byTool)
        }.value
        guard !Task.isCancelled else { return }
        if let plate { plate.setLayers(mesh) } else { plate = PlateScene(mesh) }
        plateBuilt = key
    }

    private func stepButton(_ symbol: String, _ label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                .frame(width: 44, height: 40).background(Theme.track)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.35 : 1).accessibilityLabel(label)
    }

    private func legend(_ t: L10n, _ scene: PreviewScene, _ preview: Preview, _ current: Int,
                        _ cmode: ColorMode) -> some View {
        let keys: [Int] = cmode == .color ? scene.tools : Array(0..<scene.typeCount)
        let layerPaths: [Int: Path] = scene.layers.isEmpty ? [:] : (cmode == .color ? scene.layers[current].byTool : scene.layers[current].byType)
        return VStack(alignment: .leading, spacing: 8) {
            Text(t(cmode == .color ? .colors : .lineTypes)).textCase(.uppercase).font(.footnote).foregroundStyle(Theme.sub)
            FlowLayout(spacing: 8) {
                ForEach(keys, id: \.self) { k in
                    let key = Self.hiddenKey(cmode, k)
                    let on = !hidden.contains(key)
                    let here = layerPaths[k] != nil
                    let label = cmode == .color ? t(.colorN, ["n": String(k + 1)]) : t.lineType(typeName(preview, k))
                    Button {
                        Haptics.tap()
                        if on { hidden.insert(key) } else { hidden.remove(key) }
                    } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3).fill(Self.color(preview, cmode, k))
                                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Theme.line, lineWidth: 1))
                                .frame(width: 12, height: 12)
                            Text(label).font(.footnote).foregroundStyle(Theme.text).strikethrough(!on)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.card).clipShape(Capsule())
                        .opacity(on ? (here ? 1 : 0.65) : 0.4)
                    }
                    .buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .frame(maxWidth: 640, alignment: .leading)
    }

    private func typeName(_ preview: Preview, _ i: Int) -> String {
        i < preview.types.count ? preview.types[i] : "Type \(i + 1)"
    }

    nonisolated private static func hiddenKey(_ mode: ColorMode, _ k: Int) -> String { mode == .color ? "color:\(k)" : "type:\(k)" }

    nonisolated private static func color(_ preview: Preview, _ mode: ColorMode, _ k: Int) -> Color {
        Color(hex: hex(preview, mode, k))
    }

    nonisolated private static func hex(_ preview: Preview, _ mode: ColorMode, _ k: Int) -> UInt32 {
        if mode == .color {
            return (k < preview.filamentColors.count ? Color.hexValue(preview.filamentColors[k]) : nil)
                ?? PreviewColors.fallbackHex(k)
        }
        return PreviewColors.hex(name: k < preview.types.count ? preview.types[k] : "", index: k)
    }

    // MARK: drawing

    private func canvas(_ scene: PreviewScene, _ preview: Preview, _ current: Int, _ cmode: ColorMode) -> some View {
        let hiddenKeys = hidden
        let mode = self.mode
        let line = Theme.line
        let text = Theme.text
        let sub = Theme.sub
        return Canvas { ctx, size in
            let view = PreviewView.viewport(scene, mode)
            let w = view.maxX - view.minX, h = view.maxY - view.minY
            guard w > 0, h > 0 else { return }
            let s = min(size.width / w, size.height / h)
            let ox = (size.width - w * s) / 2, oy = (size.height - h * s) / 2
            let transform = CGAffineTransform(a: s, b: 0, c: 0, d: -s, tx: ox - s * view.minX, ty: oy + s * view.maxY)

            // 10 mm grid
            var grid = Path()
            var gx = (view.minX / 10).rounded(.up) * 10
            while gx <= view.maxX {
                grid.move(to: CGPoint(x: gx, y: view.minY)); grid.addLine(to: CGPoint(x: gx, y: view.maxY)); gx += 10
            }
            var gy = (view.minY / 10).rounded(.up) * 10
            while gy <= view.maxY {
                grid.move(to: CGPoint(x: view.minX, y: gy)); grid.addLine(to: CGPoint(x: view.maxX, y: gy)); gy += 10
            }
            ctx.stroke(grid.applying(transform), with: .color(line.opacity(0.7)), lineWidth: 0.5)

            let bed = Path(CGRect(x: 0, y: 0, width: scene.bed.w, height: scene.bed.h)).applying(transform)
            ctx.stroke(bed, with: .color(line), lineWidth: 1.5)

            let width = max(1, 0.4 * s)
            let style = StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            func groups(_ index: Int) -> [Int: Path] {
                guard index >= 0, index < scene.layers.count else { return [:] }
                return cmode == .color ? scene.layers[index].byTool : scene.layers[index].byType
            }
            // the layer below, faded
            for (_, path) in groups(current - 1) {
                ctx.stroke(path.applying(transform), with: .color(sub.opacity(0.25)), style: style)
            }
            let visible = groups(current).filter { !hiddenKeys.contains(PreviewView.hiddenKey(cmode, $0.key)) }
            if cmode == .color {
                // thin dark outline, so white or very light filament stays visible on the plate
                for (_, path) in visible {
                    ctx.stroke(path.applying(transform), with: .color(text.opacity(0.45)),
                               style: StrokeStyle(lineWidth: width * 1.7, lineCap: .round, lineJoin: .round))
                }
            }
            for (k, path) in visible {
                ctx.stroke(path.applying(transform), with: .color(PreviewView.color(preview, cmode, k)), style: style)
            }
        }
    }

    /// Visible window in mm: a square around the model (6 % margin, at least 4 mm) or the whole bed.
    nonisolated private static func viewport(_ scene: PreviewScene, _ mode: ViewMode) -> (minX: Double, minY: Double, maxX: Double, maxY: Double) {
        if mode == .bed { return (0, 0, scene.bed.w, scene.bed.h) }
        let w = scene.maxX - scene.minX, h = scene.maxY - scene.minY
        let side = max(w, h, 1)
        let margin = max(side * 0.06, 4)
        let cx = (scene.minX + scene.maxX) / 2, cy = (scene.minY + scene.maxY) / 2
        let half = side / 2 + margin
        return (cx - half, cy - half, cx + half, cy + half)
    }

    // MARK: loading

    private func load() async {
        guard let api = app.api else { return }
        error = ""
        do {
            let p = try await api.preview(job: id)
            let built = await Self.buildScene(p)
            preview = p
            scene = built
            layer = max(0, (built?.layers.count ?? 1) - 1)  // the finished part first, like the Expo app
            loaded = true
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Convert every layer's paths once, so dragging the slider only draws cached paths.
    private static func buildScene(_ p: Preview) async -> PreviewScene? {
        var layers: [PreviewLayer] = []
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        var typeCount = p.types.count
        var tools = Set<Int>()
        let off = p.hasTools ? 2 : 1  // first coordinate in a path
        for (n, l) in p.layers.enumerated() {
            var byType: [Int: Path] = [:]
            var byTool: [Int: Path] = [:]
            for raw in l.paths where raw.count >= off + 4 {
                let type = max(0, Int(raw[0]))
                let tool = p.hasTools ? max(0, Int(raw[1])) : 0
                typeCount = max(typeCount, type + 1)
                if p.hasTools { tools.insert(tool) }
                var path = Path()
                var i = off
                while i + 1 < raw.count {
                    let pt = CGPoint(x: raw[i] / p.unit, y: raw[i + 1] / p.unit)
                    minX = min(minX, pt.x); maxX = max(maxX, pt.x); minY = min(minY, pt.y); maxY = max(maxY, pt.y)
                    if i == off { path.move(to: pt) } else { path.addLine(to: pt) }
                    i += 2
                }
                byType[type, default: Path()].addPath(path)
                byTool[tool, default: Path()].addPath(path)
            }
            layers.append(PreviewLayer(z: l.z, byType: byType, byTool: byTool))
            if n % 20 == 19 { await Task.yield() }
        }
        guard !layers.isEmpty, minX.isFinite else { return nil }
        // the server's bounds leave out start/end code such as the purge line at the edge of the plate
        if let b = p.bounds, b[2] > b[0], b[3] > b[1] { (minX, minY, maxX, maxY) = (b[0], b[1], b[2], b[3]) }
        let bed = (p.bed?.count ?? 0) >= 2 ? (w: p.bed![0], h: p.bed![1]) : (w: 256.0, h: 256.0)
        return PreviewScene(layers: layers, typeCount: typeCount, tools: tools.sorted(), minX: minX, minY: minY,
                            maxX: maxX, maxY: maxY, bed: bed)
    }
}

/// Colours per G-code line type (Orca's feature names), with a fallback palette for unknown names.
enum PreviewColors {
    private static let palette: [UInt32] = [0xE4572E, 0xF3A712, 0x29B6F6, 0x66BB6A, 0xAB47BC, 0x26A69A, 0xFF7043, 0x8D6E63]

    static func color(name: String, index: Int) -> Color { Color(hex: hex(name: name, index: index)) }

    static func fallback(_ index: Int) -> Color { Color(hex: fallbackHex(index)) }

    static func hex(name: String, index: Int) -> UInt32 {
        let n = name.lowercased()
        if n.contains("outer") { return 0xFF8A3D }
        if n.contains("inner") { return 0xFFD54F }
        if n.contains("overhang") { return 0x3F51B5 }
        if n.contains("sparse") { return 0xE53935 }
        if n.contains("solid") { return 0xAB47BC }
        if n.contains("top") { return 0xEF5350 }
        if n.contains("bottom") { return 0x1E88E5 }
        if n.contains("bridge") { return 0x4DB6AC }
        if n.contains("gap") { return 0xFFFFFF }
        if n.contains("support") { return 0x66BB6A }
        if n.contains("skirt") || n.contains("brim") { return 0x00ACC1 }
        return fallbackHex(index)
    }

    static func fallbackHex(_ index: Int) -> UInt32 { palette[abs(index) % palette.count] }

    /// rgb 0...1 for the 3D view's vertex colours.
    static func rgb(_ hex: UInt32) -> SIMD3<Float> {
        SIMD3(Float((hex >> 16) & 0xFF), Float((hex >> 8) & 0xFF), Float(hex & 0xFF)) / 255
    }
}
