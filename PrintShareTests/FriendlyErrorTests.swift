import XCTest
@testable import PrintShare

final class FriendlyErrorTests: XCTestCase {
    private let l = L10n(lang: .en)

    private func check(_ status: Int, _ detail: String, _ key: L10nKey, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(friendlyError(l, status: status, detail: detail), l(key), detail, file: file, line: line)
    }

    func testEveryRule() {
        check(401, "invalid token", .errToken)
        check(200, "Printer did not start the print", .errNotStarted)
        check(200, "printer refused to start", .errRefused)
        check(409, "printer is busy - wait", .errBusy)
        check(200, "Printer not reachable: x", .errPrinterOffline)
        check(200, "Moonraker not reachable", .errPrinterOffline)
        check(200, "Sending failed: boom", .errPrinterOffline)
        check(400, "Unrecognised model link", .errLink)
        check(400, "must be an http(s) URL", .errLink)
        check(404, "Model 1 not found (or not public)", .errNotFound)
        check(400, "no sliceable files in model", .errNoFiles)
        check(400, "unsupported file type - use .stl", .errFileType)
        check(413, "whatever", .errTooLarge)
        check(400, "file too large (max 200 MB)", .errTooLarge)
        check(404, "uploaded file not found", .errUploadGone)
        check(500, "OrcaSlicer produced no G-code", .errSlice)
        check(500, "slice failed", .errSlice)
        check(400, "Machine preset 'x' not found", .errProfile)
        check(400, "Thingiverse needs a token", .errThingiverse)
        check(404, "unknown job not found", .errNotFound)
        check(404, "Not Found", .errServerOld)  // route missing: server older than the app
        check(502, "download failed: 500", .errDownload)
        check(502, "Printables API error", .errDownload)
        check(502, "server refused the download", .errDownload)
        check(500, "", .errUnknown)
    }

    func testUnknownDetailIsShownAsIs() {
        XCTAssertEqual(friendlyError(l, status: 500, detail: "HTTP 500"), "HTTP 500")
    }

    func testRuleOrder() {
        // "busy" comes before "not found", "preset ... not found" before the generic not-found rule
        check(409, "printer busy, file not found", .errBusy)
        check(400, "preset X not found", .errProfile)
        // "slice" wins over the later preset rule
        check(400, "slice preset not found", .errSlice)
        // 401 beats every text
        check(401, "printer is busy", .errToken)
        // "uploaded file not found" is not the generic not-found
        check(404, "uploaded file not found", .errUploadGone)
    }

    func testGermanTexts() {
        let de = L10n(lang: .de)
        XCTAssertEqual(friendlyError(de, status: 401, detail: ""), de(.errToken))
        XCTAssertNotEqual(de(.errToken), l(.errToken))
    }
}
