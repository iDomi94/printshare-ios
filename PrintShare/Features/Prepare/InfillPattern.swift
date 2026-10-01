import CoreGraphics
import Foundation

/// Sparse infill patterns the app offers (server 0.15.2 `infill_pattern`, OrcaSlicer `sparse_infill_pattern`) and
/// the geometry of one layer of them for the preview. The other Orca patterns are not offered: they look like one
/// of these from above (aligned rectilinear, zig zag …) or are meant for special cases.
enum InfillPattern {
    static let offered = ["rectilinear", "grid", "triangles", "tri-hexagon", "cubic", "adaptivecubic", "honeycomb",
                          "3dhoneycomb", "gyroid", "crosshatch", "concentric", "lightning"]
    /// Line width when the server does not say (Orca's default sparse infill width for a 0.4 mm nozzle).
    static let defaultLineWidth = 0.45

    /// Patterns to show: the offered ones the server knows, plus the profile's own pattern if it is another one.
    static func choices(server: [String]?, current: String?) -> [String] {
        guard let server else { return [] }
        var out = offered.filter(server.contains)
        if let current, !current.isEmpty, !out.contains(current) { out.insert(current, at: 0) }
        return out
    }

    static func hasPreview(_ pattern: String) -> Bool { offered.contains(pattern) && pattern != "lightning" }

    enum Layer: Equatable {
        case empty          // 0 %: hollow
        case solid          // 100 %
        case unsupported    // no top view (lightning, unknown pattern)
        /// `top` = the layer seen from above; `below` = the layer under it where the direction changes per layer.
        case lines(top: [[CGPoint]], below: [[CGPoint]])
    }

    /// One layer of `pattern` at `density` (0...1) in a `side` × `side` mm square, coordinates in mm.
    /// Line spacing follows OrcaSlicer: extruded length × line width / area ≈ density.
    /// Lines may reach past the square; the drawing clips them.
    static func layer(_ pattern: String, density: Double, lineWidth: Double, side: Double) -> Layer {
        guard hasPreview(pattern) else { return .unsupported }
        if density <= 0.001 { return .empty }
        if density >= 0.99 { return .solid }
        let w = lineWidth > 0 ? lineWidth : defaultLineWidth
        let s = w / density  // spacing of one family of straight lines carrying the whole density
        switch pattern {
        case "rectilinear", "crosshatch":  // one direction per layer (crosshatch: per block of layers), 90° apart
            return .lines(top: parallel(45, spacing: s, side: side), below: parallel(-45, spacing: s, side: side))
        case "grid":
            return .lines(top: parallel(45, spacing: 2 * s, side: side) + parallel(-45, spacing: 2 * s, side: side),
                          below: [])
        case "triangles", "tri-hexagon", "cubic", "adaptivecubic":
            // three directions; tri-hexagon shifts one by half a spacing (stars), cubic shifts them with the height
            let phases: [Double]
            switch pattern {
            case "triangles": phases = [0, 0, 0]
            case "tri-hexagon": phases = [0, 0, 0.5]
            default: phases = [0, 1.0 / 3, 2.0 / 3]
            }
            let base = pattern.hasSuffix("cubic") ? 15.0 : 0
            let lines = (0..<3).flatMap { i in
                parallel(base + Double(i) * 60, spacing: 3 * s, phase: phases[i] * 3 * s, side: side)
            }
            return .lines(top: lines, below: [])
        case "honeycomb":
            return .lines(top: honeycomb(side: 2 * w / (3.0.squareRoot() * density), area: side), below: [])
        case "3dhoneycomb":
            let sp = s * trapezoidFactor
            return .lines(top: waves(trapezoid: true, horizontal: true, spacing: sp, side: side),
                          below: waves(trapezoid: true, horizontal: false, spacing: sp, side: side))
        case "gyroid":
            let sp = s * sineFactor
            return .lines(top: waves(trapezoid: false, horizontal: true, spacing: sp, side: side),
                          below: waves(trapezoid: false, horizontal: false, spacing: sp, side: side))
        case "concentric":
            return .lines(top: concentric(spacing: s, side: side), below: [])
        default:
            return .unsupported
        }
    }

    // MARK: shapes

    /// Parallel lines at `angle` degrees, `spacing` apart, through the centre shifted by `phase`.
    static func parallel(_ angle: Double, spacing: Double, phase: Double = 0, side: Double) -> [[CGPoint]] {
        let a = angle * .pi / 180
        let u = (x: cos(a), y: sin(a)), n = (x: -sin(a), y: cos(a))
        let c = side / 2, r = side * 0.75
        let k = Int((r / spacing).rounded(.up)) + 1
        return (-k...k).map { i in
            let o = Double(i) * spacing + phase
            return [CGPoint(x: c + n.x * o - u.x * r, y: c + n.y * o - u.y * r),
                    CGPoint(x: c + n.x * o + u.x * r, y: c + n.y * o + u.y * r)]
        }
    }

    /// Hexagons with edge length `a`; every edge once (each cell draws three of its six edges).
    static func honeycomb(side a: Double, area: Double) -> [[CGPoint]] {
        let dx = 3.0.squareRoot() * a, dy = 1.5 * a
        var out: [[CGPoint]] = []
        for row in -1...Int(area / dy) + 1 {
            for col in -1...Int(area / dx) + 1 {
                let cx = Double(col) * dx + (row.isMultiple(of: 2) ? 0 : dx / 2), cy = Double(row) * dy
                out.append((0...3).map { k in
                    let t = (30 + 60 * Double(k)) * .pi / 180
                    return CGPoint(x: cx + a * cos(t), y: cy + a * sin(t))
                })
            }
        }
        return out
    }

    /// Wavy lines `spacing` apart, neighbours mirrored so they form cells: sine (gyroid) or trapezoid (3D honeycomb).
    static func waves(trapezoid: Bool, horizontal: Bool, spacing s: Double, side: Double) -> [[CGPoint]] {
        let period = 2 * s
        let steps = Int(((side + 2 * period) / period).rounded(.up)) * (trapezoid ? 4 : 24)
        var out: [[CGPoint]] = []
        for i in -1...Int(side / s) + 1 {
            let flip = i.isMultiple(of: 2) ? 1.0 : -1.0
            out.append((0...steps).map { j in
                let x = -period + Double(j) * period / (trapezoid ? 4 : 24)
                let y = Double(i) * s + flip * wave(trapezoid: trapezoid, x / period) * s
                return horizontal ? CGPoint(x: x, y: y) : CGPoint(x: y, y: x)
            })
        }
        return out
    }

    /// Offset of a wave at `t` periods, in spacings: sine amplitude 0.3, trapezoid ±0.25 with flats of a quarter.
    private static func wave(trapezoid: Bool, _ t: Double) -> Double {
        guard trapezoid else { return 0.3 * sin(2 * .pi * t) }
        let f = t - t.rounded(.down)
        switch f {
        case ..<0.25: return -0.25
        case ..<0.5: return -0.25 + (f - 0.25) * 2
        case ..<0.75: return 0.25
        default: return 0.25 - (f - 0.75) * 2
        }
    }

    /// Path length per unit of advance of one wave (period 2 spacings), so wavy lines can be spaced for the density.
    static let sineFactor = arcFactor(trapezoid: false)
    static let trapezoidFactor = arcFactor(trapezoid: true)

    private static func arcFactor(trapezoid: Bool) -> Double {
        let n = 400
        var len = 0.0
        for j in 0..<n {
            let t0 = Double(j) / Double(n), t1 = Double(j + 1) / Double(n)
            // x in spacings: one period = 2
            let dx = 2.0 / Double(n), dy = wave(trapezoid: trapezoid, t1) - wave(trapezoid: trapezoid, t0)
            len += (dx * dx + dy * dy).squareRoot()
        }
        return len / 2
    }

    /// Squares from the outline inwards (concentric follows the part's outline).
    static func concentric(spacing s: Double, side: Double) -> [[CGPoint]] {
        var out: [[CGPoint]] = []
        var inset = s / 2
        while inset < side / 2 {
            let a = inset, b = side - inset
            out.append([CGPoint(x: a, y: a), CGPoint(x: b, y: a), CGPoint(x: b, y: b), CGPoint(x: a, y: b),
                        CGPoint(x: a, y: a)])
            inset += s
        }
        return out
    }

    /// Length of `lines` inside the `side` × `side` square (each segment clipped), in mm.
    static func length(_ lines: [[CGPoint]], inside side: Double) -> Double {
        var total = 0.0
        for line in lines {
            for (p, q) in zip(line, line.dropFirst()) {
                total += clippedLength(p, q, side: side)
            }
        }
        return total
    }

    /// Liang-Barsky clip of segment p-q against [0, side]².
    private static func clippedLength(_ p: CGPoint, _ q: CGPoint, side: Double) -> Double {
        let px = Double(p.x), py = Double(p.y), dx = Double(q.x) - px, dy = Double(q.y) - py
        var t0 = 0.0, t1 = 1.0
        for (pp, qq) in [(-dx, px), (dx, side - px), (-dy, py), (dy, side - py)] {
            if pp == 0 {
                if qq < 0 { return 0 }
                continue
            }
            let r = qq / pp
            if pp < 0 { t0 = max(t0, r) } else { t1 = min(t1, r) }
            if t0 > t1 { return 0 }
        }
        return (t1 - t0) * (dx * dx + dy * dy).squareRoot()
    }
}
