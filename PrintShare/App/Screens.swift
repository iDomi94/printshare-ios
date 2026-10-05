import Foundation

enum AppTab: Hashable, Sendable {
    case print, discover, jobs, printers, settings
}

/// Arguments of the prepare screen (a model link or a local file, optionally editing an existing job).
struct PrepareArgs: Hashable {
    var link: String?
    var fileURL: URL?
    var fileName: String?
    var edit: EditArgs?
}

struct EditArgs: Hashable {
    var printer: String?
    var file: String?
    var options: JobOptions?
    var name: String?
}

/// Screens pushed on top of the tabs.
enum Screen: Hashable {
    case prepare(PrepareArgs)
    case job(String)
    case model(source: String, id: String)
    case preview(String)
    /// Temperatures, fans, light, speed of one printer (issue #5).
    case control(id: String, name: String)
    /// Own OrcaSlicer printer profile (issue #2).
    case printerProfile(id: String, name: String)
    /// Cloud: a printer of the account and its Wi-Fi address (`CloudPrinterView.new` adds one; `bridge` = add it
    /// behind that bridge, server 0.26.0).
    case cloudPrinter(id: String, bridge: String? = nil)
    /// Cloud: bridges at home (server 0.24.0, "print from anywhere").
    case bridges
    /// Cloud: send from OrcaSlicer with this printer's key (server 0.31.0).
    case orcaUpload(id: String, name: String)
    /// Time-lapse video of a job (server 0.32.0).
    case timelapse(id: String, name: String)
    /// Spoolman (server 0.16.0): where the spools are, and bookings waiting for a decision.
    case spoolman
    /// Cloud spools (server 0.17.0): the list, and one spool (`SpoolFormView.new` adds one, `copy` starts from another).
    case spools
    case spool(id: String, copy: Int? = nil)
    /// Own Manyfold library (server 0.21.0, own servers only).
    case manyfold
    /// AI failure detection with Obico's ML API (server 0.23.0, own servers only).
    case failureDetection
    /// printables.com in a web view with the user's own Printables login (test build).
    case printablesWeb
}

/// Request to show the connect sheet, optionally prefilled from a pairing link.
struct ConnectRequest: Identifiable, Equatable {
    let id = UUID()
    var server: Server?
    var autoConnect = false
    /// Open on "own server" (home screen link, server 0.26).
    var own = false
}
