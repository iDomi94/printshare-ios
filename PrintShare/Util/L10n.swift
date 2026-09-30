import Foundation

enum Lang: String, Sendable, CaseIterable {
    case de, en
}

enum LangPref: String, Sendable, CaseIterable, Codable {
    case auto, de, en
}

private final class BundleToken {}

/// All user-visible text. Strings come from `Localizable.xcstrings` (compiled to `<lang>.lproj`), loaded from the
/// bundle of the language chosen in the settings, so the app language can differ from the system language.
struct L10n: Sendable {
    let lang: Lang
    private let bundle: Bundle

    init(lang: Lang) {
        self.lang = lang
        let app = Bundle(for: BundleToken.self)
        if let path = app.path(forResource: lang.rawValue, ofType: "lproj"), let b = Bundle(path: path) {
            bundle = b
        } else {
            bundle = app
        }
    }

    init(pref: LangPref) {
        self.init(lang: L10n.resolve(pref))
    }

    static func resolve(_ pref: LangPref, preferred: [String] = Locale.preferredLanguages) -> Lang {
        switch pref {
        case .de: return .de
        case .en: return .en
        case .auto: return (preferred.first ?? "").lowercased().hasPrefix("de") ? .de : .en
        }
    }

    var locale: Locale { Locale(identifier: lang.rawValue) }

    private static let missing = "\u{1}missing\u{1}"

    /// Text for a raw key, or nil when the key is unknown.
    func lookup(_ key: String) -> String? {
        let v = bundle.localizedString(forKey: key, value: L10n.missing, table: nil)
        return v == L10n.missing ? nil : v
    }

    func callAsFunction(_ key: L10nKey, _ vars: [String: String] = [:]) -> String {
        var text = lookup(key.rawValue) ?? key.rawValue
        for (k, v) in vars { text = text.replacingOccurrences(of: "{\(k)}", with: v) }
        return text
    }

    func jobState(_ state: String) -> String { lookup("jobState.\(state)") ?? state }
    func printerKind(_ kind: String) -> String { lookup("printerKind.\(kind)") ?? kind }
    func rawState(_ state: String) -> String { lookup("rawState.\(state)") ?? state }
    func plate(_ name: String) -> String { lookup("plate.\(name)") ?? name }
    /// OrcaSlicer line type (`;TYPE:` name) in the app language.
    func lineType(_ name: String) -> String { lookup("lineType.\(name)") ?? name }
    /// Printer control names (heater / fan / light ids from the server); unknown ids are shown as they are.
    func heaterName(_ id: String) -> String { lookup("heater.\(id)") ?? id }
    func fanName(_ id: String) -> String { lookup("fan.\(id)") ?? id }
    func lightName(_ id: String) -> String { lookup("light.\(id)") ?? id }
    /// Centauri Carbon speed modes (50 = silent … 160 = ludicrous), else "130 %".
    func speedMode(_ value: Int) -> String { lookup("speedMode.\(value)") ?? "\(value) %" }
    func powerState(_ state: String) -> String { lookup("powerState.\(state)") ?? state }
    func profileKind(_ kind: String) -> String { lookup("profileKind.\(kind)") ?? kind }
    var suggestions: [String] { callAsFunction(.suggestionList).split(separator: "|").map(String.init) }

    /// Server log lines -> readable text (German only, like the Expo app).
    func translateLog(_ line: String) -> String {
        guard lang == .de else { return line }
        for (pattern, template) in Self.logRules {
            guard let re = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(line.startIndex..., in: line)
            if re.firstMatch(in: line, range: range) != nil {
                return re.stringByReplacingMatches(in: line, range: range, withTemplate: template)
            }
        }
        return line
    }

    private static let logRules: [(String, String)] = [
        ("^Looking up model files", "Modelldateien werden gesucht"),
        ("^Downloading (.*)", "Download: $1"),
        ("^Waiting for another slice job", "Wartet auf einen anderen Auftrag"),
        ("^Slicing for (.*)", "Slicen für $1"),
        ("^Sliced: (.*)", "Geslict: $1"),
        ("^Sending to printer and starting", "Wird gesendet und gestartet"),
        ("^Sending to printer", "Wird gesendet"),
        ("^Done", "Fertig"),
    ]
}
