import Foundation

/// Which spool prints each colour of a sliced job, and what to warn about (`job/[id].tsx` of the Expo app).
enum SpoolPlan {
    /// A choice of "no spool" (Spoolman ids start at 1).
    static let none = 0

    struct Colour: Equatable, Sendable {
        var index: Int
        var preset: String
        var grams: Double?
    }

    static func colours(_ result: JobResult?) -> [Colour] {
        guard let r = result else { return [] }
        if r.filaments.count > 1 { return r.filaments.map { Colour(index: $0.index, preset: $0.preset, grams: $0.grams) } }
        return [Colour(index: 1, preset: r.profiles["filament"] ?? "", grams: r.filamentG)]
    }

    /// Spool per colour index (absent = none). With AFC and Moonraker's Spoolman link the spools belong to the slots;
    /// otherwise the user's choice, else the lane's spool, else the spool put into the chosen slot in the filament menu
    /// (`slots`: tool → spool, server 0.38.0), else Moonraker's active spool, else the last one used.
    /// Spools that no longer exist are dropped.
    static func spools(colours: [Colour], lanes: [Lane], tools: [Int: Int], afc: Bool, choice: [Int: Int],
                       tracker: SpoolmanLink?, last: [String: Int], known: [Spool]?, slots: [Int: Int] = [:]) -> [Int: Int] {
        var out: [Int: Int] = [:]
        let printerBooks = tracker?.connected == true
        for col in colours {
            let lane = lanes.first { $0.tool != nil && $0.tool == tools[col.index] }
            var id: Int?
            if afc {
                id = lane?.spoolId
            } else if let chosen = choice[col.index] {
                id = chosen == none ? nil : chosen
            } else {
                id = lane?.spoolId ?? lane?.tool.flatMap { slots[$0] } ?? (printerBooks ? tracker?.spoolId : nil)
                    ?? last[String(col.index)]
            }
            if let id, known == nil || known!.contains(where: { $0.id == id }) { out[col.index] = id }
        }
        return out
    }

    /// Too little filament left, or another material than the colour's preset.
    static func warnings(_ t: L10n, colours: [Colour], spoolFor: [Int: Int], known: [Spool]) -> [String] {
        var out: [String] = []
        for col in colours {
            guard let sp = known.first(where: { $0.id == spoolFor[col.index] }) else { continue }
            let what = colours.count > 1 ? t(.colorN, ["n": String(col.index)]) : t(.spool)
            if let left = sp.remainingG, let need = col.grams, left < need {
                out.append(t(.spoolTooLittle, ["what": what, "spool": sp.label, "have": String(Int(left.rounded(.down))),
                                                "need": String(format: "%.1f", need)]))
            }
            if !LanePlan.fits(col.preset, material: sp.material) {
                out.append(t(.spoolMaterialWarn, ["what": what, "want": Format.shortName(col.preset), "have": sp.material ?? ""]))
            }
        }
        return out
    }

    /// What the app books after a started print (not when the printer books itself).
    static func uses(colours: [Colour], spoolFor: [Int: Int], known: [Spool]) -> [BookingUse] {
        colours.compactMap { col in
            guard let sp = known.first(where: { $0.id == spoolFor[col.index] }), let g = col.grams, g > 0 else { return nil }
            return BookingUse(spool: sp.id, grams: g, label: sp.label)
        }
    }
}
