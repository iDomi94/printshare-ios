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
    /// Cloud: a printer of the account and its Wi-Fi address (`CloudPrinterView.new` adds one).
    case cloudPrinter(id: String)
}

/// Request to show the connect sheet, optionally prefilled from a pairing link.
struct ConnectRequest: Identifiable, Equatable {
    let id = UUID()
    var server: Server?
    var autoConnect = false
}
