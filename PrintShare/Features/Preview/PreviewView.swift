import SwiftUI

/// One layer of the preview, ready to draw: a path per line type, in millimetres (y up).
private struct PreviewLayer {
    var z: Double
    var paths: [Int: Path]
}

private struct PreviewScene {
    var layers: [PreviewLayer]
    var typeCount: Int
    var minX: Double, minY: Double, maxX: Double, maxY: Double
    var bed: (w: Double, h: Double)
}

private enum ViewMode: Hashable { case model, bed }

/// 2D G-code preview: layer slider, colours per line type, types on/off, model or whole bed.
struct PreviewView: View {
    let id: String

    @Environment(AppModel.self) private var app
    @State private var preview: Preview?
    @State private var scene: PreviewScene?
    @State private var error = ""
    @State private var layer = 0
    @State private var hidden: Set<Int> = []
    @State private var mode: ViewMode = .model

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
            } else {
                ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            }
        }
        .navigationTitle(t(.preview))
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    // MARK: viewer

    private func viewer(_ t: L10n, _ scene: PreviewScene, _ preview: Preview) -> some View {
        let last = max(scene.layers.count - 1, 0)
        let current = min(layer, last)
        return VStack(spacing: 12) {
            Picker("", selection: $mode) {
                Text(t(.viewModel)).tag(ViewMode.model)
                Text(t(.viewBed)).tag(ViewMode.bed)
            }
            .pickerStyle(.segmented).labelsHidden()

            canvas(scene, current)
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: 640)
                .background(Theme.card)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .accessibilityHidden(true)

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
                        .accessibilityLabel(t(.layer))
                    stepButton("plus", t(.nextLayer), disabled: current >= last) { layer = min(last, current + 1) }
                }
            }
            legend(t, scene, preview)
            Spacer(minLength: 0)
        }
        .padding(Theme.space)
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
    }

    private func stepButton(_ symbol: String, _ label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button { Haptics.tap(); action() } label: {
            Image(systemName: symbol).font(.body.weight(.semibold)).foregroundStyle(Theme.text)
                .frame(width: 44, height: 40).background(Theme.track)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.35 : 1).accessibilityLabel(label)
    }

    private func legend(_ t: L10n, _ scene: PreviewScene, _ preview: Preview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(t(.lineTypes)).textCase(.uppercase).font(.footnote).foregroundStyle(Theme.sub)
            FlowLayout(spacing: 8) {
                ForEach(0..<scene.typeCount, id: \.self) { i in
                    let on = !hidden.contains(i)
                    let color = PreviewColors.color(name: typeName(preview, i), index: i)
                    Button {
                        Haptics.tap()
                        if on { hidden.insert(i) } else { hidden.remove(i) }
                    } label: {
                        HStack(spacing: 6) {
                            Circle().fill(color).frame(width: 10, height: 10).opacity(on ? 1 : 0.3)
                            Text(typeName(preview, i)).font(.footnote).foregroundStyle(on ? Theme.text : Theme.sub)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Theme.card).clipShape(Capsule())
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

    // MARK: drawing

    private func canvas(_ scene: PreviewScene, _ current: Int) -> some View {
        let hiddenTypes = hidden
        let types = preview?.types ?? []
        let mode = self.mode
        let dark = Theme.line
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
            ctx.stroke(grid.applying(transform), with: .color(dark.opacity(0.7)), lineWidth: 0.5)

            if mode == .bed {
                let bed = Path(CGRect(x: 0, y: 0, width: scene.bed.w, height: scene.bed.h)).applying(transform)
                ctx.stroke(bed, with: .color(dark), lineWidth: 1.5)
            }

            func draw(_ index: Int, opacity: Double) {
                guard index >= 0, index < scene.layers.count else { return }
                for (type, path) in scene.layers[index].paths where !hiddenTypes.contains(type) {
                    let name = type < types.count ? types[type] : ""
                    ctx.stroke(path.applying(transform), with: .color(PreviewColors.color(name: name, index: type).opacity(opacity)),
                               style: StrokeStyle(lineWidth: max(1, 0.4 * s), lineCap: .round, lineJoin: .round))
                }
            }
            draw(current - 1, opacity: 0.25)  // the layer below, faded
            draw(current, opacity: 1)
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
            preview = p
            scene = await Self.buildScene(p)
            layer = 0
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Convert every layer's paths once, so dragging the slider only draws cached paths.
    private static func buildScene(_ p: Preview) async -> PreviewScene? {
        var layers: [PreviewLayer] = []
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        var typeCount = p.types.count
        for (n, l) in p.layers.enumerated() {
            var paths: [Int: Path] = [:]
            for raw in l.paths where raw.count >= 5 {
                let type = max(0, Int(raw[0]))
                typeCount = max(typeCount, type + 1)
                var path = paths[type] ?? Path()
                var i = 1
                var first = true
                while i + 1 < raw.count {
                    let pt = CGPoint(x: raw[i] / p.unit, y: raw[i + 1] / p.unit)
                    minX = min(minX, pt.x); maxX = max(maxX, pt.x); minY = min(minY, pt.y); maxY = max(maxY, pt.y)
                    if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
                    i += 2
                }
                paths[type] = path
            }
            layers.append(PreviewLayer(z: l.z, paths: paths))
            if n % 20 == 19 { await Task.yield() }
        }
        guard !layers.isEmpty, minX.isFinite else { return nil }
        let bed = (p.bed?.count ?? 0) >= 2 ? (w: p.bed![0], h: p.bed![1]) : (w: 256.0, h: 256.0)
        return PreviewScene(layers: layers, typeCount: typeCount, minX: minX, minY: minY, maxX: maxX, maxY: maxY, bed: bed)
    }
}

/// Colours per G-code line type (Orca's feature names), with a fallback palette for unknown names.
enum PreviewColors {
    private static let fallback: [Color] = [
        Color(hex: 0xE4572E), Color(hex: 0xF3A712), Color(hex: 0x29B6F6), Color(hex: 0x66BB6A),
        Color(hex: 0xAB47BC), Color(hex: 0x26A69A), Color(hex: 0xFF7043), Color(hex: 0x8D6E63),
    ]

    static func color(name: String, index: Int) -> Color {
        let n = name.lowercased()
        if n.contains("outer") { return Color(hex: 0xFF8A3D) }
        if n.contains("inner") { return Color(hex: 0xFFD54F) }
        if n.contains("overhang") { return Color(hex: 0x3F51B5) }
        if n.contains("sparse") { return Color(hex: 0xE53935) }
        if n.contains("solid") { return Color(hex: 0xAB47BC) }
        if n.contains("top") { return Color(hex: 0xEF5350) }
        if n.contains("bottom") { return Color(hex: 0x1E88E5) }
        if n.contains("bridge") { return Color(hex: 0x4DB6AC) }
        if n.contains("gap") { return Color(hex: 0xFFFFFF) }
        if n.contains("support") { return Color(hex: 0x66BB6A) }
        if n.contains("skirt") || n.contains("brim") { return Color(hex: 0x00ACC1) }
        return fallback[abs(index) % fallback.count]
    }
}
