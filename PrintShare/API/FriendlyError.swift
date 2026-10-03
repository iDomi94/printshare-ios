import Foundation

/// Map server error texts to messages a non-technical user understands (SL-04).
/// The order of the rules matters: the first hit wins (same order as `friendlyError` in api.ts).
func friendlyError(_ l: L10n, status: Int, detail: String) -> String {
    let d = detail.lowercased()
    func has(_ s: String) -> Bool { d.contains(s) }
    let rules: [(Bool, L10nKey)] = [
        // messages of the app's own printer connections (LAN/) and of the newer server features (0.15-0.34)
        (has("rejected the api key") || has("rejected the password"), .errLanAuth),
        (has("enter the octoprint api key") || has("enter the prusalink password"), .errLanAuth),
        (has("not connected in octoprint") || has("is the printer connected?"), .errLanOcto),
        (has("no writable storage"), .errLanStorage),
        (has("accepted the start but did not begin") || has("stored the file but did not start"), .errNotStarted),
        (has("no print is running"), .errNoPrint),
        (has("not reachable on the wi-fi") || has("did not answer") || has("did not send its status")
            || d.range(of: "^(octoprint|prusalink|the printer) answered http", options: .regularExpression) != nil, .errLanOffline),
        (has("refused the upload"), .errLanUpload),
        (has("spoolman not reachable") || d.hasPrefix("spoolman answered http"), .errSpoolmanOffline),
        (has("manyfold refused"), .errManyfoldKey),
        (has("manyfold not reachable") || has("manyfold sent no json"), .errManyfoldOffline),
        (has("ml api"), .errMlOffline),
        (has("bundle not found or private"), .errOrcaPrivate),
        (has("not an orca cloud share link"), .errOrcaLink),
        (has("makerworld only allows downloads"), .errMakerWorld),
        (has("bridge is offline") || has("bridge went offline") || has("bridge was removed")
            || has("bridge connection broke"), .errBridgeOffline),
        (has("bridge didn't answer in time"), .errBridgeTimeout),
        (has("unknown or expired code"), .errBridgeCode),
        (has("set up on the server at home itself"), .errBridgeServerPrinter),
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

/// Text for any error shown to the user: server errors are already translated, the rest (the app's own printer
/// connections, bridges on the Wi-Fi) goes through the same rules.
func errorText(_ l: L10n, _ error: Error) -> String {
    if let e = error as? APIError { return e.message }
    return friendlyError(l, status: 0, detail: error.localizedDescription)
}
