import Foundation

/// Plate options per job (server 0.14.0): copies, position (tilt / lay flat automatically), size.
/// Same choices as the Expo app (`mobile/src/lib/plate.ts`) and the web page.
enum PlateTilt: String, CaseIterable, Sendable {
    case asModel, auto, forward, back, right, left, upside

    /// rotate_x / rotate_y in degrees; `auto` lays the model flat instead (orient).
    var rotation: (x: Double, y: Double) {
        switch self {
        case .asModel, .auto: return (0, 0)
        case .forward: return (90, 0)
        case .back: return (-90, 0)
        case .right: return (0, 90)
        case .left: return (0, -90)
        case .upside: return (180, 0)
        }
    }

    var label: L10nKey {
        switch self {
        case .asModel: return .tiltNone
        case .auto: return .tiltAuto
        case .forward: return .tiltForward
        case .back: return .tiltBack
        case .right: return .tiltRight
        case .left: return .tiltLeft
        case .upside: return .tiltUpside
        }
    }

    init(options o: JobOptions?) {
        guard let o else { self = .asModel; return }
        if o.orient == true { self = .auto; return }
        let x = o.rotateX ?? 0, y = o.rotateY ?? 0
        self = Self.allCases.first { $0 != .asModel && $0 != .auto && $0.rotation.x == x && $0.rotation.y == y } ?? .asModel
    }
}

enum PlateOptions {
    static let maxCopies = 50
    static let scaleRange = 25...400

    /// Writes only what differs from "one copy, as in the model, 100 %" into `o`.
    static func apply(copies: Int, tilt: PlateTilt, scale: Int, to o: inout JobOptions) {
        o.copies = copies > 1 ? min(copies, maxCopies) : nil
        let r = tilt.rotation
        o.rotateX = r.x != 0 ? r.x : nil
        o.rotateY = r.y != 0 ? r.y : nil
        o.orient = tilt == .auto ? true : nil
        o.scale = scale != 100 ? scale : nil
    }

    /// "3× · Tip forward · 150 %"; empty when nothing was changed. `placed` = copies that fit (job result).
    static func summary(_ t: L10n, _ o: JobOptions?, placed: Int? = nil) -> String {
        var out: [String] = []
        let n = placed ?? o?.copies ?? 1
        if n > 1 { out.append(t(.copiesV, ["n": String(n)])) }
        let tilt = PlateTilt(options: o)
        if tilt != .asModel { out.append(t(tilt.label)) }
        if let s = o?.scale, s != 100 { out.append("\(s) %") }
        return out.joined(separator: " · ")
    }

    /// Hint when fewer copies fit than were asked for.
    static func fewerHint(_ t: L10n, _ r: JobResult?) -> String? {
        guard let r, let asked = r.copiesRequested, let placed = r.copies, placed < asked else { return nil }
        return t(.copiesFit, ["n": String(placed), "m": String(asked)])
    }
}
