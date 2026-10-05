import AVKit
import SwiftUI

/// The time-lapse of a print (server 0.32): play it, save / share it.
struct TimelapseView: View {
    let job: String
    let name: String

    @Environment(AppModel.self) private var app
    @State private var player: AVPlayer?
    @State private var saving = false
    @State private var share: SharedFile?
    @State private var error = ""

    var body: some View {
        let t = app.l10n
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let player {
                    VideoPlayer(player: player)
                } else {
                    ProgressView().tint(.white)
                }
            }
            VStack(spacing: 8) {
                if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                PSButton(title: t(.timelapseSave), kind: .secondary, icon: "square.and.arrow.down", loading: saving,
                         disabled: player == nil) {
                    Task { await save() }
                }
            }
            .padding(Theme.space)
            .background(Theme.bg)
        }
        .navigationTitle(name.isEmpty ? t(.timelapseTitle) : "\(t(.timelapseTitle)) · \(name)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard player == nil, let url = await app.api?.timelapseURL(job: job) else { return }
            let p = AVPlayer(url: url)
            player = p
            p.play()
        }
        .onDisappear { player?.pause() }
        .sheet(item: $share) { ActivitySheet(items: [$0.url]).ignoresSafeArea() }
    }

    private func save() async {
        guard let api = app.api else { return }
        saving = true
        error = ""
        defer { saving = false }
        do {
            let base = name.isEmpty ? job : name
            share = SharedFile(url: try await api.downloadTimelapse(job: job, name: "\(base)-timelapse.mp4"))
        } catch {
            self.error = errorText(app.l10n, error)
        }
    }
}
