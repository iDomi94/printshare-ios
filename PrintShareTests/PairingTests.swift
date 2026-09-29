import XCTest
@testable import PrintShare

final class PairingTests: XCTestCase {
    func testNormalizeUrl() {
        XCTAssertEqual(normalizeUrl("  192.168.1.10:8484/ "), "http://192.168.1.10:8484")
        XCTAssertEqual(normalizeUrl("https://tower.ts.net//"), "https://tower.ts.net")
        XCTAssertEqual(normalizeUrl("HTTP://x"), "HTTP://x")
        XCTAssertEqual(normalizeUrl(""), "")
        XCTAssertEqual(normalizeUrl("   "), "")
    }

    func testParseWithoutRemote() {
        let s = Pairing.parse("printshare://connect?url=http%3A%2F%2F192.168.1.10%3A8484&token=abc123")
        XCTAssertEqual(s, Server(url: "http://192.168.1.10:8484", token: "abc123", remoteUrl: nil))
    }

    func testParseWithRemote() {
        let s = Pairing.parse("printshare://connect?url=http://10.0.0.5:8484&token=t&remote=100.64.0.1:8484")
        XCTAssertEqual(s?.url, "http://10.0.0.5:8484")
        XCTAssertEqual(s?.remoteUrl, "http://100.64.0.1:8484")
        XCTAssertEqual(s?.token, "t")
    }

    func testParseIsCaseInsensitiveAndTrims() {
        XCTAssertNotNil(Pairing.parse("  PrintShare://Connect?url=x.local  "))
    }

    func testParseAcceptsExtraSlashes() {
        XCTAssertEqual(Pairing.parse("printshare:///connect?url=x.local&token=1")?.url, "http://x.local")
    }

    func testParseDecodesPlusAndPercent() {
        XCTAssertEqual(Pairing.parse("printshare://connect?url=x.local&token=a+b%2Bc")?.token, "a b+c")
    }

    func testParseRejectsOtherInput() {
        XCTAssertNil(Pairing.parse("https://connect?url=x"))
        XCTAssertNil(Pairing.parse("printshare://share"))
        XCTAssertNil(Pairing.parse("printshare://connect?token=only"))
        XCTAssertNil(Pairing.parse("hello"))
    }

    func testDeepLink() {
        XCTAssertEqual(DeepLink.parse(URL(string: "printshare://share")!), .share)
        XCTAssertEqual(DeepLink.parse(URL(string: "https://example.com")!), .other)
        if case .connect(let s) = DeepLink.parse(URL(string: "printshare://connect?url=x.local&token=t")!) {
            XCTAssertEqual(s.url, "http://x.local")
        } else {
            XCTFail("expected connect")
        }
    }

    func testSharedInboxRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(SharedInbox.peek(in: root))
        let src = root.appendingPathComponent("in.stl")
        try Data("solid".utf8).write(to: src)
        let rel = try SharedInbox.stage(fileAt: src, name: "part.stl", in: root)
        try SharedInbox.write(SharedItem(file: rel, fileName: "part.stl"), in: root)
        let item = SharedInbox.peek(in: root)
        XCTAssertEqual(item?.fileName, "part.stl")
        let url = SharedInbox.fileURL(item?.file ?? "", in: root)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(url)), Data("solid".utf8))
        SharedInbox.clear(in: root)
        XCTAssertNil(SharedInbox.peek(in: root))
    }
}
