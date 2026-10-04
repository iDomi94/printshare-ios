import Foundation

/// Filament to book on one spool once the print is over.
struct BookingUse: Codable, Sendable, Equatable {
    var spool: Int
    var grams: Double
    var label: String

    enum CodingKeys: String, CodingKey { case spool, grams, label }

    init(spool: Int, grams: Double, label: String) {
        self.spool = spool; self.grams = grams; self.label = label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        spool = try c.decode(Int.self, forKey: .spool)
        grams = c.lenient(Double.self, .grams) ?? 0
        label = c.lenient(String.self, .label) ?? "#\(spool)"
    }
}

/// A started print whose filament the app books after it ended (printers that don't book it themselves).
/// Same JSON as the Expo app's `Booking` (`lib/spoolman.ts`).
struct Booking: Codable, Sendable, Equatable, Identifiable {
    struct Ask: Codable, Sendable, Equatable {
        /// suggested share 0...1
        var part: Double
    }

    var id: String
    var printer: String
    var printerName: String
    /// file name on the printer
    var file: String
    var uses: [BookingUse]
    /// ms since 1970
    var created: Double
    /// the printer was seen printing this file
    var seen: Bool?
    /// last progress seen (%)
    var progress: Double?
    /// finished: book as soon as Spoolman answers
    var ready: Bool?
    /// outcome unclear (cancelled, missed): the user decides
    var ask: Ask?
    /// Kept in the cloud account (cloud spools, server 0.29.0): the server settles it, not this phone.
    var account: Bool?

    var grams: Double { uses.reduce(0) { $0 + $1.grams } }
}

enum Bookings {
    static let maxCount = 20
    /// heating + leveling can take a while before the file shows up
    static let waitStart: Double = 20 * 60 * 1000
    /// printer never seen again
    static let giveUp: Double = 3 * 24 * 3600 * 1000

    static func now() -> Double { (Date().timeIntervalSince1970 * 1000).rounded() }

    /// The same print? File names on the printer may be shortened or cleaned up (PrusaLink: plain FAT names).
    static func sameFile(_ a: String?, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            let last = s.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? s
            return last.replacingRegex("\\.[^.]+$", with: "").lowercased().replacingRegex("[^a-z0-9]", with: "")
        }
        guard let a, !norm(b).isEmpty else { return false }
        return norm(a) == norm(b)
    }

    private static func share(_ progress: Double?) -> Double { min(1, (progress ?? 0) / 100) }

    /// What to do with a booking given the printer's status now (nil = not reachable).
    static func judge(_ b: Booking, _ st: PrinterStatus?, now: Double = now()) -> Booking {
        if b.ready == true || b.ask != nil { return b }
        var out = b
        let age = now - b.created
        guard let st else {
            if age > giveUp { out.ask = .init(part: 1) }
            return out
        }
        if sameFile(st.file, b.file) {
            let progress = st.progress ?? b.progress
            switch st.kind {
            case .active, .paused:
                out.seen = true
                out.progress = progress
            case .done:
                out.ready = true
            case .stopped, .error:
                out.ask = .init(part: share(progress))
            default:  // idle with the file still shown (e.g. PrusaLink after FINISHED)
                if b.seen == true && (b.progress ?? 0) >= 99 {
                    out.ready = true
                } else if b.seen == true {
                    out.ask = .init(part: share(b.progress))
                } else if age > waitStart {
                    out.ask = .init(part: 1)
                }
            }
            return out
        }
        // the printer shows something else now: finished unseen (app closed) or replaced
        if b.seen == true {
            if (b.progress ?? 0) >= 99 { out.ready = true } else { out.ask = .init(part: share(b.progress)) }
        } else if age > waitStart {
            out.ask = .init(part: 1)
        }
        return out
    }

    /// A new booking replaces one for the same printer that never started.
    static func adding(_ b: Booking, to list: [Booking]) -> [Booking] {
        guard !b.uses.isEmpty else { return list }
        let kept = list.filter { !($0.printer == b.printer && $0.seen != true && $0.ask == nil) }
        return Array((kept + [b]).suffix(maxCount))
    }
}

/// Result of settling bookings with fresh printer statuses.
struct SettleResult: Sendable {
    var booked: [Booking] = []
    var open: [Booking] = []
    var error: String?
}

/// A spool booking kept in the cloud account (server 0.29.0, `/api/bookings`).
struct ServerBooking: Decodable, Sendable, Equatable {
    var id: String
    var printer: String
    var printerName: String?
    var file: String
    var uses: [BookingUse]
    var bookedUses: [BookingUse]
    /// Unix seconds.
    var created: Double
    var seen: Bool
    var progress: Double?
    /// "wait", "ready", "ask", "booked" or "dropped".
    var state: String
    var askPart: Double?

    enum CodingKeys: String, CodingKey {
        case id, printer, file, uses, created, seen, progress, state
        case printerName = "printer_name"
        case bookedUses = "booked_uses"
        case askPart = "ask_part"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        printer = c.lenient(String.self, .printer) ?? ""
        printerName = c.lenient(String.self, .printerName)
        file = c.lenient(String.self, .file) ?? ""
        uses = c.lenient([BookingUse].self, .uses) ?? []
        bookedUses = c.lenient([BookingUse].self, .bookedUses) ?? []
        created = c.lenient(Double.self, .created) ?? 0
        seen = c.lenient(Bool.self, .seen) ?? false
        progress = c.lenient(Double.self, .progress)
        state = c.lenient(String.self, .state) ?? "wait"
        askPart = c.lenient(Double.self, .askPart)
    }

    /// Same shape as the phone's own bookings, so the booking card and the lists work unchanged.
    var booking: Booking {
        Booking(id: id, printer: printer, printerName: printerName ?? printer, file: file,
                uses: state == "booked" ? bookedUses : uses, created: (created * 1000).rounded(), seen: seen,
                progress: progress, ready: nil, ask: state == "ask" ? .init(part: askPart ?? 1) : nil, account: true)
    }
}

struct ServerBookings: Decodable, Sendable, Equatable {
    var waiting: [ServerBooking]
    var open: [ServerBooking]
    var booked: [ServerBooking]
    /// Only from `/api/bookings/observe`: what was booked by this very call.
    var bookedNow: [ServerBooking]

    enum CodingKeys: String, CodingKey { case waiting, open, booked, bookedNow = "booked_now" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        waiting = c.lenient([ServerBooking].self, .waiting) ?? []
        open = c.lenient([ServerBooking].self, .open) ?? []
        booked = c.lenient([ServerBooking].self, .booked) ?? []
        bookedNow = c.lenient([ServerBooking].self, .bookedNow) ?? []
    }
}
