import XCTest
@testable import PrintShare

/// Server 0.50.0: print on a switched-off printer (`/send` `wake` with auto_on), slots last seen (`/lanes`), slot check before
/// the start (`expect`, `slot_problems`). Shapes from the server's `docs/API.md`.
final class ServerFiftyTests: XCTestCase {
    private func client() -> APIClient {
        APIClient(server: Server(url: "http://home.test:8484", token: "tok"), l10n: L10n(lang: .en),
                  session: StubProtocol.session(), cache: RouteCache())
    }

    func testPrinterDecodesAutoOn() throws {
        let p = try JSONDecoder().decode([Printer].self, from: Data(#"""
        [{"id": "cos", "name": "COSMOS", "type": "moonraker", "power": true, "auto_on": true},
         {"id": "cc", "name": "CC", "type": "elegoo_sdcp", "power": true}]
        """#.utf8))
        XCTAssertEqual(p.map(\.autoOn), [true, false])
    }

    func testKnownLanesDecode() throws {
        let off = try JSONDecoder().decode(KnownLanes.self, from: Data(#"""
        {"lanes": [{"id": "CANVAS_2", "tool": 1, "loaded": true, "material": "PLA", "color": "#E53935"},
                   {"id": "CANVAS_4", "tool": 0, "loaded": false, "material": null, "color": null}],
         "live": false, "seen_at": 1762785000.5, "kind": "offline"}
        """#.utf8))
        XCTAssertFalse(off.live)
        XCTAssertEqual(off.seenAt, 1762785000.5)
        XCTAssertEqual(off.lanes.map(\.tool), [1, 0])
        let never = try JSONDecoder().decode(KnownLanes.self, from: Data(#"{"lanes": [], "live": false, "seen_at": null}"#.utf8))
        XCTAssertTrue(never.lanes.isEmpty)
        XCTAssertNil(never.seenAt)
    }

    func testJobDecodesSlotProblems() throws {
        let job = try JSONDecoder().decode(Job.self, from: Data(#"""
        {"id": "j1", "state": "sliced", "error": "Not started: lane CANVAS_2 (T1) now holds material PETG instead of PLA",
         "slot_problems": [{"tool": 1, "lane": "CANVAS_2", "problem": "material", "expected": "PLA", "found": "PETG"}],
         "request": {"link": "upload:x"}}
        """#.utf8))
        XCTAssertEqual(job.slotProblems, [SlotProblem(tool: 1, lane: "CANVAS_2", problem: "material", expected: "PLA",
                                                      found: "PETG")])
        let none = try JSONDecoder().decode(Job.self, from: Data(#"{"id": "j2", "state": "started", "slot_problems": null}"#.utf8))
        XCTAssertNil(none.slotProblems)
    }

    func testSendWithPowerOnAndExpectedSlots() async throws {
        let lock = NSLock()
        var seen: [URLRequest] = []
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            if req.url?.path == "/api/printers/cos/lanes" { return StubResponse(status: 404, body: Data(#"{"detail":"Not Found"}"#.utf8)) }
            return StubResponse(body: Data(#"{"job": "j1"}"#.utf8))
        }
        let api = client()
        try await api.send(job: "j1", start: true, lanes: [1: 3], wake: true,
                           expect: [3: SlotExpect(material: "PLA")])
        try await api.send(job: "j1", start: false, lanes: [1: 3], wake: true, expect: [3: SlotExpect(material: "PLA")])
        let older = try await api.knownLanes(printer: "cos")
        XCTAssertNil(older, "older servers: no remembered slots, no error")

        let r = lock.withLock { seen }
        let start = try XCTUnwrap(body(r[0]))
        XCTAssertEqual(start["wake"] as? Bool, true)
        let expect = try XCTUnwrap(start["expect"] as? [String: [String: Any]])
        XCTAssertEqual(expect["3"]?["material"] as? String, "PLA")
        // an upload never switches on and checks nothing
        let upload = try XCTUnwrap(body(r[1]))
        XCTAssertNil(upload["wake"])
        XCTAssertNil(upload["expect"])
        XCTAssertEqual(r[2].url?.path, "/api/printers/cos/lanes")
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
        return data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
