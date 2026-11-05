import XCTest
@testable import PrintShare

/// Server 0.48.0 (key for "Open in PocketPrint3D" from a CAD program) and 0.49.0 (inbox folder). Shapes from the
/// server's `docs/API.md`.
final class ServerFortyNineTests: XCTestCase {
    private func client() -> APIClient {
        APIClient(server: Server(url: "http://home.test:8484", token: "tok"), l10n: L10n(lang: .en),
                  session: StubProtocol.session(), cache: RouteCache())
    }

    func testImportKeyDecodesOwnServerAndCloud() throws {
        let own = try JSONDecoder().decode(ImportKey.self, from: Data(#"""
        {"enabled": true, "url": "http://tower:8484", "server_token": true, "token_required": true}
        """#.utf8))
        XCTAssertTrue(own.serverToken)
        XCTAssertEqual(own.tokenRequired, true)
        XCTAssertNil(own.key)

        let cloud = try JSONDecoder().decode(ImportKey.self, from: Data(#"""
        {"enabled": true, "url": "https://api.pocketprint3d.com", "server_token": false, "created": 1700000000.5,
         "last_used": null, "key": "pp3dk_abc"}
        """#.utf8))
        XCTAssertFalse(cloud.serverToken)
        XCTAssertEqual(cloud.key, "pp3dk_abc")
        XCTAssertNil(cloud.lastUsed)

        // missing fields never break the screen
        let bare = try JSONDecoder().decode(ImportKey.self, from: Data(#"{"url": "http://x"}"#.utf8))
        XCTAssertFalse(bare.enabled)
    }

    func testInboxDecodes() throws {
        let box = try JSONDecoder().decode(Inbox.self, from: Data(#"""
        {"enabled": true, "items": [
          {"id": "a1", "name": "bracket.stl", "path": "parts/bracket.stl", "size": 20480, "modified": 1700000000,
           "found": 1700000005, "link": "upload:abc123"}]}
        """#.utf8))
        XCTAssertTrue(box.enabled)
        XCTAssertEqual(box.items.first?.link, "upload:abc123")
        XCTAssertEqual(box.items.first?.path, "parts/bracket.stl")

        let off = try JSONDecoder().decode(Inbox.self, from: Data(#"{"enabled": false, "items": []}"#.utf8))
        XCTAssertFalse(off.enabled)
        XCTAssertTrue(off.items.isEmpty)
    }

    func testImportAndInboxRequestShapes() async throws {
        let lock = NSLock()
        var seen: [URLRequest] = []
        StubProtocol.install { req in
            lock.lock(); seen.append(req); lock.unlock()
            if req.url?.path == "/api/import-key", req.httpMethod == "POST" {
                return StubResponse(body: Data(#"{"enabled": true, "url": "http://home.test:8484", "server_token": true, "key": "tok"}"#.utf8))
            }
            return StubResponse(body: Data(#"{"enabled": true, "items": [], "deleted": true, "removed": 1}"#.utf8))
        }
        let api = client()
        _ = try await api.importKey()
        let made = try await api.createImportKey()
        XCTAssertEqual(made.key, "tok")
        try await api.deleteImportKey()
        _ = try await api.inbox()
        try await api.dismissInbox(id: "a b")
        try await api.clearInbox()

        lock.lock(); let r = seen; lock.unlock()
        XCTAssertEqual(r.map { $0.httpMethod }, ["GET", "POST", "DELETE", "GET", "DELETE", "DELETE"])
        XCTAssertEqual(r[0].url?.path, "/api/import-key")
        XCTAssertEqual(r[3].url?.path, "/api/inbox")
        XCTAssertTrue(r[4].url?.absoluteString.contains("/api/inbox/a%20b") ?? false, r[4].url?.absoluteString ?? "")
        XCTAssertEqual(r[5].url?.path, "/api/inbox")
    }
}
