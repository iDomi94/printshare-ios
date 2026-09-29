import Foundation

/// Last choices per printer, so the form opens with what was used before (spec 4).
struct PrinterPrefs: Codable, Sendable, Equatable {
    var filament: String?
    var process: String?
    var bedType: String?

    enum CodingKeys: String, CodingKey {
        case filament, process
        case bedType = "bed_type"
    }
}

/// Storage keys shared with the Expo app (`storage.ts`, `app.tsx`).
enum StoreKey {
    static let server = "ps_server"
    static let lang = "ps_lang"
    static let lastPrinter = "ps_printer"
    static func prefs(_ printer: String) -> String { "ps_prefs_\(printer)" }
    static func level(_ printer: String) -> String { "ps_level_\(printer)" }
}
