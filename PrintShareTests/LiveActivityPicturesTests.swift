import XCTest
@testable import PrintShare

/// Server 0.54.0 / app 0.9.20: temperatures and the heating phase in the Live Activity, layer pictures picked by
/// layer, camera pictures in notifications. Payloads are real output of the server's `printshare.push.notify`.
final class LiveActivityPicturesTests: XCTestCase {
    func testActivityStateWithTemperaturesAndHeating() throws {
        let state = try JSONDecoder().decode(PrintActivityAttributes.ContentState.self, from: Data(#"""
        {"s": "printing", "p": 0, "l": 0, "lt": 80, "tn": 150, "tnt": 220, "tb": 60, "tbt": 60, "tc": 32, "h": 1}
        """#.utf8))
        XCTAssertTrue(state.heating)
        XCTAssertTrue(state.hasTemperatures)
        XCTAssertEqual(state.tn, 150)
        XCTAssertEqual(state.tnt, 220)
        XCTAssertEqual(state.tc, 32)
        XCTAssertEqual(state.frame, 0)
        // a state of an older server: no temperatures, not heating
        let old = try JSONDecoder().decode(PrintActivityAttributes.ContentState.self,
                                           from: Data(#"{"s": "printing", "p": 42}"#.utf8))
        XCTAssertFalse(old.heating)
        XCTAssertFalse(old.hasTemperatures)
    }

    func testFrameFollowsTheServersRule() {
        // notify.frame: l * 24 // lt, else p * 24 // 100
        XCTAssertEqual(PrintActivityAttributes.ContentState(s: "printing", p: 13, l: 50, lt: 100).frame, 12)
        XCTAssertEqual(PrintActivityAttributes.ContentState(s: "printing", p: 13, l: 17, lt: 100).frame, 4)
        XCTAssertEqual(PrintActivityAttributes.ContentState(s: "printing", p: 3).frame, 0)
        XCTAssertEqual(PrintActivityAttributes.ContentState(s: "printing", p: 50).frame, 12)
        XCTAssertEqual(PrintActivityAttributes.ContentState(s: "done", p: 100).frame, 24)
        XCTAssertEqual(PrintActivityAttributes.ContentState(s: "printing", p: 10, l: 500, lt: 100).frame, 24, "clamped")
    }

    func testLayerPictureUpTo() {
        XCTAssertEqual(ActivityPictures.upTo(frame: 0, layers: 240), -1, "nothing printed yet")
        XCTAssertEqual(ActivityPictures.upTo(frame: 12, layers: 240), 119)
        XCTAssertEqual(ActivityPictures.upTo(frame: 24, layers: 240), 239)
        XCTAssertEqual(ActivityPictures.upTo(frame: 1, layers: 10), 0, "short prints: at least the first layer")
    }

    func testFollowMapsThePrintersLayerOntoThePreview() {
        XCTAssertEqual(PreviewView.layerIndex(layer: 84, layers: 240, progress: 30, count: 240), 83)
        XCTAssertEqual(PreviewView.layerIndex(layer: 42, layers: 120, progress: nil, count: 240), 83, "other count")
        XCTAssertEqual(PreviewView.layerIndex(layer: nil, layers: nil, progress: 50, count: 100), 49, "by progress")
        XCTAssertEqual(PreviewView.layerIndex(layer: 0, layers: 100, progress: 0, count: 100), 0)
        XCTAssertEqual(PreviewView.layerIndex(layer: 300, layers: 100, progress: 0, count: 100), 99)
    }

    func testPicksTheLayerPictureOrAFreshCameraPicture() throws {
        let job = "test-\(UUID().uuidString.prefix(8))"
        guard let folder = ActivityImages.folder(job) else { throw XCTSkip("no App Group container in the unsigned CI") }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for n in [0, 4, 12] { try Data([1]).write(to: XCTUnwrap(ActivityImages.frameURL(job, n))) }
        let state = PrintActivityAttributes.ContentState(s: "printing", p: 30, l: 30, lt: 100)  // frame 7
        XCTAssertEqual(ActivityImages.pick(job: job, state: state, mode: .preview), .frame(try XCTUnwrap(ActivityImages.frameURL(job, 4))))
        XCTAssertNil(ActivityImages.pick(job: job, state: state, mode: .none))
        let cam = try XCTUnwrap(ActivityImages.cameraURL(job))
        try Data([2]).write(to: cam)
        let at = Date()
        try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: cam.path)
        guard case .camera = ActivityImages.pick(job: job, state: state, mode: .preview, now: at) else {
            return XCTFail("a fresh camera picture wins")
        }
        let later = at.addingTimeInterval(ActivityImages.cameraFresh + 1)
        XCTAssertEqual(ActivityImages.pick(job: job, state: state, mode: .preview, now: later),
                       .frame(try XCTUnwrap(ActivityImages.frameURL(job, 4))), "an old one doesn't")
        guard case .camera = ActivityImages.pick(job: job, state: state, mode: .camera, now: later) else {
            return XCTFail("camera mode keeps the last picture")
        }
        XCTAssertNil(ActivityImages.folder("../etc"), "job ids only")
    }

    func testNotificationWithACameraPicture() throws {
        let key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8="
        let blob = "cM5RB6Pkahq4mvlOhU/XPuz4x9Jkv+dmfJbNAEOmKPGRs4BvgOmqr1CjAVfhx5WU/P7DNXuQiiL+NI4In/8ulRFUfeqTkxafgkWrwThGIKpnkuot22/x1LFCyNkRyCiZX9zLUB9o00t4JGugm6Wvl0rgLDCZhrj4/BMSPw5u8DfmMSEQRCG0yyLugv94FADvNbJzas0pkfyKADpRC29sZe4BMG+z3Gfq9ZwdCvTgiGMCxLg79VUtDhAWplXaMkxFi7VhhlCKHyMipGGEyO+VkGphyhrpul24pV6WKtdAblCgSO80EOL7KuxvLMmcdLMffv0xBp/L/iM33Q=="
        let msg = try XCTUnwrap(PushPayload.open(blob, key: key))
        XCTAssertEqual(msg.event, "first_layer")
        XCTAssertEqual(msg.device, "dev123")
        XCTAssertEqual(msg.imageURLs(bases: ["http://192.0.2.5:8484/", "https://away.example"]).map(\.absoluteString),
                       ["http://192.0.2.5:8484/api/push/image/abcdefghijklmnopqrstuvwx.jpg",
                        "https://away.example/api/push/image/abcdefghijklmnopqrstuvwx.jpg"])
        var other = msg
        other.image = "https://evil.example/x.jpg"
        XCTAssertEqual(other.imageURLs(bases: ["http://home"]), [], "only the server's own picture path")
        other.image = "/api/push/image/../../api/jobs.jpg"
        XCTAssertEqual(other.imageURLs(bases: ["http://home"]), [])
    }

    func testCameraDeepLinkAndSnapshotPref() throws {
        XCTAssertEqual(DeepLink.parse(try XCTUnwrap(URL(string: "printshare://camera?printer=p1s-53"))), .camera("p1s-53"))
        XCTAssertEqual(DeepLink.parse(try XCTUnwrap(URL(string: "printshare://camera?printer=a%20b"))), .other)
        let prefs = try JSONDecoder().decode(PushPrefs.self, from: Data(#"{"done": true, "snapshots": true}"#.utf8))
        XCTAssertTrue(prefs.snapshots)
        XCTAssertFalse(try JSONDecoder().decode(PushPrefs.self, from: Data("{}".utf8)).snapshots, "off by default")
    }
}
