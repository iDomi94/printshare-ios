import CryptoKit
import XCTest
@testable import PrintShare

/// Server 0.51.0: push notifications through the relay, Live Activities, jobs waiting for a decision. Shapes from the
/// server's `docs/API.md`; the encrypted payload below is real output of `printshare.push.notify.encrypt`.
final class ServerFiftyOneTests: XCTestCase {
    private func client() -> APIClient {
        APIClient(server: Server(url: "http://home.test:8484", token: "tok"), l10n: L10n(lang: .en),
                  session: StubProtocol.session(), cache: RouteCache())
    }

    func testDecryptsTheServersNotification() throws {
        let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
        let blob = "MzTJkybLmhdAQHCJJ9W4y7z65H6EuaKEDbqSLh86P0h93+TxXh+gCdn3NoPVLjpjuJePawcA2IgvX6BFTxaePwJId6bt7u+vLRpgZ/XKP+eDx6C+V1o8ZGQhIhfS9dizFiCC9nVZXRbxYT0ufXU8TXVPnmRNYGybEPHWCgExLjMTfkDhcZIid2GB78FA/6HclhV0TuZjp0/MYvRw"
        let msg = try XCTUnwrap(PushPayload.open(blob, key: key))
        XCTAssertEqual(msg, PushPayload(event: "decision", title: "Falsches Material im Slot", body: "Slot 2 hat PETG statt PLA.",
                                        job: "j1", printer: "cos"))
        XCTAssertEqual(msg.userInfo, ["event": "decision", "job": "j1", "printer": "cos"])
        // another phone's key, or a broken blob: nothing (iOS shows the fallback text)
        XCTAssertNil(PushPayload.open(blob, key: Data(repeating: 7, count: 32).base64EncodedString()))
        XCTAssertNil(PushPayload.open("bm9wZQ==", key: key))
    }

    func testRoundTripWithCryptoKit() throws {
        let key = SymmetricKey(size: .bits256)
        let keyB64 = key.withUnsafeBytes { Data($0) }.base64EncodedString()
        let plain = try JSONEncoder().encode(PushPayload(event: "finished", title: "Druck fertig", body: "x", job: nil, printer: nil))
        let blob = try XCTUnwrap(ChaChaPoly.seal(plain, using: key).combined).base64EncodedString()
        XCTAssertEqual(PushPayload.open(blob, key: keyB64)?.title, "Druck fertig")
        XCTAssertEqual(PushPayload.open(blob, key: keyB64)?.userInfo, ["event": "finished"])
    }

    func testActivityStateUsesTheServersKeys() throws {
        let state = try JSONDecoder().decode(PrintActivityAttributes.ContentState.self, from: Data(#"""
        {"s": "printing", "p": 42, "end": 1762790000, "l": 84, "lt": 240}
        """#.utf8))
        XCTAssertEqual(state, PrintActivityAttributes.ContentState(s: "printing", p: 42, end: 1762790000, l: 84, lt: 240))
        XCTAssertEqual(state.progress, 0.42, accuracy: 0.0001)
        XCTAssertFalse(state.isOver)
        let done = try JSONDecoder().decode(PrintActivityAttributes.ContentState.self, from: Data(#"{"s": "done", "p": 100}"#.utf8))
        XCTAssertTrue(done.isOver)
        let attrs = try JSONDecoder().decode(PrintActivityAttributes.self, from: Data(#"{"job": "abc123", "printer": "dom"}"#.utf8))
        XCTAssertEqual(attrs, PrintActivityAttributes(job: "abc123", printer: "dom"))
        XCTAssertEqual(String(describing: PrintActivityAttributes.self), "PrintActivityAttributes",
                       "the server's push-to-start names this type")
    }

    func testJobWaitingForADecision() throws {
        let job = try JSONDecoder().decode(Job.self, from: Data(#"""
        {"id": "j1", "state": "needs_decision", "request": {"link": "upload:x"},
         "slot_problems": [{"tool": 1, "lane": "CANVAS_2", "problem": "material", "expected": "PLA", "found": "PETG"}],
         "decision": {"until": 1762790000.5,
                      "problems": [{"tool": 1, "lane": "CANVAS_2", "problem": "material", "expected": "PLA", "found": "PETG"}]}}
        """#.utf8))
        XCTAssertEqual(job.state, .needsDecision)
        XCTAssertTrue(job.state.isWorking, "the job screen keeps polling while it waits")
        XCTAssertEqual(job.decision?.until, 1762790000.5)
        XCTAssertEqual(job.decision?.problems.first?.found, "PETG")
    }

    func testPushInfoDecodes() throws {
        let info = try JSONDecoder().decode(PushInfo.self, from: Data(#"""
        {"relay": "https://api.pocketprint3d.com", "relay_here": false, "available": true,
         "groups": ["decisions", "done", "info", "problems", "activities"],
         "defaults": {"done": true}, "devices": [{"id": "d1", "name": "iPhone", "platform": "ios", "lang": "de",
         "prefs": {"done": true, "problems": true, "decisions": true, "info": false, "activities": true, "muted": []},
         "live_activities": true, "created": 1, "last_ok": null, "last_error": null}]}
        """#.utf8))
        XCTAssertEqual(info.relay, "https://api.pocketprint3d.com")
        XCTAssertFalse(info.relayHere)
        XCTAssertEqual(info.devices.first?.id, "d1")
        XCTAssertTrue(info.devices.first?.liveActivities == true)
        XCTAssertFalse(info.devices.first?.prefs.info ?? true)
        let cloud = try JSONDecoder().decode(PushInfo.self, from: Data(#"{"relay": null, "relay_here": true, "devices": []}"#.utf8))
        XCTAssertNil(cloud.relay)
        XCTAssertTrue(cloud.relayHere)
    }

    func testDecisionAndPushRequests() async throws {
        let lock = NSLock()
        var seen: [URLRequest] = []
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            if req.url?.path.hasPrefix("/api/push/devices") == true, req.httpMethod != "DELETE" {
                return StubResponse(body: Data(#"{"id": "d1", "name": "iPhone", "prefs": {"info": true}, "live_activities": false}"#.utf8))
            }
            return StubResponse(body: Data(#"{"ok": true}"#.utf8))
        }
        let api = client()
        try await api.decide(job: "j1", start: true)
        try await api.decide(job: "j1", start: false)
        let handle = PushHandle(handle: "pp3dp_abc", secret: "s3cr3t")
        let dev = try await api.addPushDevice(handle, key: "a2V5", lang: "de", name: "iPhone", prefs: nil)
        XCTAssertTrue(dev.prefs.info)
        _ = try await api.updatePushDevice(id: "d1", PushDeviceUpdate(startHandle: "pp3dp_start", startSecret: "x"))
        try await api.registerLiveActivity(job: "j1", handle, device: "d1")

        let r = lock.withLock { seen }
        XCTAssertEqual(r[0].url?.path, "/api/jobs/j1/decision")
        XCTAssertEqual(body(r[0])?["action"] as? String, "start")
        XCTAssertEqual(body(r[0])?["confirm"] as? Bool, true, "start only after the app's confirmation (NF-05)")
        XCTAssertEqual(body(r[1])?["action"] as? String, "abort")
        XCTAssertEqual(body(r[1])?["confirm"] as? Bool, false)
        let add = try XCTUnwrap(body(r[2]))
        XCTAssertEqual(add["handle"] as? String, "pp3dp_abc")
        XCTAssertEqual(add["key"] as? String, "a2V5")
        XCTAssertEqual(add["platform"] as? String, "ios")
        let upd = try XCTUnwrap(body(r[3]))
        XCTAssertEqual(r[3].httpMethod, "PUT")
        XCTAssertEqual(upd["start_handle"] as? String, "pp3dp_start")
        XCTAssertNil(upd["prefs"], "only the sent fields change")
        XCTAssertEqual(r[4].url?.path, "/api/jobs/j1/live-activity")
        XCTAssertEqual(body(r[4])?["device"] as? String, "d1")
    }

    func testJobDeepLink() {
        XCTAssertEqual(DeepLink.parse(URL(string: "printshare://job?id=ab12cd")!), .job("ab12cd"))
        XCTAssertEqual(DeepLink.parse(URL(string: "printshare://job?id=../x")!), .other)
        XCTAssertEqual(DeepLink.parse(URL(string: "printshare://job")!), .other)
    }

    func testTokenHex() {
        XCTAssertEqual(Data([0x00, 0xAB, 0x10]).hexString, "00ab10")
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
