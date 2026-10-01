import SwiftUI
import UIKit

/// Physical size of a point on this device, for drawings in real size.
enum ScreenMetrics {
    /// Pixel density (pixels per inch) by model identifier ("iPhone15,2"); nil for unknown idioms.
    static func ppi(model: String) -> Double? {
        if model.hasPrefix("iPhone") {
            switch model {
            case "iPhone11,8", "iPhone12,1", "iPhone12,8", "iPhone14,6": return 326     // XR, 11, SE 2/3
            case "iPhone13,1", "iPhone14,4": return 476                                  // 12 mini, 13 mini
            case "iPhone11,2", "iPhone11,4", "iPhone11,6", "iPhone12,3", "iPhone12,5",   // XS, XS Max, 11 Pro (Max)
                 "iPhone13,4", "iPhone14,3", "iPhone14,8": return 458                    // 12/13 Pro Max, 14 Plus
            default: return 460                                                          // 12 and later
            }
        }
        if model.hasPrefix("iPad") {
            switch model {
            case "iPad11,1", "iPad11,2", "iPad14,1", "iPad14,2", "iPad16,1", "iPad16,2": return 326  // iPad mini 5-7
            default: return 264
            }
        }
        return nil
    }

    /// Points per millimetre: pixels per inch / pixels per point (native scale, so Display Zoom is included).
    static func pointsPerMM(model: String, nativeScale: Double) -> Double {
        let ppi = ppi(model: model) ?? 460
        return ppi / max(1, nativeScale) / 25.4
    }

    static var model: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    @MainActor static var current: Double {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        return pointsPerMM(model: model, nativeScale: Double(scene?.screen.nativeScale ?? 3))
    }
}

/// One layer of infill drawn to scale: `side` mm shown as `side * pointsPerMM` points.
struct InfillSwatch: View {
    var pattern: String
    var density: Int           // percent
    var lineWidth: Double      // mm
    var side: Double = 30      // mm
    var pointsPerMM: Double
    var color: Color = Theme.accent

    var body: some View {
        let size = side * pointsPerMM
        let layer = InfillPattern.layer(pattern, density: Double(density) / 100, lineWidth: lineWidth, side: side)
        Canvas { ctx, _ in
            ctx.scaleBy(x: pointsPerMM, y: pointsPerMM)
            ctx.clip(to: Path(CGRect(x: 0, y: 0, width: side, height: side)))
            switch layer {
            case .solid:
                ctx.fill(Path(CGRect(x: 0, y: 0, width: side, height: side)), with: .color(color))
            case .lines(let top, let below):
                let style = StrokeStyle(lineWidth: lineWidth > 0 ? lineWidth : InfillPattern.defaultLineWidth,
                                        lineCap: .round, lineJoin: .round)
                ctx.stroke(path(below), with: .color(color.opacity(0.3)), style: style)
                ctx.stroke(path(top), with: .color(color), style: style)
            case .empty, .unsupported:
                break
            }
        }
        .frame(width: size, height: size)
        .background(Theme.track)
        .overlay(Rectangle().stroke(Theme.sub.opacity(0.5), lineWidth: 1))
        .accessibilityHidden(true)
    }

    private func path(_ lines: [[CGPoint]]) -> Path {
        var p = Path()
        for l in lines where l.count > 1 { p.addLines(l) }
        return p
    }
}

/// Small picture of a pattern for lists (16 mm at 25 % squeezed into `size` points).
struct InfillThumb: View {
    var pattern: String
    var size: CGFloat = 40

    var body: some View {
        if !InfillPattern.hasPreview(pattern) {
            Image(systemName: pattern == "lightning" ? "bolt" : "square.dashed")
                .font(.title3).foregroundStyle(Theme.accent).frame(width: size, height: size)
                .background(Theme.track).clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
        } else {
            InfillSwatch(pattern: pattern, density: 25, lineWidth: InfillPattern.defaultLineWidth, side: 16,
                         pointsPerMM: Double(size) / 16)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// The 3 × 3 cm preview in real size with its caption.
struct InfillRealSize: View {
    var pattern: String
    var density: Int
    var lineWidth: Double
    var t: L10n

    var body: some View {
        let layer = InfillPattern.layer(pattern, density: Double(density) / 100, lineWidth: lineWidth, side: 30)
        VStack(spacing: 8) {
            ZStack {
                InfillSwatch(pattern: pattern, density: density, lineWidth: lineWidth, pointsPerMM: ScreenMetrics.current)
                switch layer {
                case .empty: Text(t(.infillHollow)).font(.footnote).foregroundStyle(Theme.sub)
                case .unsupported: Text(t(.infillNoPreview)).font(.footnote).foregroundStyle(Theme.sub)
                        .multilineTextAlignment(.center).padding(8)
                default: EmptyView()
                }
            }
            Text(caption(layer)).font(.footnote).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Theme.space).padding(.bottom, 14)
        .accessibilityElement(children: .combine)
    }

    private func caption(_ layer: InfillPattern.Layer) -> String {
        if case .lines(_, let below) = layer, !below.isEmpty { return t(.infillPreviewHint) + " " + t(.infillPreviewBelow) }
        return t(.infillPreviewHint)
    }
}
