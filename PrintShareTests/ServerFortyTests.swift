import XCTest
@testable import PrintShare

/// Server 0.40.0: prints started on the printer itself (OrcaSlicer straight to the printer …) as jobs of kind
/// "external", and "always make a time-lapse". Shapes from the server's `docs/API.md` and `tests/test_jobtrack.py`.
final class ServerFortyTests: XCTestCase {
    private func client() -> APIClient {
        APIClient(server: Server(url: "http://home.test:8484", token: "tok"), l10n: L10n(lang: .en),
                  session: StubProtocol.session(), cache: RouteCache())
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

    func testExternalJobDecodes() throws {
        let job = try JSONDecoder().decode(Job.self, from: Data(#"""
        {"id": "e1", "kind": "external", "state": "started", "log": ["Started on the printer, not through PocketPrint3D"],
         "result": null, "error": null, "created": 1700000000.5, "printer": "cc",
         "request": {"link": null, "printer": "cc", "source": "printer"}, "owner": "local",
         "printer_file": "orca_cube.gcode", "started_at": 1700000000.5, "seen_printing": true, "progress": 12.3,
         "timelapse": {"state": "recording", "frames": 0}}
        """#.utf8))
        XCTAssertTrue(job.isExternal)
        XCTAssertNil(job.result)
        XCTAssertEqual(job.request.link, "")
        XCTAssertEqual(job.printer, "cc")
        XCTAssertEqual(job.printerFile, "orca_cube.gcode")
        XCTAssertEqual(job.progress, 12.3)
        XCTAssertEqual(job.timelapse?.state, .recording)

        let list = try JSONDecoder().decode([JobSummary].self, from: Data(#"""
        [{"id": "e1", "kind": "external", "state": "started", "error": null, "created": 1700000000.5, "printer": "cc",
          "link": null, "file": "orca_cube.gcode", "print_time": null, "filament_g": null, "progress": 60},
         {"id": "j1", "kind": "prepare", "state": "sliced", "error": null, "created": 1, "printer": "cc",
          "link": "https://www.printables.com/model/1-cube", "file": "cube.stl", "print_time": "1m", "filament_g": 1.5}]
        """#.utf8))
        XCTAssertTrue(list[0].isExternal)
        XCTAssertEqual(list[0].progress, 60)
        XCTAssertEqual(Format.jobName(file: list[0].file, link: list[0].link), "orca_cube.gcode")
        XCTAssertFalse(list[1].isExternal)
        XCTAssertNil(list[1].progress)                      // servers before 0.40.0 don't send it
    }

    func testTimelapseChoiceIsAlwaysExplicitAndTheSettingRequests() async throws {
        let lock = NSLock()
        var seen: [URLRequest] = []
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            if req.url?.path == "/api/timelapse/config" {
                return StubResponse(body: Data(#"{"always": true}"#.utf8))
            }
            return StubResponse(body: Data("{}".utf8))
        }
        let api = client()
        try await api.send(job: "j1", start: true, timelapse: false)   // 0: switched off for this print
        try await api.send(job: "j1", start: true)                     // 1: no choice = the server's setting
        try await api.send(job: "j1", start: false, timelapse: true)   // 2: upload only: never a time-lapse
        let got = try await api.timelapseConfig()                      // 3
        let set = try await api.setTimelapseConfig(always: true)       // 4

        lock.lock(); let r = seen; lock.unlock()
        XCTAssertEqual(body(r[0])?["timelapse"] as? Bool, false)
        XCTAssertNotNil(body(r[0])?["timelapse"])
        XCTAssertNil(body(r[1])?["timelapse"])
        XCTAssertNil(body(r[2])?["timelapse"])
        XCTAssertEqual(r[3].httpMethod, "GET")
        XCTAssertEqual(r[3].url?.path, "/api/timelapse/config")
        XCTAssertEqual(got, TimelapseConfig(always: true))
        XCTAssertEqual(r[4].httpMethod, "PUT")
        XCTAssertEqual(body(r[4])?["always"] as? Bool, true)
        XCTAssertEqual(set.always, true)
    }
}
