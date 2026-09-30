import XCTest
@testable import PrintShare

final class MJPEGTests: XCTestCase {
    func testParserCutsFramesOutOfTheMultipartStream() {
        let frame1: [UInt8] = [0xFF, 0xD8, 0x01, 0xFF, 0x00, 0x02, 0xFF, 0xD9]
        let frame2: [UInt8] = [0xFF, 0xD8, 0x03, 0xFF, 0xD9]
        let header = Array("--boundary\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        let stream = header + frame1 + Array("\r\n".utf8) + header + frame2 + header + [0xFF, 0xD8, 0x04]  // cut off
        var parser = MJPEG.Parser()
        let frames = stream.compactMap { parser.feed($0) }
        XCTAssertEqual(frames, [Data(frame1), Data(frame2)])
    }

    func testParserDropsOversizedFrames() {
        var parser = MJPEG.Parser()
        parser.limit = 4
        let frames = ([0xFF, 0xD8, 1, 2, 3, 4, 0xFF, 0xD9] as [UInt8]).compactMap { parser.feed($0) }
        XCTAssertTrue(frames.isEmpty)
    }

    func testFramesArriveThroughTheSessionDelegate() async throws {
        let header = Array("--boundarydonotcross\r\nContent-Type: image/jpeg\r\n\r\n".utf8)
        let frame: [UInt8] = [0xFF, 0xD8, 0x07, 0xFF, 0xD9]
        StubProtocol.install { _ in StubResponse(body: Data(header + frame + header + frame)) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        var got: [Data] = []
        for try await f in MJPEG.frames(URLRequest(url: URL(string: "http://home.test/stream")!), configuration: cfg) {
            got.append(f)
        }
        XCTAssertEqual(got, [Data(frame), Data(frame)])
    }

    func testStreamErrorStatusFails() async {
        StubProtocol.install { _ in StubResponse(status: 502, body: Data("{}".utf8)) }
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        do {
            for try await _ in MJPEG.frames(URLRequest(url: URL(string: "http://home.test/stream")!), configuration: cfg) {}
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .badServerResponse)
        }
    }
}
