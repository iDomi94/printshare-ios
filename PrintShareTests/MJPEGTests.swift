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
}
