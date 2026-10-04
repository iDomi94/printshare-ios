import AVKit
import SwiftUI

/// The time-lapse of a print (server 0.32.0): play it, save / share the MP4.
struct TimelapseView: View {
    let job: String
    let name: String

    @Environment(AppModel.self) private var app
    @State private var player: AVPlayer?
    @State private var failed = false
    @State private var saving = false
    @State private var shared: SharedFile?

    var body: some View {
        let t = app.l10n
        VStack(spacing: 0) {
            Group {
                if let player {
                    VideoPlayer(player: player)
                } else if failed {
                    PSEmpty(icon: "film", title: t(.errUnknown))
                } else {
                    ProgressView().controlSize(.large).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)

            VStack(spacing: 10) {
                PSButton(title: t(.timelapseSave), kind: .secondary, icon: "square.and.arrow.down", loading: saving,
                         disabled: player == nil) { Task { await save() } }
            }
            .padding(Theme.space)
            .background(Theme.bg)
        }
        .navigationTitle("\(t(.timelapseTitle)) · \(name)")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onDisappear { player?.pause() }
        .sheet(item: $shared) { ActivitySheet(items: [$0.url]).ignoresSafeArea() }
    }

    /// The server needs the session token; AVPlayer sends it as a header, so it never appears in a URL.
    private func load() async {
        guard let api = app.api, let target = await api.timelapseRequest(job: job) else { failed = true; return }
        let asset = AVURLAsset(url: target.url, options: ["AVURLAssetHTTPHeaderFieldsKey": target.headers])
        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        player = p
        p.play()
    }

    private func save() async {
        guard let api = app.api else { return }
        saving = true
        defer { saving = false }
        if let url = try? await api.downloadTimelapse(job: job) { shared = SharedFile(url: url) }
    }
}
