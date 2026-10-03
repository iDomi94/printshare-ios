import Foundation

/// Filament to book on one spool once the print is over.
struct BookingUse: Codable, Sendable, Equatable {
    var spool: Int
    var grams: Double
    var label: String
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
    /// kept in the cloud account (cloud spools, server 0.29.0) - settled by the server, not this phone
    var account: Bool?

    var grams: Double { uses.reduce(0) { $0 + $1.grams } }
}

extension Booking {
    /// A booking of the cloud account in the app's shape (`fromServer` in the Expo app).
    init(server x: ServerBooking) {
        let list = x.state == "booked" ? x.bookedUses : x.uses
        self.init(id: x.id, printer: x.printer, printerName: x.printerName ?? x.printer, file: x.file,
                  uses: list.map { BookingUse(spool: $0.spool, grams: $0.grams, label: $0.label ?? "#\($0.spool)") },
                  created: x.created * 1000, seen: x.seen, progress: x.progress,
                  ask: x.state == "ask" ? Ask(part: x.askPart ?? 1) : nil, account: true)
    }
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
