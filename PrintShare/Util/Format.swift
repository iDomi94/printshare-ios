import Foundation

/// Regex helpers (NSRegularExpression is not Sendable, so patterns are compiled per call).
extension String {
    /// Capture groups of the first match (index 0 = whole match), or nil.
    func captures(_ pattern: String, options: NSRegularExpression.Options = []) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let ns = self as NSString
        guard let m = re.firstMatch(in: self, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }

    func matches(_ pattern: String, options: NSRegularExpression.Options = []) -> Bool {
        captures(pattern, options: options) != nil
    }

    func replacingRegex(_ pattern: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return self }
        return re.stringByReplacingMatches(in: self, range: NSRange(location: 0, length: (self as NSString).length),
                                           withTemplate: template)
    }
}

enum Format {
    /// "Elegoo PLA @ECC" -> "Elegoo PLA", "0.20mm Standard @Elegoo CC 0.4 nozzle" -> "0.20mm Standard"
    static func shortName(_ name: String?) -> String {
        (name ?? "").replacingRegex(#"\s*@.*$"#, with: "")
    }

    static func brandOf(_ name: String) -> String {
        let first = shortName(name).split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? name : first
    }

    static func plateName(_ l: L10n, _ plate: String?) -> String {
        guard let plate, !plate.isEmpty else { return "–" }
        return l.plate(plate)
    }

    static func extractLink(_ text: String?) -> String {
        (text ?? "").captures(#"https?://[^\s"'<>]+"#)?.first ?? ""
    }

    /// Display name for a job: file name, else a readable link.
    static func jobName(file: String?, link: String?) -> String {
        if let file, !file.isEmpty { return file }
        guard let link, !link.isEmpty else { return "–" }
        if link.hasPrefix("upload:") { return link }
        if let m = link.captures(#"printables\.com/(?:[a-z]{2}/)?model/\d+-([\w-]+)"#) {
            return m[1].replacingOccurrences(of: "-", with: " ")
        }
        return link.replacingRegex(#"^https?://(www\.)?"#, with: "")
    }

    static func ago(_ l: L10n, _ timestamp: Double, now: Date = Date()) -> String {
        let s = max(0, Int((now.timeIntervalSince1970 - timestamp).rounded()))
        let f = RelativeDateTimeFormatter()
        f.locale = l.locale
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f.localizedString(fromTimeInterval: TimeInterval(-s))
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "–" }
        let h = Int(seconds / 3600)
        let m = Int(((seconds.truncatingRemainder(dividingBy: 3600)) / 60).rounded())
        return h > 0 ? "\(h) h \(m) min" : "\(m) min"
    }

    /// Orca prints "1h 5m 3s" / "35m 32s"; show it without seconds.
    static func printTime(_ v: String?) -> String {
        guard let v, !v.isEmpty else { return "–" }
        func num(_ unit: String) -> Int { Int(v.captures("(\\d+)\(unit)")?[1] ?? "") ?? 0 }
        let hh = num("d") * 24 + num("h"), mm = num("m")
        if !v.matches(#"\d+[dhm]"#) { return v }
        return hh > 0 ? "\(hh) h \(mm) min" : "\(mm) min"
    }

    /// 12345 -> "12.3k"
    static func compact(_ n: Int?) -> String {
        guard let n else { return "–" }
        func trim(_ x: Double, _ digits: Int) -> String {
            String(format: "%.\(digits)f", x).replacingOccurrences(of: ".0", with: "", options: [.anchored, .backwards])
        }
        if n < 1000 { return String(n) }
        if n < 1_000_000 { return "\(trim(Double(n) / 1000, n < 10_000 ? 1 : 0))k" }
        return "\(trim(Double(n) / 1_000_000, 1))M"
    }

    static func temp(_ v: Double?, _ target: Double?) -> String {
        guard let v else { return "–" }
        let t = (target ?? 0) > 0 ? " / \(Int((target ?? 0).rounded()))" : ""
        return "\(Int(v.rounded()))\(t) °C"
    }

    /// Warnings for odd combinations (DV-04). Material names come from Orca profile names.
    static func comboWarnings(_ l: L10n, filament: String, plate: String) -> [String] {
        let f = filament.uppercased()
        var out: [String] = []
        let pla = f.matches(#"\bPLA\b"#), petg = f.matches(#"\bPETG\b"#)
        if pla && plate == "Engineering Plate" { out.append(l(.warnPlatePla)) }
        if petg && plate == "High Temp Plate" { out.append(l(.warnPlatePetg)) }
        if !pla && plate == "Cool Plate" { out.append(l(.warnCoolPlate)) }
        if f.matches(#"[-\s](CF|GF)\b"#) { out.append(l(.warnCf)) }
        return out
    }

    static func mb(_ bytes: Int) -> String { String(format: "%.1f MB", Double(bytes) / 1_048_576) }
}
