import Foundation

/// Lane selection (issue #6): which lane of the printer prints each filament of the model. Same rules as
/// `job/[id].tsx` of the Expo app.
enum LanePlan {
    /// One filament of the sliced model (1-based index as the server counts it).
    struct Colour: Equatable, Sendable {
        var index: Int
        var color: String?
        var preset: String
    }

    struct Warning: Equatable, Sendable {
        var text: String
        /// An empty lane: printing is not possible.
        var blocking: Bool
    }

    private static let materials = ["PLA", "PETG", "ABS", "ASA", "TPU", "PA", "PC", "PVA", "HIPS", "PET"]

    /// Material type from a filament preset name: "Elegoo PETG @ECC" -> "PETG" (nil if unknown).
    static func materialOf(_ name: String?) -> String? {
        let words = (name ?? "").uppercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return materials.first { words.contains($0) }
    }

    /// The filaments of a job: one per colour for multicolour, else the single filament.
    static func colours(_ result: JobResult?) -> [Colour] {
        guard let r = result else { return [] }
        if r.filaments.count > 1 {
            return r.filaments.map { Colour(index: $0.index, color: $0.color, preset: $0.preset) }
        }
        return [Colour(index: 1, color: nil, preset: r.profiles["filament"] ?? "")]
    }

    /// Lanes the app can choose: only those with a tool number.
    static func usable(_ status: PrinterStatus?) -> [Lane] {
        guard let status, status.kind != .offline else { return [] }
        return status.lanes.filter { $0.tool != nil }
    }

    private static func rgb(_ hex: String?) -> [Int]? {
        guard var h = hex?.trimmingCharacters(in: .whitespaces), !h.isEmpty else { return nil }
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count >= 6, let v = Int(h.prefix(6), radix: 16) else { return nil }
        return [(v >> 16) & 0xFF, (v >> 8) & 0xFF, v & 0xFF]
    }

    static func distance(_ a: String?, _ b: String?) -> Int {
        guard let x = rgb(a), let y = rgb(b) else { return 1_000_000 }
        return zip(x, y).reduce(0) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
    }

    /// Chosen tool per filament: the user's choice, else a loaded lane with the profile's material (closest colour),
    /// else the lane for T(n-1), else any loaded lane, else the first lane.
    static func tools(colours: [Colour], lanes: [Lane], choice: [Int: Int]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        let loaded = lanes.filter(\.loaded)
        for c in colours {
            if let chosen = choice[c.index] { out[c.index] = chosen; continue }
            let want = materialOf(c.preset)
            let same = loaded.filter { l in
                guard let want else { return false }
                return (l.material ?? "").uppercased().hasPrefix(want)
            }
            let best = same.enumerated().min { a, b in
                let da = distance(a.element.color, c.color), db = distance(b.element.color, c.color)
                return da != db ? da < db : a.offset < b.offset
            }?.element
            let pick = best ?? loaded.first { $0.tool == c.index - 1 } ?? loaded.first ?? lanes.first
            if let tool = pick?.tool { out[c.index] = tool }
        }
        return out
    }

    /// Red for an empty lane (blocks printing), yellow when the lane holds another material than the profile.
    static func warnings(_ t: L10n, colours: [Colour], lanes: [Lane], tools: [Int: Int]) -> [Warning] {
        var out: [Warning] = []
        for c in colours {
            guard let lane = lanes.first(where: { $0.tool == tools[c.index] }) else { continue }
            let what = colours.count > 1 ? t(.colorN, ["n": String(c.index)]) : t(.lane)
            if !lane.loaded {
                out.append(Warning(text: t(.laneEmptyWarn, ["what": what, "lane": lane.id]), blocking: true))
            }
            let want = materialOf(c.preset), have = (lane.material ?? "").uppercased()
            if lane.loaded, let want, !have.isEmpty, !have.hasPrefix(want) {
                out.append(Warning(text: t(.laneMaterialWarn, ["what": what, "want": want, "lane": lane.id,
                                                                "have": lane.material ?? ""]),
                                   blocking: false))
            }
        }
        return out
    }

    /// "CANVAS_1 · PLA" or "CANVAS_3 · empty".
    static func label(_ t: L10n, lane: Lane?) -> String {
        guard let lane else { return "–" }
        return [lane.id, lane.loaded ? lane.material : t(.laneEmpty)].compactMap { $0 }.joined(separator: " · ")
    }
}
