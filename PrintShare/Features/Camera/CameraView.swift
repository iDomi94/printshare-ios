import SwiftUI
import UIKit

/// Live picture of the printer camera inside the app (issue #3). The printers serve MJPEG
/// (Centauri Carbon `:3031/video`, Klipper/OctoPrint `webcam/?action=stream`); the stream comes straight from the
/// printer, so it only works in the home network.
struct CameraView: View {
    let url: URL
    let title: String

    @Environment(AppModel.self) private var app
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var image: UIImage?
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        let t = app.l10n
        NavigationStack {
            VStack(spacing: 16) {
                ZStack {
                    Rectangle().fill(Color.black)
                    if let image {
                        Image(uiImage: image).resizable().scaledToFit()
                    } else if failed {
                        VStack(spacing: 10) {
                            Image(systemName: "video.slash").font(.largeTitle).foregroundStyle(.white.opacity(0.7))
                            Text(t(.cameraUnreachable)).font(.subheadline).foregroundStyle(.white.opacity(0.8))
                                .multilineTextAlignment(.center).padding(.horizontal, 24)
                        }
                    } else {
                        ProgressView().tint(.white).controlSize(.large)
                    }
                }
                .aspectRatio(4 / 3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                .accessibilityLabel(t(.camera))

                if failed {
                    PSButton(title: t(.tryAgain), kind: .secondary) { failed = false; attempt += 1 }
                }
                PSButton(title: t(.openInBrowser), kind: .plain, icon: "safari") { openURL(url) }
                Spacer(minLength: 0)
            }
            .padding(Theme.space)
            .background(Theme.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(t(.close)) { dismiss() } }
            }
            .task(id: attempt) { await play() }
        }
    }

    private func play() async {
        image = nil
        do {
            for try await frame in MJPEG.frames(url) {
                if let img = UIImage(data: frame) { image = img }
            }
            if !Task.isCancelled && image == nil { failed = true }
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

/// Minimal MJPEG reader: cuts JPEG frames (FFD8 … FFD9) out of a `multipart/x-mixed-replace` stream, off the main actor.
enum MJPEG {
    static func frames(_ url: URL, session: URLSession = .shared) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    var req = URLRequest(url: url)
                    req.timeoutInterval = 10
                    let (bytes, response) = try await session.bytes(for: req)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        throw URLError(.badServerResponse)
                    }
                    var parser = Parser()
                    for try await byte in bytes {
                        if let frame = parser.feed(byte) { continuation.yield(frame) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
