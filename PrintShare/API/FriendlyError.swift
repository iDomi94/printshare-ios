import Foundation

/// Map server error texts to messages a non-technical user understands (SL-04).
/// The order of the rules matters: the first hit wins (same order as `friendlyError` in api.ts).
func friendlyError(_ l: L10n, status: Int, detail: String) -> String {
    let d = detail.lowercased()
    func has(_ s: String) -> Bool { d.contains(s) }
    let rules: [(Bool, L10nKey)] = [
        (status == 401, .errToken),
        // FastAPI's answer for a route the server does not have: a feature of a newer server version (e.g. the
        // preview needs 0.5.0, colours 0.6.0). Must come before the generic "not found" rule.
        (status == 404 && detail.trimmingCharacters(in: .whitespaces) == "Not Found", .errServerOld),
        (has("did not start"), .errNotStarted),
        (has("refused to start"), .errRefused),
        (has("busy"), .errBusy),
        (has("printer not reachable") || has("moonraker not reachable") || has("sending failed"), .errPrinterOffline),
        (has("unrecognised model link") || has("must be an http"), .errLink),
        (has("not found (or not public)"), .errNotFound),
        (has("no sliceable files"), .errNoFiles),
        (has("unsupported file type"), .errFileType),
        (status == 413 || has("too large"), .errTooLarge),
        (has("uploaded file not found"), .errUploadGone),
        (has("orcaslicer produced no g-code") || has("slice"), .errSlice),
        (has("preset") && has("not found"), .errProfile),
        (has("thingiverse needs"), .errThingiverse),
        (has("not found") && !has("uploaded"), .errNotFound),
        (has("download failed") || has("printables api error") || has("refused the download"), .errDownload),
    ]
    for (hit, key) in rules where hit { return l(key) }
    return detail.isEmpty ? l(.errUnknown) : detail
}
