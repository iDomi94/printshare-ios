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
            let what = colours.count > 1 ? t(.colorN, ["n": String(c.index)]) : t(.slot)
            let slot = slotName(t, lane: lane, lanes: lanes)
            if !lane.loaded {
                out.append(Warning(text: t(.slotEmptyWarn, ["what": what, "slot": slot]), blocking: true))
            }
            let want = materialOf(c.preset), have = (lane.material ?? "").uppercased()
            if lane.loaded, let want, !have.isEmpty, !have.hasPrefix(want) {
                out.append(Warning(text: t(.slotMaterialWarn, ["what": what, "want": want, "slot": slot,
                                                                "have": lane.material ?? ""]),
                                   blocking: false))
            }
        }
        return out
    }

    /// Physical slot number of a lane, as printed on the unit: the trailing number of its id ("CANVAS_1" -> 1).
    /// Only when every lane has one and no two share it (several units), else nil and the app shows the lane id.
    static func slotNumbers(_ lanes: [Lane]) -> [String: Int] {
        var out: [String: Int] = [:]
        for l in lanes {
            guard let n = Int(String(l.id.reversed().prefix(while: { $0.isNumber }).reversed())) else { return [:] }
            out[l.id] = n
        }
        return Set(out.values).count == lanes.count ? out : [:]
    }

    /// "Slot 1" (physical slot) or the lane id when the lanes have no usable slot numbers.
    static func slotName(_ t: L10n, lane: Lane, lanes: [Lane]) -> String {
        slotNumbers(lanes)[lane.id].map { t(.slotN, ["n": String($0)]) } ?? lane.id
    }

    /// Lanes in the order of their slots (the server sorts by tool, which is not the physical order).
    static func bySlot(_ lanes: [Lane]) -> [Lane] {
        let n = slotNumbers(lanes)
        return lanes.enumerated().sorted { a, b in
            let x = n[a.element.id] ?? a.offset, y = n[b.element.id] ?? b.offset
            return x != y ? x < y : a.offset < b.offset
        }.map(\.element)
    }

    /// Filament preset for the material loaded in a lane: the one named like the lane's filament, else the
    /// preferred preset if it has that material, else the default, else the first preset of that material.
    /// nil for an empty lane or a material the app does not know (the caller keeps its preset).
    static func preset(for lane: Lane?, materials: [String], preferred: String?, fallback: String?) -> String? {
        guard let lane, lane.loaded, let want = materialOf(lane.material) else { return nil }
        let same = materials.filter { materialOf($0) == want }
        if let name = lane.filament?.lowercased(), !name.isEmpty,
           let hit = same.first(where: { $0.lowercased().hasPrefix(name) }) ?? same.first(where: { $0.lowercased().contains(name) }) {
            return hit
        }
        if let p = preferred, same.contains(p) { return p }
        if let f = fallback, same.contains(f) { return f }
        return same.first
    }

    /// "Slot 1 · PLA" or "Slot 3 · empty".
    static func label(_ t: L10n, lane: Lane?, lanes: [Lane]) -> String {
        guard let lane else { return "–" }
        return [slotName(t, lane: lane, lanes: lanes), lane.loaded ? lane.material : t(.laneEmpty)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    /// Picker rows: "Slot 1", sub "PLA · T3 · in the toolhead" (value = tool number).
    static func choices(_ t: L10n, lanes: [Lane]) -> [Choice] {
        bySlot(lanes).compactMap { l -> Choice? in
            guard let tool = l.tool else { return nil }
            let what = l.loaded ? [l.material, l.filament].compactMap { $0 }.joined(separator: " · ") : t(.laneEmpty)
            let parts: [String?] = [what.isEmpty ? nil : what, "T\(tool)", l.inToolhead ? t(.laneInToolhead) : nil]
            let sub = parts.compactMap { $0 }
            return Choice(value: String(tool), label: slotName(t, lane: l, lanes: lanes), sub: sub.joined(separator: " · "))
        }
    }
}
