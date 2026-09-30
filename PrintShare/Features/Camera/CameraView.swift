import SwiftUI
import UIKit

/// Which printer's camera to show.
struct CameraTarget: Identifiable {
    var printer: String
    var name: String
    var id: String { printer }
}

/// Printer camera inside the app (issue #3): live MJPEG or still images, both through the PrintShare server
/// (server 0.9.0), so it works away from home too. Away (Tailscale) it starts with still images to save mobile data.
struct CameraView: View {
    let printer: String
    let title: String

    private enum Mode: Hashable { case live, still }

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var info: CameraInfo?
    @State private var away = false
    @State private var modePref: Mode?
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    private var mode: Mode { modePref ?? (info?.stream == true && !away ? .live : .still) }

    var body: some View {
        let t = app.l10n
        NavigationStack {
            VStack(spacing: 16) {
                if info?.stream == true {
                    PSSegmented(values: [Mode.live, .still], selection: Binding(get: { mode }, set: { modePref = $0 })) {
                        $0 == .live ? t(.cameraLive) : t(.cameraStill)
                    }
                }
                Group {
                    if mode == .live {
                        liveView(t)
                    } else {
                        CameraImage(printer: printer, width: away ? 960 : 1280, interval: away ? 3 : 1, fit: true)
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .accessibilityLabel(t(.camera))

                if mode == .live && failed {
                    PSButton(title: t(.tryAgain), kind: .secondary) { failed = false; attempt += 1 }
                }
                if info?.stream == true {
                    Text(t(.cameraDataHint)).font(.footnote).foregroundStyle(Theme.sub).multilineTextAlignment(.center)
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.space)
            .background(Theme.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(t(.close)) { dismiss() } }
            }
            .task { await loadInfo() }
            .task(id: "\(mode == .live)-\(attempt)") { await play() }
        }
    }

    private func liveView(_ t: L10n) -> some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                VStack(spacing: 10) {
                    Image(systemName: "video.slash").font(.largeTitle).foregroundStyle(.white.opacity(0.7))
                    Text(t(.cameraOffline)).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center).padding(.horizontal, 24)
                }
            } else {
                ProgressView().tint(.white).controlSize(.large)
            }
        }
    }

    private func loadInfo() async {
        guard let api = app.api else { return }
        away = await api.route() == .remote
        info = try? await api.cameraInfo(printer: printer)
    }

    private func play() async {
        guard mode == .live, let api = app.api else { return }
        image = nil
        guard let req = await api.cameraRequest(printer: printer, kind: .stream, timeout: 10) else { failed = true; return }
        do {
            for try await frame in MJPEG.frames(req) {
                if let img = UIImage(data: frame) { image = img }
            }
            if !Task.isCancelled && image == nil { failed = true }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

/// Still camera images through the server, refreshed every `interval` seconds while visible. The old image stays
/// until the next one has loaded, so nothing flickers.
struct CameraImage: View {
    let printer: String
    var width: Int?
    var interval: Double
    var fit = false

    @Environment(AppModel.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            Rectangle().fill(Color.black)
            if let image {
                if fit {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    Color.clear.overlay { Image(uiImage: image).resizable().scaledToFill() }.clipped()
                }
            } else if failed {
                Text(app.l10n(.cameraOffline)).font(.footnote).foregroundStyle(.white.opacity(0.8))
            } else {
                ProgressView().tint(.white)
            }
        }
        .task(id: scenePhase == .active) { await refresh() }
    }

    /// Only while on screen and the app is in the foreground: no downloads in the background.
    private func refresh() async {
        guard scenePhase == .active, let api = app.api else { return }
        while !Task.isCancelled {
            do {
                let data = try await api.cameraSnapshot(printer: printer, width: width)
                if let img = UIImage(data: data) { image = img; failed = false } else if image == nil { failed = true }
            } catch {
                if !Task.isCancelled && image == nil { failed = true }
            }
            try? await Task.sleep(for: .seconds(interval))
        }
    }
}

/// Minimal MJPEG reader: cuts JPEG frames (FFD8 … FFD9) out of a `multipart/x-mixed-replace` stream, off the main actor.
///
/// Read through a data delegate, not `URLSession.bytes(for:)`: URLSession splits `multipart/x-mixed-replace` into its
/// parts itself (one response per part), and the async byte sequence then delivered no frames at all - live view
/// stayed "not available" on a COSMOS / mjpg-streamer camera (2026-09-30). The delegate gets every part's data; the
/// parser finds the frames whether URLSession split the parts or passed the raw stream.
enum MJPEG {
    static func frames(_ req: URLRequest, configuration: URLSessionConfiguration = .default) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let reader = Reader(continuation)
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let session = URLSession(configuration: configuration, delegate: reader, delegateQueue: queue)
            let task = session.dataTask(with: req)
            continuation.onTermination = { _ in
                task.cancel()
                session.invalidateAndCancel()
            }
            task.resume()
        }
    }

    /// Delegate callbacks come one at a time on the session's serial queue, so the parser needs no lock.
    private final class Reader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation
        private var parser = Parser()

        init(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) { self.continuation = continuation }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                completionHandler(.cancel)
                continuation.finish(throwing: URLError(.badServerResponse))
                return
            }
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            for byte in data {
                if let frame = parser.feed(byte) { continuation.yield(frame) }
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { continuation.finish(throwing: error) } else { continuation.finish() }
            session.finishTasksAndInvalidate()
        }
    }

    /// Byte-wise JPEG frame splitter (also used by the tests).
    struct Parser {
        private var buffer: [UInt8] = []
        private var inFrame = false
        private var previous: UInt8 = 0
        /// Frames above this size are dropped (a broken stream must not eat the memory).
        var limit = 8 * 1024 * 1024

        mutating func feed(_ byte: UInt8) -> Data? {
            defer { previous = byte }
            if !inFrame {
                if previous == 0xFF && byte == 0xD8 { inFrame = true; buffer = [0xFF, 0xD8] }
                return nil
            }
            buffer.append(byte)
            if buffer.count > limit { inFrame = false; buffer.removeAll(); return nil }
            guard previous == 0xFF && byte == 0xD9 else { return nil }
            inFrame = false
            let frame = Data(buffer)
            buffer.removeAll(keepingCapacity: true)
            return frame
        }
    }
}
