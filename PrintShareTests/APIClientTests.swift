import XCTest
@testable import PrintShare

final class APIClientTests: XCTestCase {
    private let l = L10n(lang: .en)
    private let infoBody = (try? Fixture.data("info")) ?? Data()

    private func client(remote: Bool = true, cache: RouteCache = RouteCache()) -> APIClient {
        APIClient(server: Server(url: "http://home.test:8484", token: "tok",
                                 remoteUrl: remote ? "http://remote.test:8484" : nil),
                  l10n: l, session: StubProtocol.session(), cache: cache)
    }

    func testProbePicksTheFasterAddress() async throws {
        let body = infoBody
        StubProtocol.install { req in
            req.url?.host == "home.test" ? StubResponse(body: body, delay: 0.6) : StubResponse(body: body)
        }
        let api = client()
        _ = try await api.info()
        let route = await api.route()
        XCTAssertEqual(route, .remote)
        // the real request went to the address that won
        XCTAssertEqual(StubProtocol.requests.last?.host, "remote.test")
    }

    func testAnyAnswerWinsTheProbeEvenUnauthorized() async throws {
        let body = infoBody
        StubProtocol.install { req in
            req.url?.host == "home.test" ? StubResponse(status: 401, body: Data("{\"detail\":\"invalid token\"}".utf8))
                                         : StubResponse(body: body, delay: 0.5)
        }
        let api = client()
        do {
            _ = try await api.info()
            XCTFail("expected 401")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 401)
            XCTAssertEqual(e.message, l(.errToken))
            XCTAssertEqual(e.detail, "invalid token")
        }
        let route = await api.route()
        XCTAssertEqual(route, .home)
    }

    func testSingleAddressSkipsProbe() async throws {
        let body = infoBody
        StubProtocol.install { _ in StubResponse(body: body) }
        let api = client(remote: false)
        _ = try await api.info()
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    /// Home answers first, then disappears (left the house): a GET moves over to the away address.
    func testGetIsRetriedOnTheOtherAddress() async throws {
        let body = infoBody
        let homeUp = Flag(true)
        StubProtocol.install { req in
            if req.url?.host == "home.test" {
                return homeUp.value ? StubResponse(body: body) : StubResponse(error: URLError(.cannotConnectToHost))
            }
            return StubResponse(body: body, delay: 0.3)
        }
        let api = client()
        _ = try await api.info()
        var route = await api.route()
        XCTAssertEqual(route, .home)

        homeUp.value = false
        let info = try await api.info()
        XCTAssertEqual(info.name, "PrintShare")
        route = await api.route()
        XCTAssertEqual(route, .remote)
        XCTAssertTrue(StubProtocol.requests.contains(LoggedRequest(method: "GET", host: "remote.test", path: "/api/info")))
    }

    func testPostIsNeverRepeated() async throws {
        let body = infoBody
        let homeUp = Flag(true)
        StubProtocol.install { req in
            if req.url?.host == "home.test" {
                return homeUp.value ? StubResponse(body: body) : StubResponse(error: URLError(.cannotConnectToHost))
            }
            return StubResponse(body: body, delay: 0.3)
        }
        let api = client()
        _ = try await api.info()
        homeUp.value = false
        do {
            _ = try await api.createJob(link: "https://x.test/m", printer: "p", file: nil, options: JobOptions())
            XCTFail("expected an error")
        } catch let e as APIError {
            XCTAssertEqual(e.message, l(.errOffline))
        }
        let posts = StubProtocol.requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 1, "a print start or new job must not be sent twice")
        XCTAssertEqual(posts.first?.host, "home.test")
        // the next read uses the address that works now
        let route = await api.route()
        XCTAssertEqual(route, .remote)
    }

    func testTimeoutMessage() async {
        StubProtocol.install { _ in StubResponse(error: URLError(.timedOut)) }
        do {
            _ = try await client(remote: false).info()
            XCTFail("expected timeout")
        } catch let e as APIError {
            XCTAssertEqual(e.message, l(.errTimeout))
            XCTAssertEqual(e.status, 0)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testOfflineMessage() async {
        StubProtocol.install { _ in StubResponse(error: URLError(.notConnectedToInternet)) }
        do {
            _ = try await client(remote: false).info()
            XCTFail("expected error")
        } catch let e as APIError {
            XCTAssertEqual(e.message, l(.errOffline))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testServerDetailBecomesFriendlyMessage() async {
        StubProtocol.install { _ in StubResponse(status: 409, body: Data("{\"detail\":\"printer is busy - wait\"}".utf8)) }
        do {
            _ = try await client(remote: false).send(job: "j", start: true)
            XCTFail("expected error")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 409)
            XCTAssertEqual(e.message, l(.errBusy))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testValidationErrorFallsBackToHTTPStatus() async {
        StubProtocol.install { _ in StubResponse(status: 422, body: Data("{\"detail\":[{\"msg\":\"x\"}]}".utf8)) }
        do {
            _ = try await client(remote: false).jobs()
            XCTFail("expected error")
        } catch let e as APIError {
            XCTAssertEqual(e.detail, "HTTP 422")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testRequestShape() async throws {
        var requestsSeen: [URLRequest] = []
        let lock = NSLock()
        let opts = try Fixture.data("options")
        StubProtocol.install { req in
            lock.lock(); requestsSeen.append(req); lock.unlock()
            return StubResponse(body: req.url?.path.hasSuffix("/options") == true ? opts : Data("{\"ok\":true}".utf8))
        }
        let api = client(remote: false)
        _ = try await api.options(printer: "centauri carbon", process: "0.20mm Standard @Elegoo")
        try await api.control(printer: "cc", action: "cancel")
        try await api.send(job: "j1", start: true)

        let seen = lock.withLock { requestsSeen }
        XCTAssertEqual(seen[0].url?.absoluteString,
                       "http://home.test:8484/api/printers/centauri%20carbon/options?process=0.20mm%20Standard%20%40Elegoo")
        XCTAssertEqual(seen[0].value(forHTTPHeaderField: "Authorization"), "Bearer tok")
        XCTAssertEqual(seen[0].timeoutInterval, 30)
        XCTAssertEqual(seen[1].httpMethod, "POST")
        XCTAssertEqual(seen[1].value(forHTTPHeaderField: "Content-Type"), "application/json")
        let control = try XCTUnwrap(bodyJSON(seen[1]))
        XCTAssertEqual(control["action"] as? String, "cancel")
        XCTAssertEqual(control["confirm"] as? Bool, true)
        let send = try XCTUnwrap(bodyJSON(seen[2]))
        XCTAssertEqual(send["start"] as? Bool, true)
        XCTAssertEqual(send["confirm"] as? Bool, true)
        XCTAssertNil(send["level"])
    }

    func testUploadIsRawBody() async throws {
        let up = try Fixture.data("upload")
        var uploadType: String?
        let lock = NSLock()
        StubProtocol.install { req in
            lock.lock(); uploadType = req.value(forHTTPHeaderField: "Content-Type"); lock.unlock()
            return StubResponse(body: up)
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("part-\(UUID().uuidString).stl")
        try Data("solid x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try await client(remote: false).upload(fileURL: file, name: "my part.stl")
        XCTAssertEqual(result.link, "upload:0123456789ab")
        let contentType = lock.withLock { uploadType }
        XCTAssertEqual(contentType, "application/octet-stream")
        XCTAssertEqual(StubProtocol.requests.last?.path, "/api/uploads")
    }

    func testCheckServerNormalisesAddresses() async throws {
        let body = infoBody
        StubProtocol.install { _ in StubResponse(body: body) }
        let s = try await Pairing.check(Server(url: " home.test:8484/ ", token: " tok ", remoteUrl: "  "), l,
                                        session: StubProtocol.session(), cache: RouteCache())
        XCTAssertEqual(s, Server(url: "http://home.test:8484", token: "tok", remoteUrl: nil))
    }

    private func bodyJSON(_ req: URLRequest) -> [String: Any]? {
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
        return data.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
    }
}

/// Mutable flag shared with the stub's background queue.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Bool
    init(_ value: Bool) { stored = value }
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
