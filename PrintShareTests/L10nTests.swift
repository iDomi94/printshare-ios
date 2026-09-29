import XCTest
@testable import PrintShare

final class L10nTests: XCTestCase {
    func testEveryKeyExistsInBothLanguages() {
        for lang in Lang.allCases {
            let l = L10n(lang: lang)
            for key in L10nKey.allCases {
                let text = l.lookup(key.rawValue)
                XCTAssertNotNil(text, "\(key.rawValue) missing in \(lang)")
                XCTAssertFalse((text ?? "").isEmpty, "\(key.rawValue) empty in \(lang)")
            }
        }
    }

    func testLanguagesDiffer() {
        XCTAssertEqual(L10n(lang: .en)(.tabPrint), "Print")
        XCTAssertEqual(L10n(lang: .de)(.tabPrint), "Drucken")
    }

    func testPlaceholders() {
        XCTAssertEqual(L10n(lang: .en)(.by, ["author": "Ann"]), "by Ann")
        XCTAssertEqual(L10n(lang: .de)(.confirmStartQ, ["printer": "CC"]), "Druck auf CC jetzt starten?")
    }

    func testTables() {
        let en = L10n(lang: .en), de = L10n(lang: .de)
        XCTAssertEqual(en.jobState("sliced"), "Ready")
        XCTAssertEqual(de.jobState("sliced"), "Bereit")
        XCTAssertEqual(de.plate("Textured PEI Plate"), "Texturierte PEI")
        XCTAssertEqual(en.printerKind("offline"), "Not reachable")
        XCTAssertEqual(de.rawState("preheating"), "Aufheizen")
        XCTAssertEqual(en.jobState("brand-new"), "brand-new")
        XCTAssertEqual(en.suggestions.count, 6)
    }

    func testResolve() {
        XCTAssertEqual(L10n.resolve(.auto, preferred: ["de-DE"]), .de)
        XCTAssertEqual(L10n.resolve(.auto, preferred: ["fr-FR"]), .en)
        XCTAssertEqual(L10n.resolve(.auto, preferred: []), .en)
        XCTAssertEqual(L10n.resolve(.de, preferred: ["en-US"]), .de)
        XCTAssertEqual(L10n.resolve(.en, preferred: ["de-DE"]), .en)
    }

    func testTranslateLog() {
        let de = L10n(lang: .de), en = L10n(lang: .en)
        XCTAssertEqual(de.translateLog("Downloading benchy.stl"), "Download: benchy.stl")
        XCTAssertEqual(de.translateLog("Sending to printer and starting"), "Wird gesendet und gestartet")
        XCTAssertEqual(de.translateLog("Sending to printer"), "Wird gesendet")
        XCTAssertEqual(de.translateLog("something else"), "something else")
        XCTAssertEqual(en.translateLog("Downloading benchy.stl"), "Downloading benchy.stl")
    }
}
