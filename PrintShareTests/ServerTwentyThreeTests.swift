import XCTest
@testable import PrintShare

/// Server 0.18.0-0.23.0: Orca Cloud import, SpoolmanDB presets, Manyfold, AI failure detection, MakerWorld card.
/// Shapes from the server's `docs/API.md` and the Expo app's `lib/api.ts` (upstream c9f9123).
final class ServerTwentyThreeTests: XCTestCase {
    private let l = L10n(lang: .en)

    private func client() -> APIClient {
        APIClient(server: Server(url: "http://home.test:8484", token: "tok"), l10n: l, session: StubProtocol.session(),
                  cache: RouteCache())
    }

    private func body(_ req: URLRequest) -> [String: Any]? {
        var data = req.httpBody
        if data == nil, let stream = req.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buf = [UInt8](repeating: 0, count: 4096)
            var out = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                out.append(buf, count: n)
            }
            data = out
        }
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
    }

    // MARK: decoding

    func testWatchStateInStatus() throws {
        let st = try JSONDecoder().decode(PrinterStatus.self, from: Data(#"""
        {"kind": "active", "watch": {"state": "alert", "score": 0.61, "threshold": 0.55, "frames": 40,
         "last_check": 1759400000.5, "alerted_at": 1759400000.5, "paused": true, "action": "pause", "error": null,
         "frame": true}}
        """#.utf8))
        let w = try XCTUnwrap(st.watch)
        XCTAssertEqual(w.state, .alert)
        XCTAssertTrue(w.paused)
        XCTAssertTrue(w.frame)
        XCTAssertEqual(w.lastCheck, 1759400000.5)
        let unknown = try JSONDecoder().decode(WatchState.self, from: Data(#"{"state": "dreaming"}"#.utf8))
        XCTAssertEqual(unknown.state, .idle)
        XCTAssertNil(try JSONDecoder().decode(PrinterStatus.self, from: Data(#"{"kind": "idle"}"#.utf8)).watch)
    }

    func testWatchLine() {
        XCTAssertNil(WatchInfo.line(l, WatchState(state: .idle)))
        XCTAssertNil(WatchInfo.line(l, WatchState(state: .alert)))
        XCTAssertEqual(WatchInfo.line(l, WatchState(state: .watching)), l(.watchActive))
        XCTAssertEqual(WatchInfo.line(l, WatchState(state: .warming)), l(.watchWarming))
        XCTAssertEqual(WatchInfo.line(l, WatchState(state: .watching, error: "ML API down")),
                       l(.watchError, ["error": "ML API down"]))
    }

    func testConfigsAndPresets() throws {
        let f = try JSONDecoder().decode(FailureConfig.self, from: Data(#"""
        {"configured": true, "ml_url": "http://ml:3333", "token_set": false, "server_url": "http://ps:8484",
         "interval": 10, "sensitivity": "high", "action": "pause", "test": {"detections": 0}}
        """#.utf8))
        XCTAssertEqual(f.mlUrl, "http://ml:3333")
        XCTAssertEqual(f.sensitivity, "high")
        XCTAssertEqual(f.testDetections, 0)
        let m = try JSONDecoder().decode(ManyfoldConfig.self, from: Data(#"{"configured": true, "url": "http://mf", "models": 61}"#.utf8))
        XCTAssertTrue(m.tokenSet)
        XCTAssertEqual(m.models, 61)
        let p = try JSONDecoder().decode([FilamentPreset].self, from: Data(#"""
        [{"id": "x", "name": "Red", "material": "PLA", "color_hex": "EA140E", "color_hexes": null, "density": 1.26,
          "extruder_temp": 210, "bed_temp": 60, "finish": null, "translucent": false, "glow": false,
          "weights": [{"weight": 1000, "spool_weight": 154}], "diameter": 1.75}]
        """#.utf8))
        XCTAssertEqual(p[0].weights.first?.spoolWeight, 154)
        XCTAssertEqual(SpoolFormView.choices(p), [Choice(value: "0", label: "Red", group: "PLA", sub: "1000 g · 210 °C")])
        let o = try JSONDecoder().decode(OrcaCloudImport.self, from: Data(#"""
        {"bundle": {"name": "AFC", "author": "d", "version": "1", "updated": null},
         "imported": [{"file": "machine-AFC.json", "kind": "machine", "name": "AFC", "inherits": "Elegoo Centauri Carbon 0.4 nozzle"},
                      {"file": "filament-X.json", "kind": "filament", "name": "X", "inherits": "Elegoo PLA @ECC"}],
         "skipped": [{"name": "Y", "error": "unknown base"}]}
        """#.utf8))
        XCTAssertEqual(o.imported.count, 2)
        XCTAssertEqual(PrinterProfileView.fittingMachine(o.imported, machine: "Elegoo Centauri Carbon 0.4 nozzle")?.file,
                       "machine-AFC.json")
        XCTAssertNil(PrinterProfileView.fittingMachine(o.imported, machine: "Prusa MK4"))
        XCTAssertTrue(PrinterProfileView.isOrcaLink("https://cloud.orcaslicer.com/b/3fad3c38f25f"))
        XCTAssertFalse(PrinterProfileView.isOrcaLink("https://orcaslicer.com"))
    }

    func testManyfoldHitUsesItsLink() throws {
        let h = try JSONDecoder().decode(ModelHit.self, from: Data(#"""
        {"source": "manyfold", "id": "12", "name": "Gear", "url": "http://mf/models/12", "link": "manyfold:12",
         "thumbnail": "/api/manyfold/image/12/3"}
        """#.utf8))
        XCTAssertEqual(h.sliceLink, "manyfold:12")
        let p = try JSONDecoder().decode(ModelHit.self, from: Data(#"{"source": "printables", "id": 1, "url": "https://p/1"}"#.utf8))
        XCTAssertEqual(p.sliceLink, "https://p/1")
    }

    // MARK: requests

    func testRequestBodies() async throws {
        var seen: [URLRequest] = []
        let lock = NSLock()
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            switch req.url?.path ?? "" {
            case "/api/manyfold/config": return StubResponse(body: Data(#"{"configured": true, "url": "http://mf", "models": 3}"#.utf8))
            case "/api/failure-detection/config": return StubResponse(body: Data(#"{"configured": true, "sensitivity": "low"}"#.utf8))
            case "/api/printers/cc/watch/mute": return StubResponse(body: Data(#"{"state": "muted"}"#.utf8))
            case "/api/profiles/orca-cloud": return StubResponse(body: Data(#"{"bundle": {}, "imported": [], "skipped": []}"#.utf8))
            default: return StubResponse(body: Data("[]".utf8))
            }
        }
        let api = client()
        _ = try await api.setManyfold(url: "http://mf", token: nil)
        _ = try await api.setManyfold(url: "http://mf", token: "k")
        _ = try await api.setFailureConfig(mlUrl: "http://ml:3333", mlToken: nil, serverUrl: "http://ps:8484",
                                           sensitivity: "low", action: "notify")
        let muted = try await api.muteWatch(printer: "cc")
        _ = try await api.importOrcaCloud(link: "https://cloud.orcaslicer.com/b/abc")
        _ = try await api.filamentPresets(brand: "Bambu Lab")
        let image = await api.imageURL("/api/manyfold/image/12/3")
        let outside = await api.imageURL("https://media.printables.com/x.jpg")

        lock.lock(); let r = seen; lock.unlock()
        XCTAssertEqual(r[0].httpMethod, "PUT")
        XCTAssertNil(body(r[0])?["token"])                         // left out = keep the stored key
        XCTAssertEqual(body(r[1])?["token"] as? String, "k")
        let f = try XCTUnwrap(body(r[2]))
        XCTAssertEqual(f["ml_url"] as? String, "http://ml:3333")
        XCTAssertNil(f["ml_token"])
        XCTAssertEqual(f["server_url"] as? String, "http://ps:8484")
        XCTAssertEqual(muted.state, .muted)
        XCTAssertEqual(r[3].httpMethod, "POST")
        XCTAssertEqual(body(r[4])?["link"] as? String, "https://cloud.orcaslicer.com/b/abc")
        XCTAssertEqual(r[5].url?.query, "brand=Bambu%20Lab")
        XCTAssertEqual(image?.absoluteString, "http://home.test:8484/api/manyfold/image/12/3?token=tok")
        XCTAssertEqual(outside?.absoluteString, "https://media.printables.com/x.jpg")
    }

    func testSpoolFromDatabaseSendsDensityAndSpoolWeight() throws {
        var input = SpoolInput(filament: .init(name: "Red", vendor: "ELEGOO", material: "PLA", colorHex: "#EA140E",
                                               weight: 1000, density: 1.26),
                               remainingWeight: nil, location: nil, comment: nil, archived: nil, spoolWeight: 154)
        var b = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        XCTAssertEqual((b["filament"] as? [String: Any])?["density"] as? Double, 1.26)
        XCTAssertEqual(b["spool_weight"] as? Double, 154)
        input.filament?.density = nil
        input.spoolWeight = nil
        b = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any])
        XCTAssertNil((b["filament"] as? [String: Any])?["density"])
        XCTAssertNil(b["spool_weight"])
    }
}
