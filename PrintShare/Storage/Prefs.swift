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
    /// Wi-Fi addresses of the cloud printers, per account (`printerAccess.ts`).
    static func lan(_ account: String) -> String { "ps_lan_\(account)" }
    /// Spoolman address (or "cloud"), last spools per printer, bookings - per server / account (`spoolman.ts`).
    static func spoolman(_ account: String) -> String { "ps_spoolman_\(account)" }
    static func spools(_ account: String, _ printer: String) -> String {
        "ps_spools_\(account)_\(printer.replacingRegex("[^A-Za-z0-9_.-]", with: "_"))"
    }
    static func bookings(_ account: String) -> String { "ps_bookings_\(account)" }
    /// Spoolman spool → cloud spool copied by the import (server 0.39.0), so a second run skips them.
    static func spoolImport(_ account: String) -> String { "ps_spoolimport_\(account)" }
    /// "Always make a time-lapse" (server 0.40.0), per server / account.
    static func timelapseAlways(_ account: String) -> String { "ps_timelapse_always_\(account)" }
}
